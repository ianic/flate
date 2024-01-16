const std = @import("std");
const assert = std.debug.assert;

// TODO: remove to common place
const limits = struct {
    const block = struct {
        const tokens = 1 << 14;
    };
    const match = struct {
        const base_length = 3; // smallest match length per the RFC section 3.2.5
        const min_length = 4; // min length used in this algorithm
        const max_length = 258;

        const min_distance = 1;
        const max_distance = 32768;
    };
    const window = struct { // TODO: consider renaming this into history
        const bits = 15;
        const size = 1 << bits;
        const mask = size - 1;
    };
    const hash = struct {
        const bits = 17;
        const size = 1 << bits;
        const mask = size - 1;
        const shift = 32 - bits;
    };
};

// The length code for length X (MIN_MATCH_LENGTH <= X <= MAX_MATCH_LENGTH)
// is length_codes[length - MIN_MATCH_LENGTH]
const length_codes = [_]u32{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  8,
    9,  9,  10, 10, 11, 11, 12, 12, 12, 12,
    13, 13, 13, 13, 14, 14, 14, 14, 15, 15,
    15, 15, 16, 16, 16, 16, 16, 16, 16, 16,
    17, 17, 17, 17, 17, 17, 17, 17, 18, 18,
    18, 18, 18, 18, 18, 18, 19, 19, 19, 19,
    19, 19, 19, 19, 20, 20, 20, 20, 20, 20,
    20, 20, 20, 20, 20, 20, 20, 20, 20, 20,
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
    21, 21, 21, 21, 21, 21, 22, 22, 22, 22,
    22, 22, 22, 22, 22, 22, 22, 22, 22, 22,
    22, 22, 23, 23, 23, 23, 23, 23, 23, 23,
    23, 23, 23, 23, 23, 23, 23, 23, 24, 24,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
    25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
    25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
    25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
    25, 25, 26, 26, 26, 26, 26, 26, 26, 26,
    26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
    26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
    26, 26, 26, 26, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 28,
};

const offset_codes = [_]u32{
    0,  1,  2,  3,  4,  4,  5,  5,  6,  6,  6,  6,  7,  7,  7,  7,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
};

pub const Token = struct {
    pub const Kind = enum(u2) {
        literal,
        match,
        end_of_block,
    };

    dc: u16 = 0, // distance code: (1 - 32768) - 1
    lc_sym: u8 = 0, // length code: (3 - 258) - 3, or symbol
    kind: Kind = .literal,

    pub fn symbol(t: Token) u8 {
        return t.lc_sym;
    }

    pub fn distance(t: Token) u16 {
        return if (t.kind == .match) @as(u16, t.dc) + limits.match.min_distance else 0;
    }

    pub fn length(t: Token) u16 {
        return if (t.kind == .match) @as(u16, t.lc_sym) + limits.match.base_length else 1;
    }

    pub fn initLiteral(sym: u8) Token {
        return .{ .kind = .literal, .lc_sym = sym };
    }

    pub fn initMatch(dis: usize, len: usize) Token {
        assert(len >= limits.match.min_length and len <= limits.match.max_length);
        assert(dis >= limits.match.min_distance and dis <= limits.match.max_distance);
        return .{
            .kind = .match,
            .dc = @intCast(dis - limits.match.min_distance),
            .lc_sym = @intCast(len - limits.match.base_length),
        };
    }

    pub fn endOfBlock() Token {
        return .{ .kind = .end_of_block };
    }

    pub fn eql(t: Token, o: Token) bool {
        return t.kind == o.kind and
            t.dc == o.dc and
            t.lc_sym == o.lc_sym;
    }

    pub fn string(t: Token) void {
        switch (t.kind) {
            .literal => std.debug.print("L('{c}') \n", .{t.symbol()}),
            .match => std.debug.print("R({d}, {d}) \n", .{ t.distance(), t.length() }),
            .end_of_block => std.debug.print("E()", .{}),
        }
    }

    pub fn lengthCode(t: Token) u32 {
        return length_codes[t.lc_sym];
    }

    // Returns the offset code corresponding to a specific offset
    pub fn offsetCode(t: Token) u32 {
        var off: u32 = t.dc;
        if (off < @as(u32, @intCast(offset_codes.len))) {
            return offset_codes[off];
        }
        off >>= 7;
        if (off < @as(u32, @intCast(offset_codes.len))) {
            return offset_codes[off] + 14;
        }
        off >>= 7;
        return offset_codes[off] + 28;
    }
};
