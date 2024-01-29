const std = @import("std");
const io = std.io;
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const Token = @import("Token.zig");
const consts = @import("consts.zig");
const hbw = @import("huffman_bit_writer.zig");
const Wrapper = @import("wrapper.zig").Wrapper;

pub const Level = enum(u4) {
    // zig fmt: off
    fast = 0xb,         level_4 = 4,
                        level_5 = 5,
    default = 0xc,      level_6 = 6,
                        level_7 = 7,
                        level_8 = 8,
    best = 0xd,         level_9 = 9,
    // zig fmt: on
};

const LevelArgs = struct {
    good: u16, // do less lookups if we already have match of this length
    nice: u16, // stop looking for better match if we found match with at least this length
    lazy: u16, // don't do lazy match find if got match with at least this length
    chain: u16, // how many lookups for previous match to perform

    pub fn get(level: Level) LevelArgs {
        // zig fmt: off
        return switch (level) {
            .fast,    .level_4 => .{ .good =  4, .lazy =   4, .nice =  16, .chain =   16 },
                      .level_5 => .{ .good =  8, .lazy =  16, .nice =  32, .chain =   32 },
            .default, .level_6 => .{ .good =  8, .lazy =  16, .nice = 128, .chain =  128 },
                      .level_7 => .{ .good =  8, .lazy =  32, .nice = 128, .chain =  256 },
                      .level_8 => .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
            .best,    .level_9 => .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
        };
        // zig fmt: on
    }
};

pub fn compress(comptime wrap: Wrapper, reader: anytype, writer: anytype, level: Level) !void {
    var df = try compressor(wrap, writer, level);
    try df.stream(reader);
    try df.close();
}

pub fn compressor(comptime wrap: Wrapper, writer: anytype, level: Level) !Deflate(
    wrap,
    @TypeOf(writer),
    hbw.HuffmanBitWriter(@TypeOf(writer)),
) {
    const WriterType = @TypeOf(writer);
    const TokenWriter = hbw.HuffmanBitWriter(WriterType);
    return try Deflate(wrap, WriterType, TokenWriter).init(writer, level);
}

