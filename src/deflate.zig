const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const min_match_length = 4;
const max_match_length = 258;

const min_match_distance = 1;
const max_match_distance = 32768;

const log_window_size = 15;
const window_size = 1 << log_window_size;
const window_mask = window_size - 1;

const Token = packed struct {
    const Kind = enum(u2) {
        literal,
        end_of_block,
        backreference,
    };

    dc: u16 = 0, // distance code: 1 - 32768
    lc_sym: u8 = 0, // length code: 3 - 258, or symbol
    kind: Kind = .literal,

    pub fn symbol(t: Token) u8 {
        return t.lc_sym;
    }

    pub fn distance(t: Token) usize {
        return if (t.kind == .backreference) t.dc + min_match_distance else 0;
    }

    pub fn length(t: Token) usize {
        return if (t.kind == .backreference) t.lc_sym + min_match_length else 1;
    }

    pub fn literal(sym: u8) Token {
        return .{ .kind = .literal, .lc_sym = sym };
    }

    pub fn backreference(dis: usize, len: usize) Token {
        assert(len > min_match_length and len < max_match_length);
        assert(dis > min_match_length and dis < max_match_distance);
        return .{
            .kind = .backreference,
            .dc = @intCast(dis - min_match_distance),
            .lc_sym = @intCast(len - min_match_length),
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
};

test "Token size" {
    try expect(@sizeOf(Token) == 4);
    try expect(@bitSizeOf(Token) == 26);
}

fn deflate(src: []const u8, tokens: []Token) usize {
    var tp: usize = 0;
    var pos: usize = 0;
    var hasher: Hasher = .{};
    while (pos < src.len) {
        var t = Token.literal(src[pos]);
        var l: usize = 1;

        var prev = hasher.add(src[pos..], @intCast(pos));
        while (prev != Hasher.not_found) {
            const ml = matchLength(src, prev, pos);
            if (ml > min_match_length and ml > l) {
                t = Token.backreference(pos - prev, ml);
                l = ml;
            }
            prev = hasher.prev[prev];
        }

        tokens[tp] = t;
        tp += 1;

        pos += l;
    }
    return tp;
}

test "deflate" {
    const L = Token.literal;
    const R = Token.backreference;

    const cases = [_]struct {
        data: []const u8,
        tokens: []const Token,
    }{
        .{
            .data = "Blah blah blah blah blah!",
            .tokens = &[_]Token{ L('B'), L('l'), L('a'), L('h'), L(' '), L('b'), R(5, 18), L('!') },
        },
    };

    for (cases) |c| {
        var tokens: [64]Token = undefined;
        const n = deflate(c.data, &tokens);

        try expect(n == c.tokens.len);
        for (c.tokens, 0..) |t, i| {
            try expect(t.eql(tokens[i]));
            // if (t.kind == .literal) {
            //     std.debug.print("literal: {c}\n", .{t.symbol()});
            // } else {
            //     std.debug.print("back reference: {d} {d}\n", .{ t.distance(), t.length() });
            // }
        }
    }
}

fn matchLength(src: []const u8, prev: usize, pos: usize) u16 {
    assert(prev < pos);
    assert(src.len > pos);

    var n: u16 = 0;
    for (src[prev .. prev + src.len - pos], src[pos..src.len]) |a, b| {
        if (a != b) return n;
        n += 1;
    }
    return n;
}

const StreamWindow = struct {
    const buffer_len = 2 * window_size;
    const max_rp = buffer_len - (min_match_length + max_match_length);

    buffer: [2 * window_size]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position

    pub fn write(self: *StreamWindow, buf: []const u8) usize {
        if (self.rp >= max_rp) return 0; // need to slide

        const n = @min(buf.len, buffer_len - self.wp);
        @memcpy(self.buffer[self.wp .. self.wp + n], buf[0..n]);
        self.wp += n;
        return n;
    }

    pub fn slide(self: *StreamWindow) usize {
        assert(self.rp >= max_rp and self.wp >= self.rp);
        const n = self.wp - window_size;
        @memcpy(self.buffer[0..n], self.buffer[window_size..self.wp]);
        self.rp -= window_size;
        self.wp -= window_size;
        return n;
    }

    pub fn lookahead(self: *StreamWindow) []const u8 {
        assert(self.wp >= self.rp);
        return self.buffer[self.rp..self.wp];
    }

    pub fn history(self: *StreamWindow) []const u8 {
        return self.buffer[0..self.rp];
    }

    pub fn advance(self: *StreamWindow, n: usize) void {
        assert(self.wp >= self.rp + n);
        self.rp += n;
    }

    // Finds match length between prev position and pos.
    pub fn match(self: *StreamWindow, prev: usize, pos: usize) usize {
        var p1: usize = prev;
        var p2: usize = pos;
        var n: usize = 0;
        while (self.buffer[p1] == self.buffer[p2]) {
            n += 1;
            if (p2 == self.wp) break;
            p1 += 1;
            p2 += 1;
        }
        return n;
    }
};

test "StreamWindow match" {
    const data = "Blah blah blah blah blah!";
    var win: StreamWindow = .{};
    try expect(win.write(data) == data.len);
    try expect(win.wp == data.len);
    try expect(win.rp == 0);

    // length between l symbols
    try expect(win.match(1, 6) == 18);
    try expect(win.match(1, 11) == 13);
    try expect(win.match(1, 16) == 8);
    try expect(win.match(1, 21) == 3);
}

test "StreamWindow slide" {
    var win: StreamWindow = .{};
    win.wp = StreamWindow.buffer_len - 11;
    win.rp = StreamWindow.buffer_len - 111;
    win.buffer[win.rp] = 0xab;
    try expect(win.lookahead().len == 100);

    const n = win.slide();
    try expect(win.buffer[win.rp] == 0xab);
    try expect(n == window_size - 11);
    try expect(win.rp == window_size - 111);
    try expect(win.wp == window_size - 11);
    try expect(win.lookahead().len == 100);
    try expect(win.history().len == win.rp);
}

const Hasher = struct {
    const mul = 0x1e35a7bd;
    const bits = 17;
    const shift = 32 - bits;
    const mask = (1 << bits) - 1;
    const size = 1 << bits;
    const not_found = window_mask;

    head: [size]u16 = [_]u16{not_found} ** size,
    prev: [window_size]u16 = [_]u16{not_found} ** window_size,

    fn add(self: *Hasher, data: []const u8, idx: u16) u16 {
        if (data.len < 4) return not_found;
        const h = hash(data[0..4]);
        const p = self.head[h];
        self.head[h] = idx;
        self.prev[idx] = p;
        return p;
    }

    fn hash(b: *const [4]u8) u32 {
        return (((@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24) *% mul) >> shift) & mask;
    }

    fn bulk(b: []u8, dst: []u32) u32 {
        if (b.len < min_match_length) {
            return 0;
        }
        var hb =
            @as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24;

        dst[0] = (hb *% mul) >> (32 - bits);
        const end = b.len - min_match_length + 1;
        var i: u32 = 1;
        while (i < end) : (i += 1) {
            hb = (hb << 8) | @as(u32, b[i + 3]);
            dst[i] = (hb *% mul) >> (32 - bits);
        }
        return hb;
    }
};

test "Hasher" {
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03,
    };

    var h: Hasher = .{};
    for (data, 0..) |_, i| {
        const prev = h.add(data[i..], @intCast(i));
        if (i >= 8 and i < 24) {
            try testing.expect(prev == i - 8);
        } else {
            try testing.expect(prev == Hasher.not_found);
        }
    }

    const v = Hasher.hash(data[2 .. 2 + 4]);
    try testing.expect(h.head[v] == 2 + 16);
    try testing.expect(h.prev[2 + 16] == 2 + 8);
    try testing.expect(h.prev[2 + 8] == 2);
}
