const std = @import("std");
const flate = @import("flate");
const inflate = flate.inflate;

const assert = std.debug.assert;

const data = @embedFile("benchdata/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar.gz");
const data_bytes = 177244160;

// const data = @embedFile("benchdata/2600.txt.utf-8.gz");
// const data_bytes = 3359630;
//
// const data = @embedFile("benchdata/cantrbry.tar.gz");
// const data_bytes = 2821120;

// const data = @embedFile("benchdata/large.tar.gz");
// const data_bytes = 11162624;

const buffer_len = 1024 * 64;

fn usage() void {
    std.debug.print(
        \\benchmark [options]
        \\
        \\Options:
        \\  --std
        \\  --profile
        \\  --help
        \\
    , .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const args = try std.process.argsAlloc(arena_allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--std")) {
            try stdLibVersion();
            return;
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            try profile();
            return;
        } else if (std.mem.eql(u8, args[i], "--zero-copy")) {
            try zeroCopy();
            return;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            usage();
            return;
        } else {
            usage();
            std.os.exit(1);
        }
    }
    try readerInterface();
}

fn zeroCopy() !void {
    var fbs = std.io.fixedBufferStream(data);
    var inf = inflate(fbs.reader());
    var n: usize = 0;

    while (try inf.nextChunk()) |buf| {
        n += buf.len;
    }
    assert(n == data_bytes);
}

fn readerInterface() !void {
    var fbs = std.io.fixedBufferStream(data);
    var inf = inflate(fbs.reader());
    var n: usize = 0;

    var buf: [buffer_len]u8 = undefined;
    var rdr = inf.reader();
    while (true) {
        const i = try rdr.readAll(&buf);
        n += i;
        if (i < buf.len) break;
    }
    assert(n == data_bytes);
}

pub fn stdLibVersion() !void {
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
    for (0..16) |_| {
        try zeroCopy();
    }
}