// Default compression algorithm. First finds tokens from the non compressed
// input data. Acumulates `const.block.tokens` number of tokens and then passes
// them to the `token_writer`. Client has to call `close` to write block with
// the final bit set.
//
// Level defines how hard (how slow) it tries to find match.
//
// Wrapper puts header and footer for gzip or zlib, they both share same
// deflate body. Raw has no header or footer just deflate body.
fn Deflate(comptime wrap: Wrapper, comptime WriterType: type, comptime TokenWriter: type) type {
    return struct {
        lookup: Lookup = .{},
        win: Window = .{},
        tokens: Tokens = .{},
        wrt: WriterType,
        token_writer: TokenWriter,
        level: LevelArgs,
        hasher: wrap.Hasher() = .{},

        // Match and literal at the previous position.
        // Used for lazy match finding in processWindow.
        prev_match: ?Token = null,
        prev_literal: ?u8 = null,

        const Self = @This();
        pub fn init(wrt: WriterType, level: Level) !Self {
            var self = Self{
                .wrt = wrt,
                .token_writer = TokenWriter.init(wrt),
                .level = LevelArgs.get(level),
            };
            try self.writeHeader();
            return self;
        }

        const TokenizeOption = enum { none, flush, final };

        // Process data in window and create tokens. If token buffer is full
        // flush tokens to the token writer. In the case of `flush` or `final`
        // option it will process all data from the window. In the `none` case
        // it will preserve some data for the next match.
        fn tokenize(self: *Self, opt: TokenizeOption) !void {
            // flush - process all data from window
            const should_flush = (opt != .none);

            // While there is data in active lookahead buffer.
            while (self.win.activeLookahead(should_flush)) |lh| {
                var step: u16 = 1; // 1 in the case of literal, match length otherwise
                const pos: u16 = self.win.pos();
                const literal = lh[0]; // literal at current position
                const min_len: u16 = if (self.prev_match) |m| m.length() else 0;

                // Try to find match at least min_len long.
                if (self.findMatch(pos, lh, min_len)) |match| {
                    // Found better match than previous.
                    try self.addPrevLiteral();

                    // Is found match length good enough?
                    if (match.length() >= self.level.lazy) {
                        // Don't try to lazy find better match, use this.
                        step = try self.addMatch(match);
                    } else {
                        // Store this match.
                        self.prev_literal = literal;
                        self.prev_match = match;
                    }
                } else {
                    // There is no better match at current pos then it was previous.
                    // Write previous match or literal.
                    if (self.prev_match) |m| {
                        // Write match from previous position.
                        step = try self.addMatch(m) - 1; // we already advanced 1 from previous position
                    } else {
                        // No match at previous postition.
                        // Write previous literal if any, and remember this literal.
                        try self.addPrevLiteral();
                        self.prev_literal = literal;
                    }
                }
                // Advance window and add hashes.
                self.windowAdvance(step, lh, pos);
            }

            if (should_flush) {
                // In the case of flushing, last few lookahead buffers were smaller then min match len.
                // So only last literal can be unwritten.
                assert(self.prev_match == null);
                try self.addPrevLiteral();
                self.prev_literal = null;

                try self.flushTokens(opt == .final);
            }
        }

        inline fn windowAdvance(self: *Self, step: u16, lh: []const u8, pos: u16) void {
            // current position is already added in findMatch
            self.lookup.bulkAdd(lh[1..], step - 1, pos + 1);
            self.win.advance(step);
        }

        // Add previous literal (if any) to the tokens list.
        inline fn addPrevLiteral(self: *Self) !void {
            if (self.prev_literal) |l| try self.addToken(Token.initLiteral(l));
        }

        // Add match to the tokens list, reset prev pointers.
        // Returns length of the added match.
        inline fn addMatch(self: *Self, m: Token) !u16 {
            try self.addToken(m);
            self.prev_literal = null;
            self.prev_match = null;
            return m.length();
        }

        inline fn addToken(self: *Self, token: Token) !void {
            self.tokens.add(token);
            if (self.tokens.full()) try self.flushTokens(false);
        }

        // Finds largest match in the history window with the data at current pos.
        fn findMatch(self: *Self, pos: u16, lh: []const u8, min_len: u16) ?Token {
            var len: u16 = min_len;
            // Previous location with the same hash (same 4 bytes).
            var prev_pos = self.lookup.add(lh, pos);
            // Last found match.
            var match: ?Token = null;

            // How much back-references to try, performance knob.
            var chain: usize = self.level.chain;
            if (len >= self.level.good) {
                // If we've got a match that's good enough, only look in 1/4 the chain.
                chain >>= 2;
            }

            while (prev_pos > 0 and chain > 0) : (chain -= 1) {
                const distance = pos - prev_pos;
                if (distance > consts.match.max_distance)
                    break;

                const new_len = self.win.match(prev_pos, pos, len);
                if (new_len > len) {
                    match = Token.initMatch(@intCast(distance), new_len);
                    if (new_len >= self.level.nice) {
                        // The match is good enough that we don't try to find a better one.
                        return match;
                    }
                    len = new_len;
                }
                prev_pos = self.lookup.prev(prev_pos);
            }

            return match;
        }

        fn flushTokens(self: *Self, final: bool) !void {
            try self.token_writer.writeBlock(self.tokens.tokens(), final, self.win.tokensBuffser());
            if (final) try self.token_writer.flush();
            self.tokens.reset();
            self.win.flushed();
        }

        pub fn flush(self: *Self) !void {
            try self.tokenize(.flush);
        }

        pub fn close(self: *Self) !void {
            try self.tokenize(.final);
            try self.writeFooter();
        }

        pub fn write(self: *Self, input: []const u8) !usize {
            var buf = input;
            self.hasher.update(buf);

            while (buf.len > 0) {
                const n = self.win.write(buf);
                if (n == 0) {
                    try self.tokenize(.none);
                    self.slide();
                    continue;
                }
                buf = buf[n..];
            }
            try self.tokenize(.none);

            return input.len;
        }

        // slide win and if needed lookup tables
        inline fn slide(self: *Self) void {
            const n = self.win.slide();
            self.lookup.slide(n);
        }

        // TODO: name for this
        pub fn stream(self: *Self, rdr: anytype) !void {
            while (true) {
                // read from rdr into win
                const buf = self.win.writable();
                if (buf.len == 0) {
                    self.slide();
                    continue;
                }
                const n = try rdr.readAll(buf);
                self.hasher.update(buf[0..n]);
                self.win.written(n);
                // process win
                try self.tokenize(.none);
                // no more data in reader
                if (n < buf.len) break;
            }
        }

        // Writer interface

        pub const Writer = io.Writer(*Self, Error, write);
        pub const Error = TokenWriter.Error;

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        // header and footer
        fn writeHeader(self: *Self) !void {
            try wrap.writeHeader(self.wrt);
        }

        fn writeFooter(self: *Self) !void {
            try wrap.writeFooter(&self.hasher, self.wrt);
        }
    };
}

