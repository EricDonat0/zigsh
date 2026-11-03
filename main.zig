
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
        self.args.deinit(self.allocator);
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
        // Temporariamente, manter o parser original
        var tokens = std.mem.tokenizeAny(u8, linha, " \t\r");

        var args = [_]?[*:0]const u8{null} ** 9;
        var arg_buffer: [8][256]u8 = undefined;
        var quantidade: usize = 0;

        while (tokens.next()) |texto| {
            if (quantidade == 8) break;

            const arg = std.fmt.bufPrintSentinel(
                &arg_buffer[quantidade],
                "{s}",
                .{texto},
                0,
            ) catch break;

            args[quantidade] = arg.ptr;
            quantidade += 1;
        }

        if (quantidade == 0) continue;

        const comando = std.mem.span(args[0].?);

        // TODO 4: Comandos internos
        // Por enquanto, somente exit
        if (std.mem.eql(u8, comando, "exit")) {
            break;
        }

        // TODO 5: Executar comandos externos
        // Temporariamente, usar fork + execve
        const pid = posix.fork();

        if (std.posix.errno(pid) != .SUCCESS) {
            std.debug.print("Erro no fork!\n", .{});
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
                @ptrCast(&args),
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

        // TODO 6: Redirecionamento de arquivos
        // Implementar futuramente

        // TODO 7: Pipelines
        // Implementar futuramente
    }

    try stdout.interface.writeAll("Shell encerrada.\n");
    try stdout.interface.flush();
}
