const deflate = @import("deflate.zig");
const inflate = @import("inflate.zig");

pub const Level = deflate.Level;
pub const Options = deflate.Options;

pub fn decompress(reader: anytype, writer: anytype) !void {
    try inflate.decompress(.raw, reader, writer);
}

pub fn decompressor(reader: anytype) inflate.Inflate(.raw, @TypeOf(reader)) {
    return inflate.decompressor(.raw, reader);
}

pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
    try deflate.compress(.raw, reader, writer, options);
}

pub fn compressor(writer: anytype, options: Options) !void {
    try deflate.compressor(.raw, writer, options);
}

pub const gzip = struct {
    pub fn decompress(reader: anytype, writer: anytype) !void {
        try inflate.decompress(.gzip, reader, writer);
    }

    pub fn decompressor(reader: anytype) inflate.Inflate(.gzip, @TypeOf(reader)) {
        return inflate.decompressor(.gzip, reader);
    }

    pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
        try deflate.compress(.gzip, reader, writer, options);
    }

    pub fn compressor(writer: anytype, options: Options) !deflate.Compressor(.gzip, @TypeOf(writer)) {
        return try deflate.compressor(.gzip, writer, options);
    }
};

pub const zlib = struct {
    pub fn decompress(reader: anytype, writer: anytype) !void {
        try inflate.decompress(.zlib, reader, writer);
    }

    pub fn decompressor(reader: anytype) inflate.Inflate(.zlib, @TypeOf(reader)) {
        return inflate.decompressor(.zlib, reader);
    }

    pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
        try deflate.compress(.zlib, reader, writer, options);
    }

    pub fn compressor(writer: anytype, options: Options) !deflate.Compressor(.zlib, @TypeOf(writer)) {
        return try deflate.compressor(.zlib, writer, options);
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
        [_]u8{ 0x47, 0x04, 0xf2, 0x1c }; // zlib footer: checksum

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
        try testing.expectEqualStrings(expected, (try cmp.nextChunk()).?);
        try testing.expect((try cmp.nextChunk()) == null);
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
    // gzip decompressor
    {
        gzip_in.reset();
        var cmp = gzip.decompressor(gzip_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
    // zlib decompressor
    {
        zlib_in.reset();
        var cmp = zlib.decompressor(zlib_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
}