pub fn compressHuffmanOnly(comptime wrap: Wrapper, reader: anytype, writer: anytype) !void {
    var df = try huffmanOnlyCompressor(wrap, writer);
    try df.stream(reader);
    try df.close();
}

pub fn huffmanOnlyCompressor(comptime wrap: Wrapper, writer: anytype) !DeflateHuffmanOnly(
    wrap,
    @TypeOf(writer),
    hbw.HuffmanBitWriter(@TypeOf(writer)),
) {
    const WriterType = @TypeOf(writer);
    const TokenWriter = hbw.HuffmanBitWriter(WriterType);
    return try DeflateHuffmanOnly(wrap, WriterType, TokenWriter).init(writer);
}

// Creates huffman only deflate blocks. Without LZ77 compression, without
// finding matches in the history.
fn DeflateHuffmanOnly(comptime wrap: Wrapper, comptime WriterType: type, comptime TokenWriter: type) type {
    return struct {
        wrt: WriterType,
        token_writer: TokenWriter,
        hasher: wrap.Hasher() = .{},

        const Self = @This();

        pub fn init(wrt: WriterType) !Self {
            var self = Self{
                .wrt = wrt,
                .token_writer = TokenWriter.init(wrt),
            };
            try self.writeHeader();
            return self;
        }

        pub fn flush(self: *Self) !void {
            try self.token_writer.flush();
        }

        pub fn close(self: *Self) !void {
            try self.token_writer.writeBlockHuff(true, "");
            try self.writeFooter();
        }

        pub fn write(self: *Self, input: []const u8) !usize {
            self.hasher.update(input);
            try self.token_writer.writeBlockHuff(false, input);
            return input.len;
        }

        pub fn stream(self: *Self, rdr: anytype) !void {
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try rdr.readAll(&buf);
                self.hasher.update(buf[0..n]);
                try self.token_writer.writeBlockHuff(false, buf[0..n]);
                if (n < buf.len) break; // no more data in reader
            }
        }

        // Writer interface

        pub const Writer = io.Writer(*Self, Error, write);
        pub const Error = TokenWriter.Error;

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        // header and footer
        fn writeHeader(self: *Self) !void {
            try wrap.writeHeader(self.wrt);
        }

        fn writeFooter(self: *Self) !void {
            try wrap.writeFooter(&self.hasher, self.wrt);
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
        .{
            .data = "ABCDEABCD ABCDEABCD",
            .tokens = &[_]Token{
                L('A'), L('B'),   L('C'), L('D'), L('E'), L('A'), L('B'), L('C'), L('D'), L(' '),
                L('A'), M(10, 8),
            },
        },
    };

    for (cases) |c| {
        inline for (Wrapper.list) |wrap| { // for each wrapping
            var cw = io.countingWriter(io.null_writer);
            const cww = cw.writer();
            var df = try Deflate(wrap, @TypeOf(cww), TestTokenWriter).init(cww, .default);

            _ = try df.write(c.data);
            try df.flush();

            // df.token_writer.show();
            try expect(df.token_writer.pos == c.tokens.len); // number of tokens written
            try testing.expectEqualSlices(Token, df.token_writer.get(), c.tokens); // tokens match

            try testing.expectEqual(wrap.headerSize(), cw.bytes_written);
            try df.close();
            try testing.expectEqual(wrap.size(), cw.bytes_written);
        }
    }
}

