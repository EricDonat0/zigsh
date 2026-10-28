
const std = @import("std");
const posix = std.posix.system;

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &buffer);

    while (true) {
        std.debug.print("> ", .{});

        const linha = (try stdin.interface.takeDelimiter('\n')) orelse break;

        // Separa comando e argumentos
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

        if (std.mem.eql(u8, comando, "exit")) break;

        const pid = posix.fork();

        if (std.posix.errno(pid) != .SUCCESS) {
            std.debug.print("Erro no fork!\n", .{});
            continue;
        }

        if (pid == 0) {
            // FILHO
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

            std.debug.print("Comando nao encontrado!\n", .{});
            posix.exit(127);
        } else {
            // PAI
            var status: u32 = 0;
            _ = posix.waitpid(@intCast(pid), &status, 0);
        }
    }

    std.debug.print("Shell encerrada.\n", .{});
}
