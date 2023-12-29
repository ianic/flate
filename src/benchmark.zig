const std = @import("std");
const inflate = @import("inflate.zig").inflate;
const assert = std.debug.assert;

const data = @embedFile("testdata/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar.gz");
const data_bytes = 177244160;

// const data = @embedFile("testdata/2600.txt.utf-8.gz");
// const data_bytes = 3359630;

pub fn main() !void {
    //for (0..16) |_| try profile();

    const argv = std.os.argv;
    if (argv.len == 1) {
        try proj();
    } else {
        try std_lib();
    }
}

const buffer_len = 1024 * 64;

fn proj() !void {
    var fbs = std.io.fixedBufferStream(data);
    var inf = inflate(fbs.reader());
    var n: usize = 0;

    // while (try inf.nextChunk()) |buf| {
    //     n += buf.len;
    // }
    // assert(n == data_bytes);

    var buf: [buffer_len]u8 = undefined;
    var rdr = inf.reader();
    while (true) {
        const i = try rdr.readAll(&buf);
        n += i;
        if (i < buf.len) break;
    }
    assert(n == data_bytes);
}

pub fn std_lib() !void {
    var fbs = std.io.fixedBufferStream(data);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var inl = try std.compress.gzip.decompress(allocator, fbs.reader());
    var rdr = inl.reader();

    var n: usize = 0;
    var buf: [buffer_len]u8 = undefined;
    while (true) {
        const i = rdr.readAll(&buf) catch 0;
        if (i == 0) break;
        n += i;
    }
    assert(n == data_bytes);
    inl.deinit();
}

fn profile() !void {
    var fbs = std.io.fixedBufferStream(data);
    var inf = inflate(fbs.reader());
    var n: usize = 0;

    while (try inf.nextChunk()) |buf| {
        n += buf.len;
    }
    assert(n == data_bytes);
}