// Tests that tokens writen are equal to expected token list.
const TestTokenWriter = struct {
    const Self = @This();
    //expected: []const Token,
    pos: usize = 0,
    actual: [1024]Token = undefined,

    pub fn init(_: anytype) Self {
        return .{};
    }
    pub fn writeBlock(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
        for (tokens) |t| {
            self.actual[self.pos] = t;
            self.pos += 1;
        }
    }

    pub fn get(self: *Self) []Token {
        return self.actual[0..self.pos];
    }

    pub fn show(self: *Self) void {
        print("\n", .{});
        for (self.get()) |t| {
            t.show();
        }
    }

    pub fn flush(_: *Self) !void {}
};

const Window = struct {
    const hist_len = consts.history.len;
    const buffer_len = 2 * hist_len;
    const min_lookahead = consts.match.min_length + consts.match.max_length;
    const max_rp = buffer_len - min_lookahead;

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position
    fp: isize = 0, // flush position, tokens are build from fp..rp

    // Returns number of bytes written, or 0 if buffer is full and need to slide.
    pub fn write(self: *Window, buf: []const u8) usize {
        if (self.rp >= max_rp) return 0; // need to slide

        const n = @min(buf.len, buffer_len - self.wp);
        @memcpy(self.buffer[self.wp .. self.wp + n], buf[0..n]);
        self.wp += n;
        return n;
    }

    // Slide buffer for hist_len.
    // Drops old history, preserves bwtween hist_len and hist_len - min_lookahead.
    // Returns number of bytes removed.
    pub fn slide(self: *Window) u16 {
        assert(self.rp >= max_rp and self.wp >= self.rp);
        const n = self.wp - hist_len;
        @memcpy(self.buffer[0..n], self.buffer[hist_len..self.wp]);
        self.rp -= hist_len;
        self.wp -= hist_len;
        self.fp -= hist_len;
        return @intCast(n);
    }

    // flush - process all data from window
    // If not flush preserve enough data for the loghest match.
    // Returns null if there is not enough data.
    pub fn activeLookahead(self: *Window, flush: bool) ?[]const u8 {
        const min: usize = if (flush) 0 else min_lookahead;
        const lh = self.lookahead();
        return if (lh.len > min) lh else null;
    }

    pub inline fn lookahead(self: *Window) []const u8 {
        assert(self.wp >= self.rp);
        return self.buffer[self.rp..self.wp];
    }

    pub fn writable(self: *Window) []u8 {
        return self.buffer[self.wp..];
    }

    pub fn written(self: *Window, n: usize) void {
        self.wp += n;
    }

    pub fn advance(self: *Window, n: u16) void {
        assert(self.wp >= self.rp + n);
        self.rp += n;
    }

    // Finds match length between previous and current position.
    pub fn match(self: *Window, prev_pos: u16, curr_pos: u16, min_len: u16) u16 {
        const max_len: usize = @min(self.wp - curr_pos, consts.match.max_length);
        // lookahead buffers from previous and current positions
        const prev_lh = self.buffer[prev_pos..][0..max_len];
        const curr_lh = self.buffer[curr_pos..][0..max_len];

        // If we alread have match (min_len > 0),
        // test the first byte above previous len a[min_len] != b[min_len]
        // and then all the bytes from that position to zero.
        // That is likely positions to find difference than looping from first bytes.
        var i: usize = min_len;
        if (i > 0) {
            if (max_len <= i) return 0;
            while (true) {
                if (prev_lh[i] != curr_lh[i]) return 0;
                if (i == 0) break;
                i -= 1;
            }
            i = min_len;
        }
        while (i < max_len) : (i += 1)
            if (prev_lh[i] != curr_lh[i]) break;
        return if (i >= consts.match.min_length) @intCast(i) else 0;
    }

    pub fn pos(self: *Window) u16 {
        return @intCast(self.rp);
    }

    pub fn flushed(self: *Window) void {
        self.fp = @intCast(self.rp);
    }

    pub fn tokensBuffser(self: *Window) ?[]const u8 {
        assert(self.fp <= self.rp);
        if (self.fp < 0) return null;
        return self.buffer[@intCast(self.fp)..self.rp];
    }
};

