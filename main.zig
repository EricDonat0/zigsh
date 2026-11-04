
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
                    try stdout.interface.writeAll("cd: HOME nao definido\n");
                    try stdout.interface.flush();
                    continue;
                };

            const dir = std.Io.Dir.cwd().openDir(init.io, destino, .{}) catch |err| {
                try stdout.interface.print("cd: {s}: {s}\n", .{ destino, @errorName(err) });
                try stdout.interface.flush();
                continue;
            };
            defer dir.close(init.io);

            std.process.setCurrentDir(init.io, dir) catch |err| {
                try stdout.interface.print("cd: falha ao mudar diretorio: {s}\n", .{@errorName(err)});
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
                try stdout.interface.writeAll("Uso: exit [codigo de 0 a 255]\n");
                try stdout.interface.flush();
                continue;
            }

            const codigo: u8 = if (parsed.args.items.len == 2)
                std.fmt.parseInt(u8, parsed.args.items[1], 10) catch {
                    try stdout.interface.writeAll("exit: codigo deve estar entre 0 e 255\n");
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
        // O sistema localiza o executavel a partir do PATH.
        // A entrada e as saidas do filho sao herdadas do terminal.
        try stdout.interface.flush();

        var child = std.process.spawn(init.io, .{
            .argv = parsed.args.items,
            .environ_map = init.environ_map,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            std.debug.print("Erro ao executar {s}: {s}\n", .{ comando, @errorName(err) });
            continue;
        };
        defer child.kill(init.io);

        // TODO 8: Temporariamente, aguardar o processo filho.
        const resultado = child.wait(init.io) catch |err| {
            std.debug.print("Erro ao aguardar {s}: {s}\n", .{ comando, @errorName(err) });
            continue;
        };

        switch (resultado) {
            .exited => |codigo| {
                if (codigo != 0) {
                    std.debug.print("Comando terminou com codigo {d}\n", .{codigo});
                }
            },
            else => std.debug.print("Comando terminou de forma anormal\n", .{}),
        }

        // TODO 6: Redirecionamento de arquivos
        // Implementar futuramente

        // TODO 7: Pipelines
        // Implementar futuramente
    }

    try stdout.interface.writeAll("Shell encerrada.\n");
    try stdout.interface.flush();
    return 0;
}
