const std = @import("std");
const flate = @import("flate");
const print = std.debug.print;

const inputs = [3][]const u8{
    @embedFile("benchdata/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar"),
    @embedFile("benchdata/2600.txt.utf-8"),
    @embedFile("benchdata/large.tar"),
};

pub fn main() !void {
    if (readArgs() catch {
        std.process.exit(1);
    }) |opt| {
        switch (opt.output) {
            .dev_null => {
                var nw = NullWriter.init();
                try run(nw.writer(), opt);
                print("bytes: {d}\n", .{nw.bytes});
            },
            .stdout => {
                try run(std.io.getStdOut().writer(), opt);
            },
            .file => {
                const file = opt.output_file.?;
                defer file.close();
                try run(file.writer(), opt);
            },
        }
    }
}

pub fn run(output: anytype, opt: Options) !void {
    const input = inputs[opt.input_index];

    if (opt.stdlib) {
        switch (opt.alg) {
            .deflate => try stdDeflate(input, output),
            .zlib => try stdZlib(input, output),
            .gzip => {
                print("There is no gzip compressor currently in std lib.\n", .{});
            },
        }
    } else {
        var fbs = std.io.fixedBufferStream(input);
        switch (opt.alg) {
            .deflate => try flate.deflate(fbs.reader(), output),
            .zlib => try flate.zlib(fbs.reader(), output),
            .gzip => try flate.gzip(fbs.reader(), output),
        }
    }
}

const OutputKind = enum {
    dev_null,
    stdout,
    file,
};

const Algorithm = enum {
    deflate,
    zlib,
    gzip,
};

const Options = struct {
    output: OutputKind = .dev_null,
    output_file: ?std.fs.File = null,

    stdlib: bool = false,
    input_index: u8 = 0,
    alg: Algorithm = .deflate,
};

fn usage() void {
    std.debug.print(
        \\benchmark [options]
        \\
        \\Options:
        \\  -o <file_name>     output to the file
        \\  -c                 write on standard output
        \\  -i [0,1,2]         test file to use
        \\  -s                 use Zig's std lib implementation
        \\  -g                 gzip
        \\  -z                 zlib
        \\  -h, --help         give this help
        \\
    , .{});
}

pub fn readArgs() !?Options {
    var args = std.process.args();
    _ = args.next();

    var opt: Options = .{};

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-c")) {
            opt.output = .stdout;
            continue;
        }
        if (std.mem.eql(u8, a, "-o")) {
            opt.output = .file;
            if (args.next()) |file_name| {
                opt.output_file = std.fs.cwd().createFile(file_name, .{ .truncate = true }) catch |err| {
                    print("Fail to open file '{s}'!\nError: {}\n", .{ file_name, err });
                    return err;
                };
            } else {
                print("Missing file name after -o option!\n", .{});
                return error.InvalidArgs;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "-s")) {
            opt.stdlib = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-i")) {
            if (args.next()) |i| {
                opt.input_index = try std.fmt.parseInt(u8, i, 10);
                if (opt.input_index >= inputs.len) {
                    print("Input index must be in range 0-{d}!\n", .{inputs.len - 1});
                    return error.InvalidArgs;
                }
            } else {
                print("Missing input index after -i option!\n", .{});
                return error.InvalidArgs;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "-g")) {
            opt.alg = .gzip;
            continue;
        }
        if (std.mem.eql(u8, a, "-z")) {
            opt.alg = .zlib;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage();
            return null;
        }
        print("Unknown argument {s}!\n", .{a});
        return error.InvalidArgs;
    }
    return opt;
}

pub fn stdZlib(input: []const u8, writer: anytype) !void {
    const allocator = std.heap.page_allocator;
    var cmp = try std.compress.zlib.compressStream(allocator, writer, .{ .level = .default });
    defer cmp.deinit();

    try cmp.writer().writeAll(input);
    try cmp.finish();
}

pub fn stdDeflate(input: []const u8, writer: anytype) !void {
    const allocator = std.heap.page_allocator;
    var cmp = try std.compress.deflate.compressor(allocator, writer, .{});
    defer cmp.deinit();

    try cmp.writer().writeAll(input);
    try cmp.flush();
}

const NullWriter = struct {
    bytes: usize = 0,

    const Self = @This();
    pub const WriteError = error{};
    pub const Writer = std.io.Writer(*Self, WriteError, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
        self.bytes += bytes.len;
        return bytes.len;
    }

    pub fn init() Self {
        return .{};
    }
};