test "StreamWindow match" {
    const data = "Blah blah blah blah blah!";
    var win: Window = .{};
    try expect(win.write(data) == data.len);
    try expect(win.wp == data.len);
    try expect(win.rp == 0);

    // length between l symbols
    try expect(win.match(1, 6, 0) == 18);
    try expect(win.match(1, 11, 0) == 13);
    try expect(win.match(1, 16, 0) == 8);
    try expect(win.match(1, 21, 0) == 0);

    // position 15 = "blah blah!"
    // position 20 = "blah!"
    try expect(win.match(15, 20, 0) == 4);
    try expect(win.match(15, 20, 3) == 4);
    try expect(win.match(15, 20, 4) == 0);
}

test "StreamWindow slide" {
    var win: Window = .{};
    win.wp = Window.buffer_len - 11;
    win.rp = Window.buffer_len - 111;
    win.buffer[win.rp] = 0xab;
    try expect(win.lookahead().len == 100);
    try expect(win.tokensBuffser().?.len == win.rp);

    const n = win.slide();
    try expect(n == 32757);
    try expect(win.buffer[win.rp] == 0xab);
    try expect(win.rp == Window.hist_len - 111);
    try expect(win.wp == Window.hist_len - 11);
    try expect(win.lookahead().len == 100);
    try expect(win.tokensBuffser() == null);
}

test "check struct sizes" {
    try expect(@sizeOf(Token) == 4);

    // list: (1 << 15) * 4 = 128k + pos: 8
    const tokens_size = 128 * 1024 + 8;
    try expect(@sizeOf(Tokens) == tokens_size);

    // head: (1 << 15) * 2 = 64k, chain: (32768 * 2) * 2  = 128k = 192k
    const lookup_size = 192 * 1024;
    try expect(@sizeOf(Lookup) == lookup_size);

    // buffer: (32k * 2), wp: 8, rp: 8, fp: 8
    const window_size = 64 * 1024 + 8 + 8 + 8;
    try expect(@sizeOf(Window) == window_size);

    const Hbw = hbw.HuffmanBitWriter(@TypeOf(io.null_writer));
    // huffman bit writer internal: 11480
    const hbw_size = 11472; // 11.2k
    try expect(@sizeOf(Hbw) == hbw_size);

    //const D = Deflate(Hbw);
    // 404744, 395.26k
    // ?Token: 6, ?u8: 2, level: 8
    //try expect(@sizeOf(D) == tokens_size + lookup_size + window_size + hbw_size + 6 + 2 + 8);

    //print("Delfate size: {d} {d}\n", .{ @sizeOf(D), @sizeOf(LevelArgs) });

    // current std lib deflate allocation:
    // 797_901, 779.2k
    // measured with:
    // var la = std.heap.logToWriterAllocator(testing.allocator, io.getStdOut().writer());
    // const allocator = la.allocator();
    // var cmp = try std.compress.deflate.compressor(allocator, io.null_writer, .{});
    // defer cmp.deinit();
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

    const file_name = "benchdata/2600.txt.utf-8";
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    const wrt = io.getStdOut().writer();

    const tw: TokenDecoder(@TypeOf(wrt)) = .{ .wrt = wrt };
    var df = Deflate(@TypeOf(tw)).init(tw);
    try df.compress(file.reader());
    try df.close();
}

