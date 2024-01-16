const std = @import("std");
const assert = std.debug.assert;
const consts = @import("consts.zig");

// The length code for length X (MIN_MATCH_LENGTH <= X <= MAX_MATCH_LENGTH)
// is length_codes[length - MIN_MATCH_LENGTH]
const length_codes = [_]u32{ // TODO: why u32
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

const offset_codes = [_]u32{ // TODO: why u32
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
    pub const Kind = enum(u1) {
        literal,
        match,
    };

    off: u15 = 0, // offset: (1 - 32768) - 1
    len_lit: u8 = 0, // length: (3 - 258) - 3, or literal
    kind: Kind = .literal,

    pub fn literal(t: Token) u8 {
        return t.len_lit;
    }

    pub fn offset(t: Token) u16 {
        return t.off;
    }

    pub fn length(t: Token) u16 {
        return t.len_lit;
    }

    pub fn initLiteral(lit: u8) Token {
        return .{ .kind = .literal, .len_lit = lit };
    }

    // offset range 1 - 32768, stored in off as 0 - 32767 (u16)
    // length range 3 - 258, stored in len_lit as 0 - 255 (u8)
    pub fn initMatch(off: u16, len: u16) Token {
        assert(len >= consts.match.min_length and len <= consts.match.max_length);
        assert(off >= consts.match.min_distance and off <= consts.match.max_distance);
        return .{
            .kind = .match,
            .off = @intCast(off - consts.match.min_distance),
            .len_lit = @intCast(len - consts.match.base_length),
        };
    }

    pub fn eql(t: Token, o: Token) bool {
        return t.kind == o.kind and
            t.off == o.off and
            t.len_lit == o.len_lit;
    }

    pub fn lengthCode(t: Token) u32 {
        return length_codes[t.len_lit];
    }

    // Returns the offset code corresponding to a specific offset
    pub fn offsetCode(t: Token) u32 {
        var off: u32 = t.off;
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

const print = std.debug.print;

test "Token size" {
    print("bit_offset: {d} {d} {d} size of: {d}\n", .{
        @bitOffsetOf(Token, "off"),
        @bitOffsetOf(Token, "len_lit"),
        @bitOffsetOf(Token, "kind"),
        @sizeOf(Token),
    });
    //try expect(@sizeOf(Token) == 4);
}
