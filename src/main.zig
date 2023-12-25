const std = @import("std");
const inflate = @import("inflate.zig").inflate;

pub fn main() !void {
    const stdin = std.io.getStdIn();
    var br = std.io.bufferedReader(stdin.reader());
    const stdout = std.io.getStdOut();
    var il = inflate(br.reader());

    while (true) {
        const buf = try il.read();
        if (buf.len == 0) return;
        try stdout.writeAll(buf);
    }
}
