const std = @import("std");
const raw = @import("compress").flate;
const gzip = @import("compress").gzip;
const zlib = @import("compress").zlib;

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
            .gzip => try stdGzip(input, output, opt),
        }
    } else {
        if (opt.level == 0) {
            switch (opt.alg) {
                .deflate => try raw.store.compress(input, output),
                .zlib => try zlib.store.compress(input, output),
                .gzip => try gzip.store.compress(input, output),
            }
            return;
        }
        if (opt.level == 1) {
            switch (opt.alg) {
                .deflate => try raw.huffman.compress(input, output),
                .zlib => try zlib.huffman.compress(input, output),
                .gzip => try gzip.huffman.compress(input, output),
            }
            return;
        }
        const level: raw.deflate.Level = @enumFromInt(opt.level);
        switch (opt.alg) {
            .deflate => try raw.compress(input, output, .{ .level = level }),
            .zlib => try zlib.compress(input, output, .{ .level = level }),
            .gzip => try gzip.compress(input, output, .{ .level = level }),
            // .gzip => {
            //     var buf: [4096]u8 = undefined;
            //     var cmp = try gzip.compressor(output, level);
            //     while (true) {
            //         const n = try input.readAll(&buf);
            //         _ = try cmp.write(buf[0..n]);
            //         try cmp.flush();
            //         if (n < buf.len) break;
            //     }
            //     try cmp.finish();
            // },
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
                if (!(opt.level == 0 or opt.level == 1 or (opt.level >= 4 and opt.level <= 9))) {
                    print("Compression level must be in range 4-9 or 0 for store, 1 for huffman only!\n", .{});
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

pub fn stdGzip(reader: anytype, writer: anytype, opt: Options) !void {
    const c_opt: std.compress.gzip.CompressOptions = if (opt.level == 0)
        .{ .level = .huffman_only }
    else
        .{ .level = @enumFromInt(opt.level) };

    var cmp = try std.compress.gzip.compress(allocator, writer, c_opt);
    defer cmp.deinit();
    try stream(reader, cmp.writer());
    try cmp.close();
}

pub fn stdDeflate(reader: anytype, writer: anytype, opt: Options) !void {
    const c_opt: std.compress.deflate.CompressorOptions = if (opt.level == 0)
        .{ .level = .huffman_only }
    else
        .{ .level = @enumFromInt(opt.level) };

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
