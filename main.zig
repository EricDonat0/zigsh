
const std = @import("std");
const posix = std.posix.system;

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
pub fn main(init: std.process.Init) !void {
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

        var tokens = std.mem.tokenizeAny(u8, linha, " \t\r");

        while (tokens.next()) |token| {

            // Redirecionamento de saida (stdout)
            if (std.mem.eql(u8, token, ">")) {
                if (tokens.next()) |arquivo| {
                    parsed.stdout_file = try allocator.dupe(u8, arquivo);
                }
                continue;
            }

            // Redirecionamento de erros (stderr)
            if (std.mem.eql(u8, token, "2>")) {
                if (tokens.next()) |arquivo| {
                    parsed.stderr_file = try allocator.dupe(u8, arquivo);
                }
                continue;
            }

            // Redirecionamento de entrada (stdin)
            if (std.mem.eql(u8, token, "<")) {
                if (tokens.next()) |arquivo| {
                    parsed.stdin_file = try allocator.dupe(u8, arquivo);
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
        if (parsed.args.items.len == 0) {
            parsed.deinit();
            continue;
        }

        // TODO 4: Comandos internos
        const comando = parsed.args.items[0];

        if (std.mem.eql(u8, comando, "exit")) {
            parsed.deinit();
            break;
        }

        // TODO 5: Executar comandos externos

        // Criar vetor de argumentos terminado em null
        var argv_strings = try allocator.alloc(
            [:0]u8,
            parsed.args.items.len,
        );

        var args = try allocator.alloc(
            ?[*:0]const u8,
            parsed.args.items.len + 1,
        );

        for (parsed.args.items, 0..) |arg, i| {
            argv_strings[i] = try allocator.dupeZ(u8, arg);
            args[i] = argv_strings[i].ptr;
        }

        // Finalizar vetor de argumentos
        args[parsed.args.items.len] = null;

        // Criar processo filho
        const pid = posix.fork();

        if (std.posix.errno(pid) != .SUCCESS) {
            std.debug.print("Erro no fork!\n", .{});

            for (argv_strings) |arg| {
                allocator.free(arg);
            }

            allocator.free(argv_strings);
            allocator.free(args);

            parsed.deinit();
            continue;
        }

        if (pid == 0) {
            // Processo filho
            var caminho_buffer: [256]u8 = undefined;

            const caminho = std.fmt.bufPrintSentinel(
                &caminho_buffer,
                "/bin/{s}",
                .{comando},
                0,
            ) catch posix.exit(1);

            const env = [_:null]?[*:0]const u8{};

            _ = posix.execve(
                caminho.ptr,
                @ptrCast(args.ptr),
                &env,
            );

            std.debug.print(
                "Comando nao encontrado!\n",
                .{},
            );

            posix.exit(127);
        } else {
            // TODO 8: Controle de concorrencia
            // Temporariamente, aguardar o filho
            var status: u32 = 0;
            _ = posix.waitpid(@intCast(pid), &status, 0);
        }

        // Liberar memoria dos argumentos
        for (argv_strings) |arg| {
            allocator.free(arg);
        }

        allocator.free(argv_strings);
        allocator.free(args);

        // Liberar memoria do comando
        parsed.deinit();

        // TODO 6: Redirecionamento de arquivos
        // Implementar futuramente

        // TODO 7: Pipelines
        // Implementar futuramente
    }

    try stdout.interface.writeAll("Shell encerrada.\n");
    try stdout.interface.flush();
}
