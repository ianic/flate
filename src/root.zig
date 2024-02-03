const deflate = @import("deflate.zig");
const inflate = @import("inflate.zig");

pub const Level = deflate.Level;

pub fn decompress(reader: anytype, writer: anytype) !void {
    try inflate.decompress(.raw, reader, writer);
}

pub fn decompressor(reader: anytype) inflate.Inflate(.raw, @TypeOf(reader)) {
    return inflate.inflate(.raw, reader);
}

pub fn compress(reader: anytype, writer: anytype, level: Level) !void {
    try deflate.compress(.raw, reader, writer, level);
}

pub fn compressHuffmanOnly(reader: anytype, writer: anytype) !void {
    try deflate.compressHuffmanOnly(.raw, reader, writer);
}

pub fn compressor(writer: anytype, level: Level) !void {
    try deflate.compressor(.raw, writer, level);
}

pub const gzip = struct {
    pub fn decompress(reader: anytype, writer: anytype) !void {
        try inflate.decompress(.gzip, reader, writer);
    }

    pub fn decompressor(reader: anytype) inflate.Inflate(.gzip, @TypeOf(reader)) {
        return inflate.decompressor(.gzip, reader);
    }

    pub fn compress(reader: anytype, writer: anytype, level: Level) !void {
        try deflate.compress(.gzip, reader, writer, level);
    }

    pub fn compressHuffmanOnly(reader: anytype, writer: anytype) !void {
        try deflate.compressHuffmanOnly(.gzip, reader, writer);
    }

    pub fn compressor(writer: anytype, level: Level) !deflate.Compressor(.gzip, @TypeOf(writer)) {
        return try deflate.compressor(.gzip, writer, level);
    }
};

pub const zlib = struct {
    pub fn decompress(reader: anytype, writer: anytype) !void {
        try inflate.decompress(.zlib, reader, writer);
    }

    pub fn decompressor(reader: anytype) inflate.Inflate(.zlib, @TypeOf(reader)) {
        return inflate.decompressor(.zlib, reader);
    }

    pub fn compress(reader: anytype, writer: anytype, level: Level) !void {
        try deflate.compress(.zlib, reader, writer, level);
    }

    pub fn compressHuffmanOnly(reader: anytype, writer: anytype) !void {
        try deflate.compressHuffmanOnly(.zlib, reader, writer);
    }

    pub fn compressor(writer: anytype, level: Level) !deflate.Compressor(.zlib, @TypeOf(writer)) {
        return try deflate.compressor(.zlib, writer, level);
    }
};

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}

const std = @import("std");
const testing = std.testing;

