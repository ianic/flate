const std = @import("std");
const inflate = @import("inflate.zig").inflate;
const assert = std.debug.assert;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) return;

    const file_name = std.mem.span(argv[1]);
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());

    const stdout = std.io.getStdOut();
    var il = inflate(br.reader());

    var n: usize = 0;
    while (try il.nextChunk()) |buf| {
        n += buf.len;
        try stdout.writeAll(buf);
    }

    // var buf: [128 * 1024]u8 = undefined;
    // var rdr = il.reader();
    // while (true) {
    //     const n = try rdr.readAll(&buf);
    //     std.debug.print("{d} ", .{n});
    //     if (n == 0) return;
    //     try stdout.writeAll(buf[0..n]);
    //     if (n < buf.len) return;
    // }
}

pub fn _main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) return;

    const file_name = std.mem.span(argv[1]);
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());

    // const stdin = std.io.getStdIn();
    // var br = std.io.bufferedReader(stdin.reader());

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut();
    var il = try std.compress.gzip.decompress(allocator, br.reader());
    var rdr = il.reader();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try rdr.readAll(&buf);
        std.debug.print("{d} ", .{n});
        if (n == 0) return;
        try stdout.writeAll(buf[0..n]);
    }
}
