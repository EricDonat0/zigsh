
const std = @import("std");

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

// Assinatura Juicy Main - Zig 0.16.x
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    // Configuracao da entrada padrao
    var input_buffer: [256]u8 = undefined;
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

    while (true) {

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

        var tokens = std.mem.tokenizeAny(u8, linha, " \t\r");

        while (tokens.next()) |token| {

            // Redirecionamento de saida (stdout)
            if (std.mem.eql(u8, token, ">")) {
                if (tokens.next()) |arquivo| {
                    parsed.stdout_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de saida nao informado\n",
                    );
                    try stdout.interface.flush();
                    continue;
                }
                continue;
            }

            // Redirecionamento de erros (stderr)
            if (std.mem.eql(u8, token, "2>")) {
                if (tokens.next()) |arquivo| {
                    parsed.stderr_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de erros nao informado\n",
                    );
                    try stdout.interface.flush();
                    continue;
                }
                continue;
            }

            // Redirecionamento de entrada (stdin)
            if (std.mem.eql(u8, token, "<")) {
                if (tokens.next()) |arquivo| {
                    parsed.stdin_file = try allocator.dupe(u8, arquivo);
                } else {
                    try stdout.interface.writeAll(
                        "Erro: arquivo de entrada nao informado\n",
                    );
                    try stdout.interface.flush();
                    continue;
                }
                continue;
            }

            // Execucao em segundo plano (background)
            if (std.mem.eql(u8, token, "&")) {
                parsed.is_background = true;
                continue;
            }

            // Identificacao de pipeline
            if (std.mem.eql(u8, token, "|")) {
                try parsed.args.append(
                    allocator,
                    try allocator.dupe(u8, token),
                );
                continue;
            }

            // Armazenar argumentos normais
            try parsed.args.append(
                allocator,
                try allocator.dupe(u8, token),
            );
        }

        // Ignorar comandos sem argumentos
        if (parsed.args.items.len == 0) continue;

        // TODO 4: Comandos internos (executar no processo pai)
        const comando = parsed.args.items[0];

        if (std.mem.eql(u8, comando, "cd")) {
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

        if (std.mem.eql(u8, comando, "pwd")) {
            if (parsed.args.items.len != 1) {
                try stdout.interface.writeAll("Uso: pwd\n");
            } else {
                try stdout.interface.print("{s}\n", .{cwd});
            }
            try stdout.interface.flush();
            continue;
        }

        if (std.mem.eql(u8, comando, "help")) {
            try stdout.interface.writeAll(
                "Comandos internos:\n" ++
                "  cd [diretorio] - muda o diretorio atual\n" ++
                "  pwd            - mostra o diretorio atual\n" ++
                "  help           - mostra esta ajuda\n" ++
                "  exit [codigo]  - encerra o shell\n" ++
                "Outros comandos sao executados pelo PATH.\n",
            );
            try stdout.interface.flush();
            continue;
        }

        if (std.mem.eql(u8, comando, "exit")) {
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

            try stdout.interface.writeAll("Shell encerrada.\n");
            try stdout.interface.flush();
            return codigo;
        }

        // TODO 5: Comandos externos usando std.process.spawn (Zig 0.16)
        // Os canais sao configurados como pipe quando existe redirecionamento.
        // Sem redirecionamento, o processo herda os canais do terminal.
        try stdout.interface.flush();

        var child = std.process.spawn(init.io, .{
            .argv = parsed.args.items,
            .environ_map = init.environ_map,

            .stdin = if (parsed.stdin_file != null)
                .pipe
            else
                .inherit,

            .stdout = if (parsed.stdout_file != null)
                .pipe
            else
                .inherit,

            .stderr = if (parsed.stderr_file != null)
                .pipe
            else
                .inherit,
        }) catch |err| {
            std.debug.print(
                "Erro ao executar {s}: {s}\n",
                .{ comando, @errorName(err) },
            );
            continue;
        };

        // TODO 6: Redirecionamento de arquivos
        const diretorio = std.Io.Dir.cwd();

        // Redirecionamento de entrada (stdin)
        if (parsed.stdin_file) |nome| {
            var arquivo_entrada = diretorio.openFile(
                init.io,
                nome,
                .{},
            ) catch |err| {
                std.debug.print(
                    "Erro ao abrir arquivo de entrada '{s}': {s}\n",
                    .{ nome, @errorName(err) },
                );

                child.kill(init.io);
                continue;
            };
            defer arquivo_entrada.close(init.io);

            var buffer_entrada: [1024]u8 = undefined;

            while (true) {
                const quantidade = arquivo_entrada.readStreaming(
                    init.io,
                    &.{buffer_entrada[0..]},
                ) catch |err| {
                    if (err == error.EndOfStream) {
                        break;
                    }

                    std.debug.print(
                        "Erro ao ler arquivo '{s}': {s}\n",
                        .{ nome, @errorName(err) },
                    );
                    break;
                };

                if (quantidade == 0) break;

                child.stdin.?.writeStreamingAll(
                    init.io,
                    buffer_entrada[0..quantidade],
                ) catch |err| {
                    std.debug.print(
                        "Erro ao enviar entrada para o processo: {s}\n",
                        .{@errorName(err)},
                    );
                    break;
                };
            }

            // Fechar o pipe para informar EOF ao processo filho.
            child.stdin.?.close(init.io);
            child.stdin = null;
        }

        // Redirecionamento de saida (stdout)
        if (parsed.stdout_file) |nome| {
            var arquivo_saida = diretorio.createFile(
                init.io,
                nome,
                .{},
            ) catch |err| {
                std.debug.print(
                    "Erro ao criar arquivo de saida '{s}': {s}\n",
                    .{ nome, @errorName(err) },
                );

                child.kill(init.io);
                continue;
            };
            defer arquivo_saida.close(init.io);

            var buffer_saida: [1024]u8 = undefined;

            while (true) {
                const quantidade = child.stdout.?.readStreaming(
                    init.io,
                    &.{buffer_saida[0..]},
                ) catch |err| {
                    if (err == error.EndOfStream) {
                        break;
                    }

                    std.debug.print(
                        "Erro ao ler saida do processo: {s}\n",
                        .{@errorName(err)},
                    );
                    break;
                };

                if (quantidade == 0) break;

                try arquivo_saida.writeStreamingAll(
                    init.io,
                    buffer_saida[0..quantidade],
                );
            }
        }

        // Redirecionamento de erros (stderr)
        if (parsed.stderr_file) |nome| {
            var arquivo_erros = diretorio.createFile(
                init.io,
                nome,
                .{},
            ) catch |err| {
                std.debug.print(
                    "Erro ao criar arquivo de erros '{s}': {s}\n",
                    .{ nome, @errorName(err) },
                );

                child.kill(init.io);
                continue;
            };
            defer arquivo_erros.close(init.io);

            var buffer_erros: [1024]u8 = undefined;

            while (true) {
                const quantidade = child.stderr.?.readStreaming(
                    init.io,
                    &.{buffer_erros[0..]},
                ) catch |err| {
                    if (err == error.EndOfStream) {
                        break;
                    }

                    std.debug.print(
                        "Erro ao ler erros do processo: {s}\n",
                        .{@errorName(err)},
                    );
                    break;
                };

                if (quantidade == 0) break;

                try arquivo_erros.writeStreamingAll(
                    init.io,
                    buffer_erros[0..quantidade],
                );
            }
        }

        // TODO 7: Implementar o encadeamento I/O entre processos conectados por Pipeline (|)
        // Conectar o stdout.Pipe do processo 1 ao stdin.Pipe do processo 2.

        // TODO 8: Controle de Concorrencia
        if (parsed.is_background) {
            try stdout.interface.print(
                "Processo '{s}' executado em segundo plano.\n",
                .{comando},
            );
            try stdout.interface.flush();
        } else {
            const resultado = child.wait(init.io) catch |err| {
                std.debug.print(
                    "Erro ao aguardar {s}: {s}\n",
                    .{ comando, @errorName(err) },
                );
                continue;
            };

            switch (resultado) {
                .exited => |codigo| {
                    if (codigo != 0) {
                        std.debug.print(
                            "Comando terminou com codigo {d}\n",
                            .{codigo},
                        );
                    }
                },
                else => {
                    std.debug.print(
                        "Comando terminou de forma anormal\n",
                        .{},
                    );
                },
            }
        }
    }

    try stdout.interface.writeAll("Shell encerrada.\n");
    try stdout.interface.flush();

    return 0;
}