test "decompress" {
    const deflate_block = [_]u8{
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
    };
    const gzip_block =
        [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 } ++ // gzip header (10 bytes)
        deflate_block ++
        [_]u8{ 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00 }; // gzip footer checksum (4 byte), size (4 bytes)
    const zlib_block = [_]u8{ 0x78, 0b10_0_11100 } ++ // zlib header (2 bytes)}
        deflate_block ++
        [_]u8{ 0x1c, 0xf2, 0x04, 0x47 }; // zlib footer: checksum

    const expected = "Hello world\n";

    var raw_in = std.io.fixedBufferStream(&deflate_block);
    var gzip_in = std.io.fixedBufferStream(&gzip_block);
    var zlib_in = std.io.fixedBufferStream(&zlib_block);

    // raw deflate
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try decompress(raw_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }
    // gzip
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try gzip.decompress(gzip_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }
    // zlib
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try zlib.decompress(zlib_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }

    // raw with decompressor interface
    {
        raw_in.reset();
        var cmp = decompressor(raw_in.reader());
        try testing.expectEqualStrings(expected, (try cmp.next()).?);
        try testing.expect((try cmp.next()) == null);
    }
    var buf: [128]u8 = undefined;
    // raw with decompressor reader interface
    {
        raw_in.reset();
        var cmp = decompressor(raw_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
    // // gzip decompressor
    // {
    //     gzip_in.reset();
    //     var cmp = gzip.decompressor(gzip_in.reader());
    //     var rdr = cmp.reader();
    //     const n = try rdr.readAll(&buf);
    //     try testing.expectEqualStrings(expected, buf[0..n]);
    // }
    // // zlib decompressor
    // {
    //     zlib_in.reset();
    //     var cmp = zlib.decompressor(zlib_in.reader());
    //     var rdr = cmp.reader();
    //     const n = try rdr.readAll(&buf);
    //     try testing.expectEqualStrings(expected, buf[0..n]);
    // }
}

test "compress/decompress" {
    const Wrapper = @import("wrapper.zig").Wrapper;
    const fixedBufferStream = std.io.fixedBufferStream;

    var cmp_buf: [32 * 1024]u8 = undefined; // compressed data buffer
    var dcm_buf: [64 * 1024]u8 = undefined; // decompressed data buffer

    const levels = [_]Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const cases = [_]struct {
        data: []const u8, // uncompressed content
        gzip_sizes: [levels.len]usize, // compressed data sizes per level 4-9
        huffman_only_size: usize,
    }{
        .{
            .data = @embedFile("testdata/rfc1951.txt"),
            .gzip_sizes = [_]usize{ 11513, 11217, 11139, 11126, 11122, 11119 },
            .huffman_only_size = 20291,
        },
    };

    // helper for printing sizes
    // for (cases, 0..) |case, i| {
    //     const data = case.data;
    //     std.debug.print("\ncase[{d}]: ", .{i});
    //     for (4..10) |ilevel| {
    //         var original = fixedBufferStream(data);
    //         var compressed = fixedBufferStream(&cmp_buf);
    //         try deflate.compress(.gzip, original.reader(), compressed.writer(), .{ .level = @enumFromInt(ilevel) });
    //         std.debug.print("{d}, ", .{compressed.pos});
    //     }
    // }
    // std.debug.print("\n", .{});

    for (cases) |case| { // for each case
        const data = case.data;

        for (levels, 0..) |level, i| { // for each compression level
            const gzip_size = case.gzip_sizes[i];

            inline for (Wrapper.list) |wrap| { // for each wrapping
                const compressed_size = gzip_size - Wrapper.gzip.size() + wrap.size();

                // compress original stream to compressed stream
                {
                    var original = fixedBufferStream(data);
                    var compressed = fixedBufferStream(&cmp_buf);

                    try deflate.compress(wrap, original.reader(), compressed.writer(), level);

                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompress compressed stream to decompressed stream
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);
                    var decompressed = fixedBufferStream(&dcm_buf);

                    try inflate.decompress(wrap, compressed.reader(), decompressed.writer());

                    try testing.expectEqualSlices(u8, data, decompressed.getWritten());
                }

                // compressor writer interface
                {
                    var compressed = fixedBufferStream(&cmp_buf);

                    var cmp = try deflate.compressor(wrap, compressed.writer(), level);
                    var cmp_wrt = cmp.writer();
                    try cmp_wrt.writeAll(data);
                    try cmp.close();

                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompressor reader interface
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);

                    var dcm = inflate.inflate(wrap, compressed.reader());
                    var dcm_rdr = dcm.reader();
                    const n = try dcm_rdr.readAll(&dcm_buf);

                    try testing.expectEqual(data.len, n);
                    try testing.expectEqualSlices(u8, data, dcm_buf[0..n]);
                }
            }
        }
        // huffman only compression
        {
            const gzip_size = case.huffman_only_size;

            inline for (Wrapper.list) |wrap| { // for each wrapping
                const compressed_size = gzip_size - Wrapper.gzip.size() + wrap.size();

                // compress original stream to compressed stream
                {
                    var original = fixedBufferStream(data);
                    var compressed = fixedBufferStream(&cmp_buf);

                    try deflate.compressHuffmanOnly(wrap, original.reader(), compressed.writer());

                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompress compressed stream to decompressed stream
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);
                    var decompressed = fixedBufferStream(&dcm_buf);

                    try inflate.decompress(wrap, compressed.reader(), decompressed.writer());

                    try testing.expectEqualSlices(u8, data, decompressed.getWritten());
                }

                // compressor writer interface
                {
                    var compressed = fixedBufferStream(&cmp_buf);

                    var cmp = try deflate.huffmanOnlyCompressor(wrap, compressed.writer());
                    var cmp_wrt = cmp.writer();
                    try cmp_wrt.writeAll(data);
                    try cmp.close();

                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompressor reader interface
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);

                    var dcm = inflate.inflate(wrap, compressed.reader());
                    var dcm_rdr = dcm.reader();
                    const n = try dcm_rdr.readAll(&dcm_buf);

                    try testing.expectEqual(data.len, n);
                    try testing.expectEqualSlices(u8, data, dcm_buf[0..n]);
                }
            }
        }
    }
}
