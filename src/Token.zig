const std = @import("std");
const assert = std.debug.assert;
const consts = @import("consts.zig");

// Retruns index in match_lengths table for each length in range 0-255.
const match_lengths_index = [_]u8{
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

const MatchLength = struct {
    code: u16,
    base: u8,
    extra_length: u8 = 0,
    extra_bits: u4,
};

// match_lengths represents table from rfc (https://datatracker.ietf.org/doc/html/rfc1951#page-12)
//
//      Extra               Extra               Extra
// Code Bits Length(s) Code Bits Lengths   Code Bits Length(s)
// ---- ---- ------     ---- ---- -------   ---- ---- -------
//  257   0     3       267   1   15,16     277   4   67-82
//  258   0     4       268   1   17,18     278   4   83-98
//  259   0     5       269   2   19-22     279   4   99-114
//  260   0     6       270   2   23-26     280   4  115-130
//  261   0     7       271   2   27-30     281   5  131-162
//  262   0     8       272   2   31-34     282   5  163-194
//  263   0     9       273   3   35-42     283   5  195-226
//  264   0    10       274   3   43-50     284   5  227-257
//  265   1  11,12      275   3   51-58     285   0    258
//  266   1  13,14      276   3   59-66
//
// Base length is scaled down for 3, same as lit_len field in Token.
//
pub const length_codes_start = 257;

const match_lengths = [_]MatchLength{
    .{ .extra_bits = 0, .base = 0, .code = 0 + length_codes_start },
    .{ .extra_bits = 0, .base = 1, .code = 1 + length_codes_start },
    .{ .extra_bits = 0, .base = 2, .code = 2 + length_codes_start },
    .{ .extra_bits = 0, .base = 3, .code = 3 + length_codes_start },
    .{ .extra_bits = 0, .base = 4, .code = 4 + length_codes_start },
    .{ .extra_bits = 0, .base = 5, .code = 5 + length_codes_start },
    .{ .extra_bits = 0, .base = 6, .code = 6 + length_codes_start },
    .{ .extra_bits = 0, .base = 7, .code = 7 + length_codes_start },
    .{ .extra_bits = 1, .base = 8, .code = 8 + length_codes_start },
    .{ .extra_bits = 1, .base = 10, .code = 9 + length_codes_start },
    .{ .extra_bits = 1, .base = 12, .code = 10 + length_codes_start },
    .{ .extra_bits = 1, .base = 14, .code = 11 + length_codes_start },
    .{ .extra_bits = 2, .base = 16, .code = 12 + length_codes_start },
    .{ .extra_bits = 2, .base = 20, .code = 13 + length_codes_start },
    .{ .extra_bits = 2, .base = 24, .code = 14 + length_codes_start },
    .{ .extra_bits = 2, .base = 28, .code = 15 + length_codes_start },
    .{ .extra_bits = 3, .base = 32, .code = 16 + length_codes_start },
    .{ .extra_bits = 3, .base = 40, .code = 17 + length_codes_start },
    .{ .extra_bits = 3, .base = 48, .code = 18 + length_codes_start },
    .{ .extra_bits = 3, .base = 56, .code = 19 + length_codes_start },
    .{ .extra_bits = 4, .base = 64, .code = 20 + length_codes_start },
    .{ .extra_bits = 4, .base = 80, .code = 21 + length_codes_start },
    .{ .extra_bits = 4, .base = 96, .code = 22 + length_codes_start },
    .{ .extra_bits = 4, .base = 112, .code = 23 + length_codes_start },
    .{ .extra_bits = 5, .base = 128, .code = 24 + length_codes_start },
    .{ .extra_bits = 5, .base = 160, .code = 25 + length_codes_start },
    .{ .extra_bits = 5, .base = 192, .code = 26 + length_codes_start },
    .{ .extra_bits = 5, .base = 224, .code = 27 + length_codes_start },
    .{ .extra_bits = 0, .base = 255, .code = 28 + length_codes_start },
};

// Used in offsetCode fn to get index in match_offset table for each offset in range 0-32767.
const match_offsets_index = [_]u8{
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

const MatchOffset = struct {
    base: u16,
    extra_offset: u16 = 0,
    code: u8,
    extra_bits: u4,
};

// match_offsets represents table from rfc (https://datatracker.ietf.org/doc/html/rfc1951#page-12)
//
//      Extra           Extra               Extra
// Code Bits Dist  Code Bits   Dist     Code Bits Distance
// ---- ---- ----  ---- ----  ------    ---- ---- --------
//   0   0    1     10   4     33-48    20    9   1025-1536
//   1   0    2     11   4     49-64    21    9   1537-2048
//   2   0    3     12   5     65-96    22   10   2049-3072
//   3   0    4     13   5     97-128   23   10   3073-4096
//   4   1   5,6    14   6    129-192   24   11   4097-6144
//   5   1   7,8    15   6    193-256   25   11   6145-8192
//   6   2   9-12   16   7    257-384   26   12  8193-12288
//   7   2  13-16   17   7    385-512   27   12 12289-16384
//   8   3  17-24   18   8    513-768   28   13 16385-24576
//   9   3  25-32   19   8   769-1024   29   13 24577-32768
//
// Base distance is scaled down by 1, same as Token off field.
//
const match_offsets = [_]MatchOffset{
    .{ .extra_bits = 0, .base = 0x0000, .code = 0 },
    .{ .extra_bits = 0, .base = 0x0001, .code = 1 },
    .{ .extra_bits = 0, .base = 0x0002, .code = 2 },
    .{ .extra_bits = 0, .base = 0x0003, .code = 3 },
    .{ .extra_bits = 1, .base = 0x0004, .code = 4 },
    .{ .extra_bits = 1, .base = 0x0006, .code = 5 },
    .{ .extra_bits = 2, .base = 0x0008, .code = 6 },
    .{ .extra_bits = 2, .base = 0x000c, .code = 7 },
    .{ .extra_bits = 3, .base = 0x0010, .code = 8 },
    .{ .extra_bits = 3, .base = 0x0018, .code = 9 },
    .{ .extra_bits = 4, .base = 0x0020, .code = 10 },
    .{ .extra_bits = 4, .base = 0x0030, .code = 11 },
    .{ .extra_bits = 5, .base = 0x0040, .code = 12 },
    .{ .extra_bits = 5, .base = 0x0060, .code = 13 },
    .{ .extra_bits = 6, .base = 0x0080, .code = 14 },
    .{ .extra_bits = 6, .base = 0x00c0, .code = 15 },
    .{ .extra_bits = 7, .base = 0x0100, .code = 16 },
    .{ .extra_bits = 7, .base = 0x0180, .code = 17 },
    .{ .extra_bits = 8, .base = 0x0200, .code = 18 },
    .{ .extra_bits = 8, .base = 0x0300, .code = 19 },
    .{ .extra_bits = 9, .base = 0x0400, .code = 20 },
    .{ .extra_bits = 9, .base = 0x0600, .code = 21 },
    .{ .extra_bits = 10, .base = 0x0800, .code = 22 },
    .{ .extra_bits = 10, .base = 0x0c00, .code = 23 },
    .{ .extra_bits = 11, .base = 0x1000, .code = 24 },
    .{ .extra_bits = 11, .base = 0x1800, .code = 25 },
    .{ .extra_bits = 12, .base = 0x2000, .code = 26 },
    .{ .extra_bits = 12, .base = 0x3000, .code = 27 },
    .{ .extra_bits = 13, .base = 0x4000, .code = 28 },
    .{ .extra_bits = 13, .base = 0x6000, .code = 29 },
};

const Token = @This();

pub const Kind = enum(u1) {
    literal,
    match,
};

// offset range 1 - 32768, stored in off as 0 - 32767 (u16)
off: u15 = 0,
// length range 3 - 258, stored in len_lit as 0 - 255 (u8)
len_lit: u8 = 0,
kind: Kind = .literal,

pub fn literal(t: Token) u8 {
    return t.len_lit;
}

pub fn offset(t: Token) u16 {
    return @as(u16, t.off) + consts.match.min_distance;
}

pub fn length(t: Token) u16 {
    return @as(u16, t.len_lit) + consts.match.base_length;
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

pub fn lengthCode(t: Token) u16 {
    return @as(u16, match_lengths_index[t.len_lit]) + length_codes_start;
}

pub fn lengthEncoding(t: Token) MatchLength {
    var c = match_lengths[match_lengths_index[t.len_lit]];
    c.extra_length = t.len_lit - c.base;
    return c;
}

// Returns the offset code corresponding to a specific offset.
// Offset code is in range: 0 - 29.
pub fn offsetCode(t: Token) u8 {
    var off: u16 = t.off;
    if (off < match_offsets_index.len) {
        return match_offsets_index[off];
    }
    off >>= 7;
    if (off < match_offsets_index.len) {
        return match_offsets_index[off] + 14;
    }
    off >>= 7;
    return match_offsets_index[off] + 28;
}

pub fn offsetEncoding(t: Token) MatchOffset {
    var c = match_offsets[t.offsetCode()];
    c.extra_offset = t.off - c.base;
    return c;
}

pub fn lengthExtraBits(code: u32) u8 {
    return match_lengths[code - length_codes_start].extra_bits;
}

pub fn offsetExtraBits(code: u32) u8 {
    return match_offsets[code].extra_bits;
}

const print = std.debug.print;
const expect = std.testing.expect;

test "Token size" {
    try expect(@sizeOf(Token) == 4);
}

// testing table https://datatracker.ietf.org/doc/html/rfc1951#page-12
test "MatchLength" {
    var c = Token.initMatch(1, 4).lengthEncoding();
    try expect(c.code == 258);
    try expect(c.extra_bits == 0);
    try expect(c.extra_length == 0);

    c = Token.initMatch(1, 11).lengthEncoding();
    try expect(c.code == 265);
    try expect(c.extra_bits == 1);
    try expect(c.extra_length == 0);

    c = Token.initMatch(1, 12).lengthEncoding();
    try expect(c.code == 265);
    try expect(c.extra_bits == 1);
    try expect(c.extra_length == 1);

    c = Token.initMatch(1, 130).lengthEncoding();
    try expect(c.code == 280);
    try expect(c.extra_bits == 4);
    try expect(c.extra_length == 130 - 115);
}

test "MatchOffset" {
    var c = Token.initMatch(1, 4).offsetEncoding();
    try expect(c.code == 0);
    try expect(c.extra_bits == 0);
    try expect(c.extra_offset == 0);

    c = Token.initMatch(192, 4).offsetEncoding();
    try expect(c.code == 14);
    try expect(c.extra_bits == 6);
    try expect(c.extra_offset == 192 - 129);
}
