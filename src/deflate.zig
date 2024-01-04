const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const limits = struct {
    const block = struct {
        const tokens = 1 << 14;
    };
    const match = struct {
        const min_length = 4;
        const max_length = 258;
        const min_distance = 1;
        const max_distance = 32768;
    };
    const window = struct {
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

pub fn deflate(writer: anytype) Deflate(@TypeOf(writer)) {
    return Deflate(@TypeOf(writer)).init(writer);
}

pub fn Deflate(comptime WriterType: type) type {
    return struct {
        hasher: Hasher = .{},
        win: StreamWindow = .{},
        tokens: Tokens = .{},

        const Self = @This();
        pub fn init(w: WriterType) Self {
            _ = w;
            return .{};
        }

        fn tokenize(self: *Self) bool {
            const L = Token.literal;
            const R = Token.backreference;

            while (!self.tokens.full()) {
                const lh = self.win.lookahead();
                if (lh.len == 0) return false;

                var token = L(lh[0]);
                var length: usize = 1;

                const pos = self.win.pos();
                var prev = self.hasher.add(lh, @intCast(pos));
                while (prev != Hasher.not_found) {
                    const d = pos - prev;
                    if (d > limits.match.max_distance) break;
                    const l = self.win.match(prev, pos);
                    if (l > length) {
                        token = R(d, l);
                        length = l;
                    }
                    prev = self.hasher.prev(prev);
                }

                self.win.advance(length);
                if (length > 1)
                    self.hasher.bulkAdd(lh[1..], length - 1, @intCast(pos + 1));

                self.tokens.add(token);
                //token.string();
            }
            return true;
        }

        fn step(self: *Self) !void {
            while (self.tokenize())
                try self.flush();
        }

        fn flush(self: *Self) !void {
            self.tokens.reset();
        }

        pub fn close(self: *Self) !void {
            try self.step();
        }

        pub fn write(self: *Self, input: []const u8) !usize {
            var buf = input;

            while (buf.len > 0) {
                try self.step();
                const n = self.win.write(buf);
                if (n == 0) {
                    const j = self.win.slide();
                    self.hasher.slide(@intCast(j));
                    continue;
                }
                buf = buf[n..];
            }

            return input.len;
        }

        // Writer interface

        pub const Writer = std.io.Writer(*Self, Error, write);
        pub const Error = WriterType.Error;

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

fn tokenize(src: []const u8, tokens: *Tokens) void {
    const L = Token.literal;
    const R = Token.backreference;

    var hasher: Hasher = .{};
    var win: StreamWindow = .{};
    assert(win.write(src) == src.len);

    while (true) {
        const lh = win.lookahead();
        if (lh.len == 0) break;

        var token = L(lh[0]);
        var length: usize = 1;

        const pos = win.pos();
        var prev = hasher.add(lh, @intCast(pos));
        while (prev != Hasher.not_found) {
            const l = win.match(prev, pos);
            if (l > length) {
                token = R(pos - prev, l);
                length = l;
            }
            prev = hasher.prev(prev);
        }

        tokens.add(token);
        win.advance(length);
        if (length > 0)
            hasher.bulkAdd(lh[1..], length - 1, @intCast(pos + 1));
    }
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
        var tokens: Tokens = .{};
        tokenize(c.data, &tokens);

        try expect(tokens.len() == c.tokens.len);
        for (c.tokens, 0..) |t, i| {
            try expect(t.eql(tokens.at(i)));
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
    const hist_len = limits.window.size;
    const buffer_len = 2 * hist_len;
    const max_rp = buffer_len - (limits.match.min_length + limits.match.max_length);

    buffer: [buffer_len]u8 = undefined,
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
        const n = self.wp - hist_len;
        @memcpy(self.buffer[0..n], self.buffer[hist_len..self.wp]);
        self.rp -= hist_len;
        self.wp -= hist_len;
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

    // Finds match length between previous and current position.
    pub fn match(self: *StreamWindow, prev: usize, curr: usize) usize {
        var p1: usize = prev;
        var p2: usize = curr;
        var n: usize = 0;
        while (p2 < self.wp and self.buffer[p1] == self.buffer[p2] and n < limits.match.max_length) {
            n += 1;
            p1 += 1;
            p2 += 1;
        }
        return if (n > limits.match.min_length) n else 0;
    }

    pub fn pos(self: *StreamWindow) usize {
        return self.rp;
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
    try expect(win.match(1, 21) == 0);
}

test "StreamWindow slide" {
    var win: StreamWindow = .{};
    win.wp = StreamWindow.buffer_len - 11;
    win.rp = StreamWindow.buffer_len - 111;
    win.buffer[win.rp] = 0xab;
    try expect(win.lookahead().len == 100);

    const n = win.slide();
    try expect(win.buffer[win.rp] == 0xab);
    try expect(n == StreamWindow.hist_len - 11);
    try expect(win.rp == StreamWindow.hist_len - 111);
    try expect(win.wp == StreamWindow.hist_len - 11);
    try expect(win.lookahead().len == 100);
    try expect(win.history().len == win.rp);
}

const Hasher = struct {
    const mul = 0x1e35a7bd;
    const not_found = limits.window.mask;

    head: [limits.hash.size]u16 = [_]u16{not_found} ** limits.hash.size,
    chain: [2 * limits.window.size]u16 = [_]u16{not_found} ** (2 * limits.window.size),

    fn add(self: *Hasher, data: []const u8, idx: u16) u16 {
        if (data.len < 4) return not_found;
        const h = hash(data[0..4]);
        return self.set(h, idx);
    }

    fn prev(self: *Hasher, idx: u16) u16 {
        return self.chain[idx];
    }

    inline fn set(self: *Hasher, h: u32, idx: u16) u16 {
        const p = self.head[h];
        self.head[h] = idx;
        self.chain[idx] = p;
        return p;
    }

    pub fn slide(self: *Hasher, n: u16) void {
        for (self.head, 0..) |v, i| {
            if (v == not_found) continue;
            self.head[i] = if (v < n) not_found else v - n;
        }
        for (self.chain, 0..) |v, i| {
            if (v == not_found) continue;
            self.chain[i] = if (v < n) not_found else v - n;
        }
    }

    fn bulkAdd(self: *Hasher, data: []const u8, len: usize, idx: u16) void {
        // TOOD: use bulk alg from below
        var i: u16 = idx;
        for (0..len) |j| {
            const d = data[j..];
            if (d.len < limits.match.min_length) return;
            _ = self.add(d, i);
            i += 1;
        }
    }

    fn hash(b: *const [4]u8) u32 {
        return (((@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24) *% mul) >> limits.hash.shift) & limits.hash.mask;
    }

    fn bulk(b: []u8, dst: []u32) u32 {
        if (b.len < limits.match.min_length) {
            return 0;
        }
        var hb =
            @as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24;

        dst[0] = (hb *% mul) >> limits.hash.shift;
        const end = b.len - limits.match.min_length + 1;
        var i: u32 = 1;
        while (i < end) : (i += 1) {
            hb = (hb << 8) | @as(u32, b[i + 3]);
            dst[i] = (hb *% mul) >> limits.hash.shift;
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
    try testing.expect(h.chain[2 + 16] == 2 + 8);
    try testing.expect(h.chain[2 + 8] == 2);
}

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
        return if (t.kind == .backreference) @as(usize, t.dc) + limits.match.min_distance else 0;
    }

    pub fn length(t: Token) usize {
        return if (t.kind == .backreference) @as(usize, t.lc_sym) + limits.match.min_length else 1;
    }

    pub fn literal(sym: u8) Token {
        return .{ .kind = .literal, .lc_sym = sym };
    }

    pub fn backreference(dis: usize, len: usize) Token {
        assert(len >= limits.match.min_length and len <= limits.match.max_length);
        assert(dis >= limits.match.min_distance and dis <= limits.match.max_distance);
        return .{
            .kind = .backreference,
            .dc = @intCast(dis - limits.match.min_distance),
            .lc_sym = @intCast(len - limits.match.min_length),
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
            .backreference => std.debug.print("R({d}, {d}) \n", .{ t.distance(), t.length() }),
            .end_of_block => std.debug.print("E()", .{}),
        }
    }
};

test "Token size" {
    try expect(@sizeOf(Token) == 4);
    try expect(@bitSizeOf(Token) == 26);
    print("size of Hasher {d}\n", .{@sizeOf(Hasher) / 1024});
}

const Tokens = struct {
    list: [limits.block.tokens]Token = undefined,
    pos: usize = 0,

    fn add(self: *Tokens, t: Token) void {
        self.list[self.pos] = t;
        self.pos += 1;
    }

    fn len(self: *Tokens) usize {
        return self.pos;
    }

    fn full(self: *Tokens) bool {
        return self.pos == limits.block.tokens;
    }

    fn reset(self: *Tokens) void {
        self.pos = 0;
    }

    fn at(self: *Tokens, n: usize) Token {
        assert(n < self.pos);
        return self.list[n];
    }

    fn tokens(self: *Tokens) []const Token {
        return self.list[0..self.pos];
    }
};

test "zig tar" {
    const file_name = "testdata/2600.txt.utf-8";
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    var rdr = br.reader();

    var df = deflate(file.writer());

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try rdr.readAll(&buf);
        _ = try df.write(buf[0..n]);
        if (n < buf.len) break;
    }
    try df.close();
}
