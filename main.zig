const std = @import("std");
const builtin = @import("builtin");

// Estrutura definida pelo professor.
// Sera utilizada nas proximas etapas.
const ParsedCommand = struct {
    allocator: std.mem.Allocator,
    args: std.ArrayList([]const u8) = .empty,

    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    is_background: bool = false,

    pub fn init(allocator: std.mem.Allocator) ParsedCommand {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedCommand) void {
        for (self.args.items) |arg| {
            self.allocator.free(arg);
        }

        self.args.deinit(self.allocator);

        if (self.stdin_file) |arquivo| {
            self.allocator.free(arquivo);
        }

        if (self.stdout_file) |arquivo| {
            self.allocator.free(arquivo);
        }

        if (self.stderr_file) |arquivo| {
            self.allocator.free(arquivo);
        }
    }
};

// TODO 7: um estagio do pipeline e o argv de um unico comando.
// A linha "ls | grep zig | wc -l" gera tres estagios.
const Estagio = []const []const u8;

// TODO 8: processo disparado com "&" que ainda nao foi recolhido.
const JobBackground = struct {
    numero: usize,
    pid: std.process.Child.Id,
    nome: []const u8,
};

// TODO 3 (complemento): tokenizador com suporte a aspas.
// "a b" vira um unico token (a b), sem as aspas. Um operador entre
// aspas (ex.: "|" ou ">") e tratado como argumento comum.
// O token e montado em `buffer`, que e reaproveitado a cada chamada,
// por isso o parser precisa copiar (dupe) o token antes da proxima.
const Tokenizador = struct {
    linha: []const u8,
    buffer: []u8,
    pos: usize = 0,
    // Indica se o ultimo token devolvido tinha aspas.
    com_aspas: bool = false,

    const Erro = error{ AspasNaoFechadas, TokenMuitoLongo };

    fn ehEspaco(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r';
    }

    fn proximo(self: *Tokenizador) Erro!?[]const u8 {
        while (self.pos < self.linha.len and ehEspaco(self.linha[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.linha.len) return null;

        var tamanho: usize = 0;
        var aspas: ?u8 = null;
        self.com_aspas = false;

        while (self.pos < self.linha.len) : (self.pos += 1) {
            const c = self.linha[self.pos];

            if (aspas) |abertura| {
                if (c == abertura) {
                    aspas = null;
                    continue;
                }
            } else {
                if (c == '"' or c == '\'') {
                    aspas = c;
                    self.com_aspas = true;
                    continue;
                }
                if (ehEspaco(c)) break;
            }

            if (tamanho >= self.buffer.len) return error.TokenMuitoLongo;
            self.buffer[tamanho] = c;
            tamanho += 1;
        }

        if (aspas != null) return error.AspasNaoFechadas;
        return self.buffer[0..tamanho];
    }
};

// TODO 7: separa os argumentos nos estagios do pipeline.
// `cortes` guarda, para cada "|" encontrado pelo parser, a posicao em
// `args` onde o comando seguinte comeca. Retorna erro se algum estagio
// ficar vazio (ex.: "ls |", "| wc" ou "ls | | wc").
fn separarEstagios(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cortes: []const usize,
) error{ EstagioVazio, OutOfMemory }!std.ArrayList(Estagio) {
    var estagios: std.ArrayList(Estagio) = .empty;
    errdefer estagios.deinit(allocator);

    var inicio: usize = 0;
    for (cortes) |corte| {
        if (corte == inicio) return error.EstagioVazio;
        try estagios.append(allocator, args[inicio..corte]);
        inicio = corte;
    }

    if (inicio == args.len) return error.EstagioVazio;
    try estagios.append(allocator, args[inicio..]);

    return estagios;
}

// TODO 8: resultado de um filho recolhido com waitpid.
const FilhoTerminado = struct {
    pid: std.process.Child.Id,
    termino: std.process.Child.Term,
};

// TODO 8: recolhe, sem bloquear, UM filho qualquer que ja tenha terminado.
// Retorna null se nenhum filho terminou (ou se nao ha filhos).
// Usa waitpid(-1, WNOHANG) diretamente porque Child.wait() e bloqueante
// e porque o fork cujo exec falhou (comando inexistente) nao tem o pid
// devolvido pelo spawn(): so assim ele tambem e recolhido.
fn recolherQualquerFilho() ?FilhoTerminado {
    const posix = std.posix;

    var status: if (builtin.link_libc) c_int else u32 = undefined;

    while (true) {
        const rc = posix.system.waitpid(-1, &status, posix.W.NOHANG);

        switch (posix.errno(rc)) {
            .SUCCESS => {
                // waitpid devolve 0 quando nenhum filho terminou ainda.
                if (rc == 0) return null;

                const pid: std.process.Child.Id = @intCast(rc);
                const s: u32 = @bitCast(status);

                const termino: std.process.Child.Term = if (posix.W.IFEXITED(s))
                    .{ .exited = posix.W.EXITSTATUS(s) }
                else if (posix.W.IFSIGNALED(s))
                    .{ .signal = posix.W.TERMSIG(s) }
                else
                    .{ .unknown = s };

                return .{ .pid = pid, .termino = termino };
            },
            .INTR => continue,
            // ECHILD: nao ha mais filhos para recolher.
            else => return null,
        }
    }
}

// TODO 8: recolhe os processos em segundo plano que ja terminaram,
// evitando zumbis sem bloquear o REPL. Chamado antes de cada prompt,
// quando nao ha nenhum processo em primeiro plano pendente.
fn recolherBackground(
    allocator: std.mem.Allocator,
    jobs: *std.ArrayList(JobBackground),
    stdout: *std.Io.Writer,
) !void {
    while (recolherQualquerFilho()) |filho| {
        // Procurar o job correspondente. Um pid desconhecido e o fork
        // de um spawn que falhou: basta te-lo recolhido.
        const indice = for (jobs.items, 0..) |job, i| {
            if (job.pid == filho.pid) break i;
        } else continue;

        const job = jobs.items[indice];

        switch (filho.termino) {
            .exited => |codigo| try stdout.print(
                "[{d}] Concluido (pid {d}): {s} (codigo {d})\n",
                .{ job.numero, job.pid, job.nome, codigo },
            ),
            .signal => |sinal| try stdout.print(
                "[{d}] Encerrado por sinal {s} (pid {d}): {s}\n",
                .{ job.numero, @tagName(sinal), job.pid, job.nome },
            ),
            else => try stdout.print(
                "[{d}] Concluido (pid {d}): {s}\n",
                .{ job.numero, job.pid, job.nome },
            ),
        }

        allocator.free(job.nome);
        _ = jobs.orderedRemove(indice);
    }

    try stdout.flush();
}

// TODO 5, 6, 7 e 8: executa um comando externo ou um pipeline.
//
// Redirecionamentos (TODO 6): os arquivos sao abertos pelo shell e
// passados ao processo filho como `.file`, assim o proprio sistema
// operacional faz a transferencia de dados (sem o shell copiar bytes,
// o que tambem evita travamentos com & e com pipelines).
//   - "<"  vale para o primeiro estagio do pipeline.
//   - ">" e "2>" valem para o ultimo estagio.
//
// Pipeline (TODO 7): cada estagio, exceto o ultimo, e criado com
// stdout = .pipe; a ponta de leitura desse pipe vira o stdin (.file)
// do estagio seguinte. O shell fecha a ponta assim que o filho a herda,
// para que o processo seguinte receba EOF quando o anterior terminar.
//
// Concorrencia (TODO 8): em primeiro plano aguarda todos os filhos;
// com "&" registra os pids em `jobs` e devolve o prompt imediatamente.
fn executarPipeline(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    parsed: *const ParsedCommand,
    estagios: []const Estagio,
    jobs: *std.ArrayList(JobBackground),
    proximo_job: *usize,
    stdout: *std.Io.Writer,
) !void {
    const diretorio = std.Io.Dir.cwd();

    // Tudo que o shell escreveu precisa sair antes de criar os filhos,
    // porque eles herdam o mesmo terminal.
    try stdout.flush();

    // TODO 6: abrir os arquivos de redirecionamento antes de criar
    // qualquer processo. Se algum falhar, nada e executado.
    var arquivo_entrada: ?std.Io.File = null;
    defer if (arquivo_entrada) |arquivo| arquivo.close(io);

    if (parsed.stdin_file) |nome| {
        arquivo_entrada = diretorio.openFile(io, nome, .{}) catch |err| {
            std.debug.print(
                "Erro ao abrir arquivo de entrada '{s}': {s}\n",
                .{ nome, @errorName(err) },
            );
            return;
        };
    }

    var arquivo_saida: ?std.Io.File = null;
    defer if (arquivo_saida) |arquivo| arquivo.close(io);

    if (parsed.stdout_file) |nome| {
        arquivo_saida = diretorio.createFile(io, nome, .{}) catch |err| {
            std.debug.print(
                "Erro ao criar arquivo de saida '{s}': {s}\n",
                .{ nome, @errorName(err) },
            );
            return;
        };
    }

    var arquivo_erros: ?std.Io.File = null;
    defer if (arquivo_erros) |arquivo| arquivo.close(io);

    if (parsed.stderr_file) |nome| {
        arquivo_erros = diretorio.createFile(io, nome, .{}) catch |err| {
            std.debug.print(
                "Erro ao criar arquivo de erros '{s}': {s}\n",
                .{ nome, @errorName(err) },
            );
            return;
        };
    }

    // TODO 5 e 7: criar os processos, ligando a saida de um a entrada
    // do seguinte.
    var filhos: std.ArrayList(std.process.Child) = .empty;
    defer filhos.deinit(allocator);

    // Ponta de leitura do pipe do estagio anterior (ainda nao entregue).
    var entrada_anterior: ?std.Io.File = null;
    defer if (entrada_anterior) |pipe| pipe.close(io);

    for (estagios, 0..) |argv, i| {
        const primeiro = i == 0;
        const ultimo = i == estagios.len - 1;

        const stdin_cfg: std.process.SpawnOptions.StdIo = if (entrada_anterior) |pipe|
            .{ .file = pipe }
        else if (primeiro and arquivo_entrada != null)
            .{ .file = arquivo_entrada.? }
        else
            .inherit;

        const stdout_cfg: std.process.SpawnOptions.StdIo = if (!ultimo)
            .pipe
        else if (arquivo_saida) |arquivo|
            .{ .file = arquivo }
        else
            .inherit;

        const stderr_cfg: std.process.SpawnOptions.StdIo = if (ultimo and arquivo_erros != null)
            .{ .file = arquivo_erros.? }
        else
            .inherit;

        var filho = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = environ_map,
            .stdin = stdin_cfg,
            .stdout = stdout_cfg,
            .stderr = stderr_cfg,
        }) catch |err| {
            std.debug.print(
                "Erro ao executar {s}: {s}\n",
                .{ argv[0], @errorName(err) },
            );

            // Fechar a ponta pendente para que o estagio anterior receba
            // EOF/SIGPIPE, e recolher os filhos ja criados (sem zumbis).
            if (entrada_anterior) |pipe| {
                pipe.close(io);
                entrada_anterior = null;
            }
            for (filhos.items) |*criado| {
                _ = criado.wait(io) catch {};
            }
            return;
        };

        // O filho ja herdou a ponta de leitura: o shell nao precisa
        // mais dela. Fechar aqui e essencial, senao o proximo processo
        // nunca receberia EOF.
        if (entrada_anterior) |pipe| {
            pipe.close(io);
            entrada_anterior = null;
        }

        // Guardar a ponta de leitura deste estagio para o proximo.
        // Zeramos o campo para o wait() nao fechar o descritor de novo.
        if (filho.stdout) |pipe| {
            entrada_anterior = pipe;
            filho.stdout = null;
        }

        try filhos.append(allocator, filho);
    }

    // TODO 8: Controle de Concorrencia
    if (parsed.is_background) {
        for (filhos.items, estagios) |filho, argv| {
            const numero = proximo_job.*;
            proximo_job.* += 1;

            try jobs.append(allocator, .{
                .numero = numero,
                .pid = filho.id.?,
                .nome = try allocator.dupe(u8, argv[0]),
            });

            try stdout.print(
                "[{d}] Processo '{s}' (pid {d}) executado em segundo plano.\n",
                .{ numero, argv[0], filho.id.? },
            );
        }
        try stdout.flush();
        return;
    }

    for (filhos.items, estagios) |*filho, argv| {
        const resultado = filho.wait(io) catch |err| {
            std.debug.print(
                "Erro ao aguardar {s}: {s}\n",
                .{ argv[0], @errorName(err) },
            );
            continue;
        };

        switch (resultado) {
            .exited => |codigo| {
                if (codigo != 0) {
                    std.debug.print(
                        "Comando '{s}' terminou com codigo {d}\n",
                        .{ argv[0], codigo },
                    );
                }
            },
            .signal => |sinal| {
                // SIGPIPE e normal em pipelines: o leitor fechou antes
                // do escritor terminar (ex.: "seq 1 100000 | head -1").
                if (sinal != .PIPE) {
                    std.debug.print(
                        "Comando '{s}' encerrado pelo sinal {s}\n",
                        .{ argv[0], @tagName(sinal) },
                    );
                }
            },
            else => {
                std.debug.print(
                    "Comando '{s}' terminou de forma anormal\n",
                    .{argv[0]},
                );
            },
        }
    }
}

