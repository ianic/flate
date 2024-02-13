const std = @import("std");
const gzip = @import("compress").gzip;

const print = std.debug.print;
const assert = std.debug.assert;

const cases = [_]struct {
    data: []const u8,
    bytes: usize,
}{
    .{
        .data = @embedFile("bench_data/ziglang.tar.gz"),
        .bytes = 177244160,
    },
    .{
        .data = @embedFile("bench_data/war_and_peace.txt.gz"),
        .bytes = 3359630,
    },
    .{
        .data = @embedFile("bench_data/large.tar.gz"),
        .bytes = 11162624,
    },
    .{
        .data = @embedFile("bench_data/cantrbry.tar.gz"),
        .bytes = 2821120,
    },
};

const buffer_len = 1024 * 64;

fn usage(prog_name: []const u8) void {
    std.debug.print(
        \\{s} [options]
        \\
        \\Options:
        \\  -i [0-3]     use one of the test cases, default 0
        \\  -s           use Zig std lib gzip decompressor
        \\  -h           show this help
    , .{prog_name});
}

pub fn main() !void {
    if (readArgs() catch {
        std.process.exit(1);
    }) |opt| {
        //const input = opt.input_file.?.reader();

        const case = cases[opt.input_index];
        var fbs = std.io.fixedBufferStream(case.data);
        const input = fbs.reader();

        const n = if (opt.stdlib)
            try stdLib(input)
        else
            try thisLib(input);

        assert(n == case.bytes);
    }
}

const Options = struct {
    input_file: ?std.fs.File = null,
    input_size: usize = 0,

    input_index: u8 = 0,
    stdlib: bool = false,
};

pub fn readArgs() !?Options {
    var args = std.process.args();
    const prog_name = args.next().?;

    var opt: Options = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-i")) {
            if (args.next()) |i| {
                opt.input_index = std.fmt.parseInt(u8, i, 10) catch {
                    print("Unable to parse {s} as integer!", .{i});
                    return error.InvalidArgs;
                };
                if (opt.input_index >= cases.len) {
                    print("Input data index must be in range 0-{d}!\n", .{cases.len - 1});
                    return error.InvalidArgs;
                }
            } else {
                print("Missing compression level -l option!\n", .{});
                return error.InvalidArgs;
            }
            continue;
        }

        if (std.mem.eql(u8, a, "-s")) {
            opt.stdlib = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage(prog_name);
            return null;
        }
        //        if (a[0] == '-') {
        print("Unknown argument {s}!\n", .{a});
        return error.InvalidArgs;
    }
    return opt;
}

fn setInputFile(file_name: []const u8, opt: *Options) !void {
    opt.input_file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
        print("Fail to open input file '{s}'!\nError: {}\n", .{ file_name, err });
        return err;
    };
    const uncompressed = std.fs.cwd().openFile(file_name[0 .. file_name.len - 3], .{}) catch {
        return;
    };
    opt.input_size = (try uncompressed.stat()).size;
}

fn thisLib(input: anytype) !usize {
    var cw = std.io.countingWriter(std.io.null_writer);
    try gzip.decompress(input, cw.writer());
    return cw.bytes_written;
}

const allocator = std.heap.page_allocator;

pub fn stdLib(input: anytype) !usize {
    var dcp = try std.compress.gzip.decompress(allocator, input);
    defer dcp.deinit();

    //var rdr = dcp.reader();
    var n: usize = 0;
    var buf: [buffer_len]u8 = undefined;
    while (true) {
        //const i = rdr.readAll(&buf) catch 0;
        const i = dcp.read(&buf) catch 0;
        if (i == 0) break;
        n += i;
    }
    return n;
}