fn TokenDecoder(comptime WriterType: type) type {
    return struct {
        const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
        win: SlidingWindow = .{},
        wrt: WriterType,
        const Self = @This();

        pub fn writeBlock(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
            for (tokens) |t| {
                switch (t.kind) {
                    .literal => self.win.write(t.literal()),
                    .match => self.win.writeCopy(t.length(), t.offset()),
                }
                if (self.win.free() < 285) try self.flushWin();
            }
            try self.flushWin();
        }

        fn flushWin(self: *Self) !void {
            while (true) {
                const buf = self.win.read();
                if (buf.len == 0) break;
                try self.wrt.writeAll(buf);
            }
        }

        pub fn flush(_: *Self) !void {}
    };
}

const Lookup = struct {
    const prime4 = 0x9E3779B1; // 4 bytes prime number 2654435761
    const chain_len = Window.buffer_len;

    // hash => location lookup
    head: [consts.lookup.len]u16 = [_]u16{0} ** consts.lookup.len,
    // location => prev location for the same hash value
    chain: [chain_len]u16 = [_]u16{0} ** (chain_len),

    // Calculates hash of the 4 bytes from data.
    // Inserts idx location of that hash in the lookup tables.
    // Resturns previous location with the same hash value.
    pub fn add(self: *Lookup, data: []const u8, idx: u16) u16 {
        if (data.len < 4) return 0;
        const h = hash(data[0..4]);
        return self.set(h, idx);
    }

    // Previous location with the same hash value.
    pub inline fn prev(self: *Lookup, idx: u16) u16 {
        return self.chain[idx];
    }

    inline fn set(self: *Lookup, h: u32, idx: u16) u16 {
        const p = self.head[h];
        self.head[h] = idx;
        self.chain[idx] = p;
        return p;
    }

    // Slide all positions in head and chain for n.
    pub fn slide(self: *Lookup, n: u16) void {
        for (&self.head) |*v| {
            v.* -|= n;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.chain[i] = self.chain[i + n] -| n;
        }
    }

    // Add `len` 4 bytes hashes from `data` into lookup.
    // Position of the first byte is `idx`.
    pub fn bulkAdd(self: *Lookup, data: []const u8, len: u16, idx: u16) void {
        if (len == 0 or data.len < consts.match.min_length) {
            return;
        }
        var hb =
            @as(u32, data[3]) |
            @as(u32, data[2]) << 8 |
            @as(u32, data[1]) << 16 |
            @as(u32, data[0]) << 24;
        _ = self.set(hashu(hb), idx);

        var i = idx;
        for (4..@min(len + 3, data.len)) |j| {
            hb = (hb << 8) | @as(u32, data[j]);
            i += 1;
            _ = self.set(hashu(hb), i);
        }
    }

    // Calculates hash of the first 4 bytes of `b`.
    inline fn hash(b: *const [4]u8) u32 {
        return hashu(@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24);
    }

    inline fn hashu(v: u32) u32 {
        return @intCast((v *% prime4) >> consts.lookup.shift);
    }
};

test "Lookup add/prev" {
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03,
    };

    var h: Lookup = .{};
    for (data, 0..) |_, i| {
        const prev = h.add(data[i..], @intCast(i));
        if (i >= 8 and i < 24) {
            try expect(prev == i - 8);
        } else {
            try expect(prev == 0);
        }
    }

    const v = Lookup.hash(data[2 .. 2 + 4]);
    try expect(h.head[v] == 2 + 16);
    try expect(h.chain[2 + 16] == 2 + 8);
    try expect(h.chain[2 + 8] == 2);
}

test "Lookup bulkAdd" {
    const data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit.";

    // one by one
    var h: Lookup = .{};
    for (data, 0..) |_, i| {
        _ = h.add(data[i..], @intCast(i));
    }

    // in bulk
    var bh: Lookup = .{};
    bh.bulkAdd(data, data.len, 0);

    try testing.expectEqualSlices(u16, &h.head, &bh.head);
    try testing.expectEqualSlices(u16, &h.chain, &bh.chain);
}
