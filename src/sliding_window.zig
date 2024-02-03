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
pub const SlidingWindow = struct {
    const mask = 0xffff; // 64K - 1
    const buffer_len = mask + 1; // 64K buffer

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position

    pub inline fn writeAll(self: *SlidingWindow, buf: []const u8) void {
        for (buf) |c| self.write(c);
    }

    // Write single byte.
    pub inline fn write(self: *SlidingWindow, b: u8) void {
        assert(self.wp - self.rp < mask);
        self.buffer[self.wp & mask] = b;
        self.wp += 1;
    }

    // Write match (backreference to the same data slice) starting at `distance`
    // back from current write position, and `length` of bytes.
    pub fn writeCopy(self: *SlidingWindow, length: u16, distance: u16) void {
        assert(self.wp - self.rp < mask);
        assert(self.wp >= distance);

        var from: usize = self.wp - distance;
        const from_end: usize = from + length;
        var to: usize = self.wp;
        const to_end: usize = to + length;

        self.wp += length;

        // fast path
        if (length <= distance and // no overlapping buffers
            (from >> 16 == from_end >> 16) and // start and and at the same circle
            (to >> 16 == to_end >> 16))
        {
            @memcpy(self.buffer[to & mask .. to_end & mask], self.buffer[from & mask .. from_end & mask]);
            return;
        }

        // slow path
        while (to < to_end) {
            self.buffer[to & mask] = self.buffer[from & mask];
            to += 1;
            from += 1;
        }
    }

    pub fn getWritable(self: *SlidingWindow, n: usize) []u8 {
        const wp = self.wp & mask;
        const len = @min(n, buffer_len - wp);
        self.wp += len;
        return self.buffer[wp .. wp + len];
    }

    // Read available data. Can return part of the available data if it is
    // spread across two circles. So read until this returns zero length.
    pub fn read(self: *SlidingWindow) []const u8 {
        return self.readAtMost(buffer_len);
    }

    // Read part of available data. Can return less than max even if there are
    // more than max decoded data.
    pub fn readAtMost(self: *SlidingWindow, limit: usize) []const u8 {
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
    inline fn readBlock(self: *SlidingWindow, max: usize) ReadBlock {
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
    pub inline fn free(self: *SlidingWindow) usize {
        return buffer_len - (self.wp - self.rp);
    }
};

// example from: https://youtu.be/SJPvNi4HrWQ?t=3558
test "SlidingWindow copy" {
    var sw: SlidingWindow = .{};

    sw.writeAll("a salad; ");
    sw.writeCopy(5, 9);
    sw.writeCopy(2, 3);

    try testing.expectEqualStrings("a salad; a salsa", sw.read());
}

test "SlidingWindow copy overlap" {
    var sw: SlidingWindow = .{};

    sw.writeAll("a b c ");
    sw.writeCopy(8, 4);
    sw.write('d');

    try testing.expectEqualStrings("a b c b c b c d", sw.read());
}

test "SlidingWindow readAtMost" {
    var sw: SlidingWindow = .{};

    sw.writeAll("0123456789");
    sw.writeCopy(50, 10);

    try testing.expectEqualStrings("0123456789" ** 6, sw.buffer[sw.rp..sw.wp]);
    for (0..6) |i| {
        try testing.expectEqual(i * 10, sw.rp);
        try testing.expectEqualStrings("0123456789", sw.readAtMost(10));
    }
    try testing.expectEqualStrings("", sw.readAtMost(10));
    try testing.expectEqualStrings("", sw.read());
}

test "SlidingWindow circular buffer" {
    var sw: SlidingWindow = .{};

    const data = "0123456789abcdef" ** (1024 / 16);
    sw.writeAll(data);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024 * 63), sw.free());

    sw.writeCopy(62 * 1024, 1024);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 63 * 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.free());

    sw.writeAll(data[0..200]);
    _ = sw.readAtMost(1024); // make some space
    sw.writeAll(data); // overflows write position
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.rp);
    try testing.expectEqual(@as(usize, 1024 - 200), sw.free());

    const rb = sw.readBlock(SlidingWindow.buffer_len);
    try testing.expectEqual(@as(usize, 65536 - 1024), rb.len);
    try testing.expectEqual(@as(usize, 1024), rb.head);
    try testing.expectEqual(@as(usize, 65536), rb.tail);

    try testing.expectEqual(@as(usize, 65536 - 1024), sw.read().len); // read to the end of the buffer
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 65536), sw.rp);
    try testing.expectEqual(@as(usize, 65536 - 200), sw.free());

    try testing.expectEqual(@as(usize, 200), sw.read().len); // read the rest
}

test "SlidingWindow write over border" {
    var sw: SlidingWindow = .{};
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

test "SlidingWindow copy over border" {
    var sw: SlidingWindow = .{};
    sw.wp = sw.buffer.len - 15;
    sw.rp = sw.wp;

    sw.writeAll("0123456789");
    sw.writeCopy(15, 5);

    try testing.expectEqualStrings("012345678956789", sw.read());
    try testing.expectEqualStrings("5678956789", sw.read());

    sw.writeCopy(20, 25);
    try testing.expectEqualStrings("01234567895678956789", sw.read());
}
