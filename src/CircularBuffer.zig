const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Sliding window of decoded data. Or maybe better described as circular buffer.
/// Contains 64K bytes. Deflate limits:
///  * non-compressible block is limited to 65,535 bytes.
///  * backward pointer is limited in distance to 32K bytes and in length to 258 bytes.
///
/// Whole non-compressed block can be written without overlap. We always have
/// history of up to 64K, more then 32K needed.
///
/// Reads can return less than available bytes if they are spread across
/// different circles. So reads should repeat until get required number of bytes
/// or until returned slice is zero length.
///
const mask = 0xffff; // 64K - 1
const buffer_len = mask + 1; // 64K buffer

const Self = @This();

buffer: [buffer_len]u8 = undefined,
wp: usize = 0, // write position
rp: usize = 0, // read position

inline fn writeAll(self: *Self, buf: []const u8) void {
    for (buf) |c| self.write(c);
}

// Write literal.
pub inline fn write(self: *Self, b: u8) void {
    assert(self.wp - self.rp < mask);
    self.buffer[self.wp & mask] = b;
    self.wp += 1;
}

// Write match (backreference to the same data slice) starting at `distance`
// back from current write position, and `length` of bytes.
pub fn writeMatch(self: *Self, length: u16, distance: u16) void {
    assert(self.wp - self.rp < mask);
    assert(self.wp >= distance);

    var from: usize = self.wp - distance;
    const from_end: usize = from + length;
    var to: usize = self.wp;
    const to_end: usize = to + length;

    self.wp += length;

    // Fast path using memcpy
    if (length <= distance and // no overlapping buffers
        (from >> 16 == from_end >> 16) and // start and and at the same circle
        (to >> 16 == to_end >> 16))
    {
        @memcpy(self.buffer[to & mask .. to_end & mask], self.buffer[from & mask .. from_end & mask]);
        return;
    }

    // Slow byte by byte
    while (to < to_end) {
        self.buffer[to & mask] = self.buffer[from & mask];
        to += 1;
        from += 1;
    }
}

// Retruns writable part of the internal buffer of size `n` at most. Advanjces
// write pointer, assumes that returned buffer will be filled with data.
pub fn getWritable(self: *Self, n: usize) []u8 {
    const wp = self.wp & mask;
    const len = @min(n, buffer_len - wp);
    self.wp += len;
    return self.buffer[wp .. wp + len];
}

// Read available data. Can return part of the available data if it is
// spread across two circles. So read until this returns zero length.
pub fn read(self: *Self) []const u8 {
    return self.readAtMost(buffer_len);
}

// Read part of available data. Can return less than max even if there are
// more than max decoded data.
pub fn readAtMost(self: *Self, limit: usize) []const u8 {
    const rb = self.readBlock(if (limit == 0) buffer_len else limit);
    defer self.rp += rb.len;
    return self.buffer[rb.head..rb.tail];
}

const ReadBlock = struct {
    head: usize,
    tail: usize,
    len: usize,
};

// Returns position of continous read block data.
inline fn readBlock(self: *Self, max: usize) ReadBlock {
    const r = self.rp & mask;
    const w = self.wp & mask;
    const n = @min(
        max,
        if (w >= r) w - r else buffer_len - r,
    );
    return .{
        .head = r,
        .tail = r + n,
        .len = n,
    };
}

// Number of free bytes for write.
pub inline fn free(self: *Self) usize {
    return buffer_len - (self.wp - self.rp);
}

// example from: https://youtu.be/SJPvNi4HrWQ?t=3558
test "CircularBuffer copy" {
    var sw: Self = .{};

    sw.writeAll("a salad; ");
    sw.writeMatch(5, 9);
    sw.writeMatch(2, 3);

    try testing.expectEqualStrings("a salad; a salsa", sw.read());
}

test "CircularBuffer copy overlap" {
    var sw: Self = .{};

    sw.writeAll("a b c ");
    sw.writeMatch(8, 4);
    sw.write('d');

    try testing.expectEqualStrings("a b c b c b c d", sw.read());
}

test "CircularBuffer readAtMost" {
    var sw: Self = .{};

    sw.writeAll("0123456789");
    sw.writeMatch(50, 10);

    try testing.expectEqualStrings("0123456789" ** 6, sw.buffer[sw.rp..sw.wp]);
    for (0..6) |i| {
        try testing.expectEqual(i * 10, sw.rp);
        try testing.expectEqualStrings("0123456789", sw.readAtMost(10));
    }
    try testing.expectEqualStrings("", sw.readAtMost(10));
    try testing.expectEqualStrings("", sw.read());
}

test "CircularBuffer circular buffer" {
    var sw: Self = .{};

    const data = "0123456789abcdef" ** (1024 / 16);
    sw.writeAll(data);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024 * 63), sw.free());

    sw.writeMatch(62 * 1024, 1024);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 63 * 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.free());

    sw.writeAll(data[0..200]);
    _ = sw.readAtMost(1024); // make some space
    sw.writeAll(data); // overflows write position
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.rp);
    try testing.expectEqual(@as(usize, 1024 - 200), sw.free());

    const rb = sw.readBlock(Self.buffer_len);
    try testing.expectEqual(@as(usize, 65536 - 1024), rb.len);
    try testing.expectEqual(@as(usize, 1024), rb.head);
    try testing.expectEqual(@as(usize, 65536), rb.tail);

    try testing.expectEqual(@as(usize, 65536 - 1024), sw.read().len); // read to the end of the buffer
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 65536), sw.rp);
    try testing.expectEqual(@as(usize, 65536 - 200), sw.free());

    try testing.expectEqual(@as(usize, 200), sw.read().len); // read the rest
}

test "CircularBuffer write over border" {
    var sw: Self = .{};
    sw.wp = sw.buffer.len - 15;
    sw.rp = sw.wp;

    sw.writeAll("0123456789");
    sw.writeAll("abcdefghij");

    try testing.expectEqual(sw.buffer.len + 5, sw.wp);
    try testing.expectEqual(sw.buffer.len - 15, sw.rp);

    try testing.expectEqualStrings("0123456789abcde", sw.read());
    try testing.expectEqualStrings("fghij", sw.read());

    try testing.expect(sw.wp == sw.rp);
}

test "CircularBuffer copy over border" {
    var sw: Self = .{};
    sw.wp = sw.buffer.len - 15;
    sw.rp = sw.wp;

    sw.writeAll("0123456789");
    sw.writeMatch(15, 5);

    try testing.expectEqualStrings("012345678956789", sw.read());
    try testing.expectEqualStrings("5678956789", sw.read());

    sw.writeMatch(20, 25);
    try testing.expectEqualStrings("01234567895678956789", sw.read());
}
