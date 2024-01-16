const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;
const Token = @import("token.zig").Token;
const consts = @import("consts.zig");

pub fn deflateWriter(writer: anytype) Deflate(@TypeOf(writer)) {
    return Deflate(@TypeOf(writer)).init(writer);
}

pub fn deflate(reader: anytype, writer: anytype) !void {
    const tw = tokenWriter(writer);
    var df = Deflate(@TypeOf(tw)).init(tw);
    try df.compress(reader);
    try df.close();
}

pub fn Deflate(comptime WriterType: type) type {
    return struct {
        hasher: Hasher = .{},
        win: StreamWindow = .{},
        tokens: Tokens = .{},
        token_writer: WriterType,

        const Self = @This();
        pub fn init(w: WriterType) Self {
            return .{ .token_writer = w };
        }

        fn nextToken(self: *Self, min_lookahead: usize) ?Token {
            const lh = self.win.lookahead();
            if (lh.len <= min_lookahead) return null;

            var token = Token.initLiteral(lh[0]);
            var length: usize = 1;

            const curr_pos = self.win.pos();
            var match_pos = self.hasher.add(lh, @intCast(curr_pos)); // TODO: rethink intCast

            var tries: usize = 128; // TODO: this is just hack
            while (match_pos != Hasher.not_found and tries > 0) : (tries -= 1) {
                const distance = curr_pos - match_pos;
                if (distance > consts.match.max_distance or
                    match_pos < self.win.offset) break;
                const match_length = self.win.match(match_pos, curr_pos);
                if (match_length > length) {
                    token = Token.initMatch(@intCast(distance), match_length);
                    length = match_length;
                }
                match_pos = self.hasher.prev(match_pos);
            }

            self.win.advance(length);
            if (length > 1)
                self.hasher.bulkAdd(lh[1..], length - 1, @intCast(curr_pos + 1));

            return token;
        }

        const ProcessOption = enum { none, flush, final };

        // Process data in window and create tokens.
        // If token buffer is full flush tokens to the token writer.
        fn processWindow(self: *Self, opt: ProcessOption) !void {
            const min_lookahead: usize = if (opt == .none) consts.match.max_length else 0;

            while (self.nextToken(min_lookahead)) |token| {
                self.tokens.add(token);
                if (self.tokens.full()) try self.flushTokens(false);
            }

            if (opt != .none) try self.flushTokens(opt == .final);
        }

        fn flushTokens(self: *Self, final: bool) !void {
            try self.token_writer.write(self.tokens.tokens(), final);
            self.tokens.reset();
        }

        pub fn flush(self: *Self) !void {
            try self.processWindow(.flush);
        }

        pub fn close(self: *Self) !void {
            try self.processWindow(.final);
        }

        pub fn write(self: *Self, input: []const u8) !usize {
            var buf = input;

            while (buf.len > 0) {
                const n = self.win.write(buf);
                if (n == 0) {
                    try self.processWindow(.none);
                    self.slide();
                    continue;
                }
                buf = buf[n..];
            }
            try self.processWindow(.none);

            return input.len;
        }

        // slide win and if needed hasher
        inline fn slide(self: *Self) void {
            const j = self.win.slide();
            if (j > 0)
                self.hasher.slide(@intCast(j));
        }

        pub fn compress(self: *Self, rdr: anytype) !void {
            while (true) {
                // read from rdr into win
                const buf = self.win.writable();
                if (buf.len == 0) {
                    self.slide();
                    continue;
                }
                const n = try rdr.readAll(buf);
                self.win.written(n);
                // process win
                try self.processWindow(.none);
                // no more data in reader
                if (n < buf.len) break;
            }
        }

        // Writer interface

        pub const Writer = std.io.Writer(*Self, Error, write);
        pub const Error = WriterType.Error;

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

test "deflate: tokenization" {
    const L = Token.initLiteral;
    const M = Token.initMatch;

    const cases = [_]struct {
        data: []const u8,
        tokens: []const Token,
    }{
        .{
            .data = "Blah blah blah blah blah!",
            .tokens = &[_]Token{ L('B'), L('l'), L('a'), L('h'), L(' '), L('b'), M(5, 18), L('!') },
        },
    };

    for (cases) |c| {
        var fbs = std.io.fixedBufferStream(c.data);
        var nw: TestTokenWriter = .{
            .expected = c.tokens,
        };
        var df = deflateWriter(&nw);
        try df.compress(fbs.reader());
        try df.close();
        try expect(nw.pos == c.tokens.len);
    }
}

// Tests that tokens writen are equal to expected token list.
const TestTokenWriter = struct {
    const Self = @This();
    expected: []const Token,
    pos: usize = 0,

    pub fn write(self: *Self, tokens: []const Token, _: bool) !void {
        for (tokens) |t| {
            try expect(t.eql(self.expected[self.pos]));
            self.pos += 1;
        }
    }
};

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
    const hist_len = consts.window.size;
    const buffer_len = 2 * hist_len;
    const max_rp = buffer_len - (consts.match.min_length + consts.match.max_length);
    const max_offset = (1 << 32) - (2 * buffer_len);

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position
    offset: usize = 0,

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
        self.offset += hist_len;

        if (self.offset >= max_offset) {
            const ret = self.offset;
            self.offset = 0;
            return ret;
        }
        return 0;
    }

    pub fn lookahead(self: *StreamWindow) []const u8 {
        assert(self.wp >= self.rp);
        return self.buffer[self.rp..self.wp];
    }

    pub fn history(self: *StreamWindow) []const u8 {
        return self.buffer[0..self.rp];
    }

    pub fn writable(self: *StreamWindow) []u8 {
        return self.buffer[self.wp..];
    }

    pub fn written(self: *StreamWindow, n: usize) void {
        self.wp += n;
    }

    pub fn advance(self: *StreamWindow, n: usize) void {
        assert(self.wp >= self.rp + n);
        self.rp += n;
    }

    // Finds match length between previous and current position.
    pub fn match(self: *StreamWindow, prev: usize, curr: usize) u16 {
        //if (!(prev > self.offset and curr > prev)) {
        //if (self.offset > 0)
        //            print("match prev: {d}, self.offset: {d}, curr: {d}\n", .{ prev, self.offset, curr });
        //}
        assert(prev >= self.offset and curr > prev);
        var p1: usize = prev - self.offset;
        var p2: usize = curr - self.offset;
        var n: u16 = 0;
        while (p2 < self.wp and self.buffer[p1] == self.buffer[p2] and n < consts.match.max_length) {
            n += 1;
            p1 += 1;
            p2 += 1;
        }
        return if (n > consts.match.min_length) n else 0;
    }

    pub fn pos(self: *StreamWindow) usize {
        return self.rp + self.offset;
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
    try expect(n == 0);
    try expect(win.offset == StreamWindow.hist_len);
    try expect(win.rp == StreamWindow.hist_len - 111);
    try expect(win.wp == StreamWindow.hist_len - 11);
    try expect(win.lookahead().len == 100);
    try expect(win.history().len == win.rp);
}

const Hasher = struct {
    const mul = 0x1e35a7bd;
    const not_found = (1 << 32) - 1;
    const mask = consts.window.mask;

    head: [consts.hash.size]u32 = [_]u32{not_found} ** consts.hash.size,
    chain: [consts.window.size]u32 = [_]u32{not_found} ** (consts.window.size),

    fn add(self: *Hasher, data: []const u8, idx: u32) u32 {
        if (data.len < 4) return not_found;
        const h = hash(data[0..4]);
        return self.set(h, idx);
    }

    fn prev(self: *Hasher, idx: u32) u32 {
        const v = self.chain[idx & mask];
        return if (v > idx) not_found else v;
    }

    inline fn set(self: *Hasher, h: u32, idx: u32) u32 {
        const p = self.head[h];
        self.head[h] = idx;
        self.chain[idx & mask] = p;
        return p;
    }

    // Slide all positions in head and chain for n.
    pub fn slide(self: *Hasher, n: u32) void {
        for (self.head, 0..) |v, i| {
            if (v == not_found) continue;
            self.head[i] = if (v < n) not_found else v - n;
        }
        for (self.chain, 0..) |v, i| {
            if (v == not_found) continue;
            self.chain[i] = if (v < n) not_found else v - n;
        }
    }

    fn bulkAdd(self: *Hasher, data: []const u8, len: usize, idx: u32) void {
        // TOOD: use bulk alg from below
        var i: u32 = idx;
        for (0..len) |j| {
            const d = data[j..];
            if (d.len < consts.match.min_length) return;
            _ = self.add(d, i);
            i += 1;
        }
    }

    fn hash(b: *const [4]u8) u32 {
        return (((@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24) *% mul) >> consts.hash.shift) & consts.hash.mask;
    }

    fn bulk(b: []u8, dst: []u32) u32 {
        if (b.len < consts.match.min_length) {
            return 0;
        }
        var hb =
            @as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24;

        dst[0] = (hb *% mul) >> consts.hash.shift;
        const end = b.len - consts.match.min_length + 1;
        var i: u32 = 1;
        while (i < end) : (i += 1) {
            hb = (hb << 8) | @as(u32, b[i + 3]);
            dst[i] = (hb *% mul) >> consts.hash.shift;
        }
        return hb;
    }
};

test "Hasher add/prev" {
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

test "Token size" {
    // TODO: remove this
    // print("size of Tokens {d}, bit_offset: {d} {d} {d}\n", .{
    //     @sizeOf(Tokens),
    //     @bitOffsetOf(Token, "kind"),
    //     @bitOffsetOf(Token, "lc_sym"),
    //     @bitOffsetOf(Token, "dc"),
    // });
    try expect(@sizeOf(Token) == 4);
    //try expect(@bitSizeOf(Token) == 26);
    // print("size of Hasher {d}\n", .{@sizeOf(Hasher)});
    try expect(@sizeOf(Hasher) == 655_360);
}

const Tokens = struct {
    list: [consts.block.tokens]Token = undefined,
    pos: usize = 0,

    fn add(self: *Tokens, t: Token) void {
        self.list[self.pos] = t;
        self.pos += 1;
    }

    fn len(self: *Tokens) usize {
        return self.pos;
    }

    fn full(self: *Tokens) bool {
        return self.pos == consts.block.tokens;
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

test "deflate compress file to stdout" {
    if (true) return error.SkipZigTest;

    const file_name = "testdata/2600.txt.utf-8";
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    var rdr = br.reader();

    var stw: StdoutTokenWriter = .{};
    var df = deflateWriter(&stw);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try rdr.readAll(&buf);
        _ = try df.write(buf[0..n]);
        if (n < buf.len) break;
    }
    try df.close();
}

const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

const StdoutTokenWriter = struct {
    win: SlidingWindow = .{},

    pub fn write(self: *StdoutTokenWriter, tokens: []const Token) !void {
        const stdout = std.io.getStdOut();

        for (tokens) |t| {
            switch (t.kind) {
                .literal => self.win.write(t.symbol()),
                .match => self.win.writeCopy(t.length(), t.distance()),
                else => unreachable,
            }
            if (self.win.free() < 285) {
                while (true) {
                    const buf = self.win.read();
                    if (buf.len == 0) break;
                    try stdout.writeAll(buf);
                }
            }
        }

        while (true) {
            const buf = self.win.read();
            if (buf.len == 0) break;
            try stdout.writeAll(buf);
        }
    }

    pub fn close(self: *StdoutTokenWriter) !void {
        _ = self;
    }
};

const hm_bw = @import("std/huffman_bit_writer.zig");

test "deflate compress file" {
    const input_file_name = "testdata/2600.txt.utf-8";
    var input = try std.fs.cwd().openFile(input_file_name, .{});
    defer input.close();

    const output_file_name = "testdata/output.gz";
    var output = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
    defer output.close();

    try gzip(input.reader(), output.writer());
}

pub fn gzip(reader: anytype, writer: anytype) !void {
    var ev = envelope(reader, .gzip);
    try ev.header(writer);
    try deflate(ev.reader(), writer);
    try ev.footer(writer);
}

// TODO: so far just placeholder
pub fn zlib(reader: anytype, writer: anytype) !void {
    var ev = envelope(reader, .zlib);
    try ev.header(writer);
    try deflate(ev.reader(), writer);
    try ev.footer(writer);
}

pub fn tokenWriter(writer: anytype) TokenWriter(@TypeOf(writer)) {
    return TokenWriter(@TypeOf(writer)).init(writer);
}

fn TokenWriter(comptime WriterType: type) type {
    return struct {
        hw_bw: hm_bw.HuffmanBitWriter(WriterType),

        const Self = @This();

        pub fn init(writer: WriterType) Self {
            return .{ .hw_bw = hm_bw.huffmanBitWriter(writer) };
        }

        pub fn write(self: *Self, tokens: []const Token, final: bool) !void {
            // for (tokens, 0..) |t, i| {
            //     self.tokens[i] = switch (t.kind) {
            //         .literal => std_token.literalToken(t.symbol()),
            //         .match => std_token.matchToken(t.lc_sym, t.dc),
            //         else => unreachable,
            //     };
            // }
            // const std_tokens = self.tokens[0..tokens.len];
            try self.hw_bw.writeBlock(tokens, final, null);
            if (final) try self.hw_bw.flush();
        }
    };
}

const EnvelopeKind = enum {
    gzip,
    zlib,
};

pub fn Envelope(comptime ReaderType: type, comptime kind: EnvelopeKind) type {
    const HasherType = if (kind == .gzip)
        std.hash.Crc32
    else
        std.hash.Adler32;

    return struct {
        rdr: ReaderType,
        bytes: usize = 0,
        hasher: HasherType = HasherType.init(),

        const Self = @This();

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            const n = try self.rdr.read(buf);
            self.hasher.update(buf[0..n]);
            self.bytes += n;
            return n;
        }

        pub fn chksum(self: *Self) u32 {
            return self.hasher.final();
        }

        pub fn bytesRead(self: *Self) u32 {
            return @intCast(self.bytes);
        }

        pub fn header(self: *Self, wrt: anytype) !void {
            _ = self;
            switch (kind) {
                .gzip => {
                    const gzipHeader = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
                    try wrt.writeAll(&gzipHeader);
                },
                .zlib => {
                    // TODO: ref https://github.com/golang/go/blob/8db131082d08e497fd8e9383d0ff7715e1bef478/src/compress/zlib/writer.go#L93
                },
            }
        }

        pub fn footer(self: *Self, wrt: anytype) !void {
            var bits: [4]u8 = undefined;
            switch (kind) {
                .gzip => {
                    std.mem.writeInt(u32, &bits, self.chksum(), .little);
                    try wrt.writeAll(&bits);

                    std.mem.writeInt(u32, &bits, self.bytesRead(), .little);
                    try wrt.writeAll(&bits);
                },
                .zlib => {
                    std.mem.writeInt(u32, &bits, self.chksum(), .bit);
                    try wrt.writeAll(&bits);
                },
            }
        }
    };
}

pub fn envelope(reader: anytype, comptime kind: EnvelopeKind) Envelope(@TypeOf(reader), kind) {
    return .{ .rdr = reader };
}
