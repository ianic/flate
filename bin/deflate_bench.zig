const std = @import("std");
const flate = @import("flate");

//const data = @embedFile("benchdata/large.tar");
//const data = @embedFile("benchdata/2600.txt.utf-8");
const data = @embedFile("benchdata/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const args = try std.process.argsAlloc(arena_allocator);

    // const output_file_name = "output.zz";
    // var output_file = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
    // const output = output_file.writer();
    // defer output_file.close();

    //const output = std.io.getStdOut().writer();

    const output = NullWriter.init().writer();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--std")) {
            try stdZlib(output);
            return;
        } else {
            std.os.exit(1);
        }
    }
    try lib(output);
}

pub fn lib(output: anytype) !void {
    var input = std.io.fixedBufferStream(data);
    try flate.zlib(input.reader(), output);
}

pub fn stdZlib(writer: anytype) !void {
    const allocator = std.heap.page_allocator;
    var compressor = try std.compress.zlib.compressStream(allocator, writer, .{ .level = .default });
    defer compressor.deinit();

    try compressor.writer().writeAll(data);
    try compressor.finish();
}

const NullWriter = struct {
    const Self = @This();
    pub const WriteError = error{};
    pub const Writer = std.io.Writer(Self, WriteError, write);
    pub fn writer(self: Self) Writer {
        return .{ .context = self };
    }
    pub fn write(_: Self, bytes: []const u8) WriteError!usize {
        return bytes.len;
    }
    pub fn init() Self {
        return .{};
    }
};
