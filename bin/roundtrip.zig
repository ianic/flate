const std = @import("std");
const flate = @import("compress").flate;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const levels = [_]flate.Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };

    // For each compression level
    for (levels) |level| {
        var fbs = std.io.fixedBufferStream(data);

        // Compress the data
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try flate.compress(fbs.reader(), buf.writer(), level);

        // Now try to decompress it
        var buf_fbs = std.io.fixedBufferStream(buf.items);
        var inflate = flate.decompressor(buf_fbs.reader());
        const inflated = try inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(inflated);

        try std.testing.expectEqualSlices(u8, data, inflated);
        std.debug.print("{}, original: {d}, compressed: {d}\n", .{ level, data.len, buf.items.len });
    }

    // Huffman only compression
    {
        var fbs = std.io.fixedBufferStream(data);
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        // Compress the data
        var cmp = try flate.huffman.compressor(buf.writer());
        try cmp.compress(fbs.reader());
        try cmp.close();

        // Now try to decompress it
        var buf_fbs = std.io.fixedBufferStream(buf.items);
        var inflate = flate.decompressor(buf_fbs.reader());
        const inflated = try inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(inflated);

        try std.testing.expectEqualSlices(u8, data, inflated);
        std.debug.print("huffman only original: {d}, compressed {d}\n", .{ data.len, buf.items.len });
    }

    // Store only, no compression
    {
        var fbs = std.io.fixedBufferStream(data);
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        // Compress the data
        var cmp = try flate.store.compressor(buf.writer());
        try cmp.compress(fbs.reader());
        try cmp.close();

        // Now try to decompress it
        var buf_fbs = std.io.fixedBufferStream(buf.items);
        var inflate = flate.decompressor(buf_fbs.reader());
        const inflated = try inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(inflated);

        try std.testing.expectEqualSlices(u8, data, inflated);
        std.debug.print("store original: {d}, stored {d}\n", .{ data.len, buf.items.len });
    }
}
