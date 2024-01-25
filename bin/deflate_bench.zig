const std = @import("std");
const flate = @import("flate");
const gzip = flate.gzip;
const zlib = flate.zlib;

const print = std.debug.print;

pub fn main() !void {
    if (readArgs() catch {
        std.process.exit(1);
    }) |opt| {
        switch (opt.output) {
            .dev_null => {
                var cw = std.io.countingWriter(std.io.null_writer);
                try run(cw.writer(), opt);
                print("bytes: {d}\n", .{cw.bytes_written});
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
    const input = opt.input_file.?.reader();

    if (opt.stdlib) {
        switch (opt.alg) {
            .deflate => try stdDeflate(input, output, opt),
            .zlib => try stdZlib(input, output, opt),
            .gzip => {
                print("There is no gzip compressor currently in std lib.\n", .{});
            },
        }
    } else {
        //var fbs = std.io.fixedBufferStream(input);
        const f_opt: flate.Options = .{ .level = @enumFromInt(opt.level) };
        switch (opt.alg) {
            .deflate => try flate.compress(input, output, f_opt),
            .zlib => try zlib.compress(input, output, f_opt),
            .gzip => try gzip.compress(input, output, f_opt),
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

    input_file: ?std.fs.File = null,
    //input_index: u8 = 0,

    stdlib: bool = false,
    alg: Algorithm = .deflate,
    level: u8 = 6,
};

fn usage() void {
    std.debug.print(
        \\benchmark [options]
        \\
        \\Options:
        \\  -o <output_file_name>     output to the file
        \\  -c                        write on standard output
        \\  -s                        use Zig's std lib implementation
        \\  -g                        gzip
        \\  -z                        zlib
        \\  -l [4-9]                  compression level
        \\  -h, --help                give this help
        \\ <input_file_name>
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
        if (std.mem.eql(u8, a, "-l")) {
            if (args.next()) |i| {
                opt.level = try std.fmt.parseInt(u8, i, 10);
                if (opt.level > 9 or opt.level < 4) {
                    print("Compression level must be in range 4-9!\n", .{});
                    return error.InvalidArgs;
                }
            } else {
                print("Missing compression level -l option!\n", .{});
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
        if (a[0] == '-') {
            print("Unknown argument {s}!\n", .{a});
            return error.InvalidArgs;
        }

        const input_file_name = a;
        opt.input_file = std.fs.cwd().openFile(input_file_name, .{}) catch |err| {
            print("Fail to open input file '{s}'!\nError: {}\n", .{ input_file_name, err });
            return err;
        };
    }
    if (opt.input_file == null) {
        const input_file_name = "bin/bench_data/ziglang.tar";
        opt.input_file = std.fs.cwd().openFile(input_file_name, .{}) catch |err| {
            print("Fail to open input file '{s}'!\nError: {}\n", .{ input_file_name, err });
            return err;
        };
    }

    return opt;
}

const read_buffer_len = 64 * 1024;
const allocator = std.heap.page_allocator;

pub fn stdZlib(reader: anytype, writer: anytype, opt: Options) !void {
    var z_opt: std.compress.zlib.CompressStreamOptions = .{ .level = .default };
    if (opt.level == 4) z_opt.level = .fastest;
    if (opt.level == 9) z_opt.level = .maximum;

    var cmp = try std.compress.zlib.compressStream(allocator, writer, z_opt);
    defer cmp.deinit();
    try stream(reader, cmp.writer());
    try cmp.finish();
}

pub fn stdDeflate(reader: anytype, writer: anytype, opt: Options) !void {
    const c_opt = std.compress.deflate.CompressorOptions{ .level = @enumFromInt(opt.level) };

    var cmp = try std.compress.deflate.compressor(allocator, writer, c_opt);
    defer cmp.deinit();
    try stream(reader, cmp.writer());
    try cmp.close();
}

fn stream(reader: anytype, writer: anytype) !void {
    var buf: [read_buffer_len]u8 = undefined;
    while (true) {
        const n = try reader.readAll(&buf);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        //if (n < buf.len) break;
    }
}