// Assinatura Juicy Main - Zig 0.16.x
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    // Configuracao da entrada padrao
    var input_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(
        init.io,
        &input_buffer,
    );

    // Configuracao da saida padrao
    var output_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(
        init.io,
        &output_buffer,
    );

    // Buffer de montagem de tokens (mesmo tamanho da linha).
    var token_buffer: [4096]u8 = undefined;

    // TODO 8: processos em segundo plano ainda em execucao.
    var jobs: std.ArrayList(JobBackground) = .empty;
    var proximo_job: usize = 1;
    defer {
        for (jobs.items) |job| allocator.free(job.nome);
        jobs.deinit(allocator);
    }

    while (true) {

        // TODO 8: recolher processos em segundo plano concluidos
        try recolherBackground(allocator, &jobs, &stdout.interface);

        // TODO 1: Prompt dinamico com diretorio atual
        const cwd = try std.process.currentPathAlloc(
            init.io,
            allocator,
        );
        defer allocator.free(cwd);

        try stdout.interface.print(
            "zigsh [{s}]> ",
            .{cwd},
        );
        try stdout.interface.flush();

        // TODO 2: Ler a linha e tratar EOF (Ctrl+D)
        const linha = (try stdin.interface.takeDelimiter('\n')) orelse {
            try stdout.interface.writeAll("\n");
            try stdout.interface.flush();
            break;
        };

        // Ignorar linhas vazias ou apenas com espacos
        if (std.mem.trim(u8, linha, " \t\r").len == 0) {
            continue;
        }

        // TODO 3: Parsing e tokenizacao completa
        var parsed = ParsedCommand.init(allocator);
        defer parsed.deinit();

        // TODO 7: posicoes em parsed.args onde cada "|" corta o pipeline.
        var cortes: std.ArrayList(usize) = .empty;
        defer cortes.deinit(allocator);

        var tokens = Tokenizador{ .linha = linha, .buffer = &token_buffer };
        var erro_sintaxe = false;

        while (true) {
            const token = (tokens.proximo() catch |err| {
                try stdout.interface.print(
                    "Erro de sintaxe: {s}\n",
                    .{switch (err) {
                        error.AspasNaoFechadas => "aspas nao fechadas",
                        error.TokenMuitoLongo => "argumento muito longo",
                    }},
                );
                try stdout.interface.flush();
                erro_sintaxe = true;
                break;
            }) orelse break;

            // Um operador entre aspas e so um argumento comum.
            const eh_operador = !tokens.com_aspas;

            // Redirecionamento de saida (stdout)
            if (eh_operador and std.mem.eql(u8, token, ">")) {
                if (try tokens.proximo()) |arquivo| {
                    parsed.stdout_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de saida nao informado\n",
                    );
                    try stdout.interface.flush();
                    erro_sintaxe = true;
                    break;
                }
                continue;
            }

            // Redirecionamento de erros (stderr)
            if (eh_operador and std.mem.eql(u8, token, "2>")) {
                if (try tokens.proximo()) |arquivo| {
                    parsed.stderr_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de erros nao informado\n",
                    );
                    try stdout.interface.flush();
                    erro_sintaxe = true;
                    break;
                }
                continue;
            }

            // Redirecionamento de entrada (stdin)
            if (eh_operador and std.mem.eql(u8, token, "<")) {
                if (try tokens.proximo()) |arquivo| {
                    parsed.stdin_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de entrada nao informado\n",
                    );
                    try stdout.interface.flush();
                    erro_sintaxe = true;
                    break;
                }
                continue;
            }

            // Execucao em segundo plano (background)
            if (eh_operador and std.mem.eql(u8, token, "&")) {
                parsed.is_background = true;
                continue;
            }

            // Identificacao de pipeline: o "|" nao vira argumento,
            // apenas marca onde o proximo comando comeca.
            if (eh_operador and std.mem.eql(u8, token, "|")) {
                try cortes.append(allocator, parsed.args.items.len);
                continue;
            }

            // Armazenar argumentos normais
            try parsed.args.append(
                allocator,
                try allocator.dupe(u8, token),
            );
        }

        if (erro_sintaxe) continue;

        // Ignorar comandos sem argumentos
        if (parsed.args.items.len == 0 and cortes.items.len == 0) continue;

        // TODO 7: montar os estagios do pipeline
        var estagios = separarEstagios(
            allocator,
            parsed.args.items,
            cortes.items,
        ) catch |err| switch (err) {
            error.EstagioVazio => {
                try stdout.interface.writeAll(
                    "Erro de sintaxe: pipeline com comando vazio " ++
                        "(ex.: 'ls |', '| wc' ou 'ls | | wc')\n",
                );
                try stdout.interface.flush();
                continue;
            },
            error.OutOfMemory => return err,
        };
        defer estagios.deinit(allocator);

        const eh_pipeline = estagios.items.len > 1;

        // TODO 4: Comandos internos (executar no processo pai)
        // Em um pipeline nao ha comandos internos: tudo vira processo filho.
        const comando = parsed.args.items[0];

        if (!eh_pipeline and std.mem.eql(u8, comando, "cd")) {
            if (parsed.args.items.len > 2) {
                try stdout.interface.writeAll("Uso: cd [diretorio]\n");
                try stdout.interface.flush();
                continue;
            }

            const destino = if (parsed.args.items.len == 2)
                parsed.args.items[1]
            else
                init.environ_map.get("HOME") orelse {
                    try stdout.interface.writeAll(
                        "cd: HOME nao definido\n",
                    );
                    try stdout.interface.flush();
                    continue;
                };

            const dir = std.Io.Dir.cwd().openDir(
                init.io,
                destino,
                .{},
            ) catch |err| {
                try stdout.interface.print(
                    "cd: {s}: {s}\n",
                    .{ destino, @errorName(err) },
                );
                try stdout.interface.flush();
                continue;
            };
            defer dir.close(init.io);

            std.process.setCurrentDir(init.io, dir) catch |err| {
                try stdout.interface.print(
                    "cd: falha ao mudar diretorio: {s}\n",
                    .{@errorName(err)},
                );
                try stdout.interface.flush();
            };
            continue;
        }

        if (!eh_pipeline and std.mem.eql(u8, comando, "pwd")) {
            if (parsed.args.items.len != 1) {
                try stdout.interface.writeAll("Uso: pwd\n");
            } else {
                try stdout.interface.print("{s}\n", .{cwd});
            }
            try stdout.interface.flush();
            continue;
        }

        if (!eh_pipeline and std.mem.eql(u8, comando, "help")) {
            try stdout.interface.writeAll(
                "Comandos internos:\n" ++
                    "  cd [diretorio] - muda o diretorio atual\n" ++
                    "  pwd            - mostra o diretorio atual\n" ++
                    "  jobs           - lista processos em segundo plano\n" ++
                    "  help           - mostra esta ajuda\n" ++
                    "  exit [codigo]  - encerra o shell\n" ++
                    "Outros comandos sao executados pelo PATH.\n" ++
                    "Operadores: > 2> < (redirecionamento), | (pipeline), & (segundo plano)\n",
            );
            try stdout.interface.flush();
            continue;
        }

        // TODO 8: lista os processos em segundo plano ainda em execucao
        if (!eh_pipeline and std.mem.eql(u8, comando, "jobs")) {
            if (jobs.items.len == 0) {
                try stdout.interface.writeAll(
                    "Nenhum processo em segundo plano.\n",
                );
            }
            for (jobs.items) |job| {
                try stdout.interface.print(
                    "[{d}] Em execucao (pid {d}): {s}\n",
                    .{ job.numero, job.pid, job.nome },
                );
            }
            try stdout.interface.flush();
            continue;
        }

        if (!eh_pipeline and std.mem.eql(u8, comando, "exit")) {
            if (parsed.args.items.len > 2) {
                try stdout.interface.writeAll(
                    "Uso: exit [codigo de 0 a 255]\n",
                );
                try stdout.interface.flush();
                continue;
            }

            const codigo: u8 = if (parsed.args.items.len == 2)
                std.fmt.parseInt(u8, parsed.args.items[1], 10) catch {
                    try stdout.interface.writeAll(
                        "exit: codigo deve estar entre 0 e 255\n",
                    );
                    try stdout.interface.flush();
                    continue;
                }
            else
                0;

            if (jobs.items.len > 0) {
                try stdout.interface.print(
                    "Aviso: {d} processo(s) em segundo plano ainda em execucao.\n",
                    .{jobs.items.len},
                );
            }
            try stdout.interface.writeAll("Shell encerrada.\n");
            try stdout.interface.flush();
            return codigo;
        }

        // TODO 5, 6, 7 e 8: Comandos externos, redirecionamento,
        // pipeline e controle de concorrencia
        try executarPipeline(
            init.io,
            allocator,
            init.environ_map,
            &parsed,
            estagios.items,
            &jobs,
            &proximo_job,
            &stdout.interface,
        );
    }

    if (jobs.items.len > 0) {
        try stdout.interface.print(
            "Aviso: {d} processo(s) em segundo plano ainda em execucao.\n",
            .{jobs.items.len},
        );
    }
    try stdout.interface.writeAll("Shell encerrada.\n");
    try stdout.interface.flush();

    return 0;
}
