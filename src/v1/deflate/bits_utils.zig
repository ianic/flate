const math = @import("std").math;

// Reverse bit-by-bit a N-bit code.
pub fn bitReverse(comptime T: type, value: T, N: usize) T {
    const r = @bitReverse(value);
    return r >> @as(math.Log2Int(T), @intCast(@typeInfo(T).Int.bits - N));
}

test "bitReverse" {
    const std = @import("std");

    const ReverseBitsTest = struct {
        in: u16,
        bit_count: u5,
        out: u16,
    };

    const reverse_bits_tests = [_]ReverseBitsTest{
        .{ .in = 1, .bit_count = 1, .out = 1 },
        .{ .in = 1, .bit_count = 2, .out = 2 },
        .{ .in = 1, .bit_count = 3, .out = 4 },
        .{ .in = 1, .bit_count = 4, .out = 8 },
        .{ .in = 1, .bit_count = 5, .out = 16 },
        .{ .in = 17, .bit_count = 5, .out = 17 },
        .{ .in = 257, .bit_count = 9, .out = 257 },
        .{ .in = 29, .bit_count = 5, .out = 23 },
    };

    for (reverse_bits_tests) |h| {
        const v = bitReverse(u16, h.in, h.bit_count);
        try std.testing.expectEqual(h.out, v);
    }
}

/// Copies elements from a source `src` slice into a destination `dst` slice.
/// The copy never returns an error but might not be complete if the destination is too small.
/// Returns the number of elements copied, which will be the minimum of `src.len` and `dst.len`.
/// TODO: remove this smelly function
pub fn copy(dst: []u8, src: []const u8) usize {
    if (dst.len <= src.len) {
        @memcpy(dst, src[0..dst.len]);
        return dst.len;
    } else {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
}
