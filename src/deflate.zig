const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;
const Token = @import("Token.zig");
const consts = @import("consts.zig");
const hbw = @import("huffman_bit_writer.zig");

pub fn deflateWriter(writer: anytype) Deflate(@TypeOf(writer)) {
    return Deflate(@TypeOf(writer)).init(writer);
}

pub fn deflate(reader: anytype, writer: anytype) !void {
    const tw = hbw.huffmanBitWriter(writer);
    var df = Deflate(@TypeOf(tw)).init(tw);
    try df.compress(reader);
    try df.close();
}

const Compression = enum {
    default,
    best,
};

const Level = struct {
    good: u16,
    nice: u16,
    lazy: u16,
    chain: u16,
};

pub fn Deflate(comptime WriterType: type) type {
    const compression: Compression = .default;
    const level: Level = switch (compression) {
        .default => .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
        .best => .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
    };
    return struct {
        hasher: Hasher = .{},
        win: StreamWindow = .{},
        tokens: Tokens = .{},
        token_writer: WriterType,

        prev_match: ?Token = null,
        prev_literal: ?u8 = null,

        const Self = @This();
        pub fn init(w: WriterType) Self {
            return .{ .token_writer = w };
        }

        const ProcessOption = enum { none, flush, final };

        // Process data in window and create tokens. If token buffer is full
        // flush tokens to the token writer. In the case of `flush` or `final`
        // option it will process all data from the window. In the `none` case
        // it will preserve some data for the next match.
        fn processWindow(self: *Self, opt: ProcessOption) !void {
            // flush - process all data from window
            const flsh = (opt != .none);

            // While there is data in active lookahead buffer.
            while (self.win.activeLookahead(flsh)) |lh| {
                var step: usize = 1; // 1 in the case of literal, match length otherwise
                const pos: usize = self.win.pos();
                const literal = lh[0]; // literal at current position
                const min_len: u16 = if (self.prev_match) |m| m.length() else consts.match.min_length;

                // Try to find match at least min_len long.
                if (self.findMatch(pos, lh, min_len)) |match| {
                    // Found better match than previous.

                    try self.addPrevLiteral();

                    // Is found match length good enough?
                    if (match.length() >= level.lazy) {
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
                self.windowAdvance(step);
            }

            if (flsh) {
                // In the case of flushing, last few lookahead buffers were smaller then min match len.
                // So only last literal can be unwritten.
                assert(self.prev_match == null);
                try self.addPrevLiteral();
                self.prev_literal = null;
            }

            if (flsh) try self.flushTokens(opt == .final);
        }

        inline fn windowAdvance(self: *Self, step: usize) void {
            // assuming current position is already added in findMatch
            if (step > 1) {
                const lh = self.win.lookahead();
                const pos = self.win.pos();
                self.hasher.bulkAdd(lh[1..], step - 1, @intCast(pos + 1));
            }
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

        fn findMatch(self: *Self, pos: usize, lh: []const u8, min_len: u16) ?Token {
            var length: usize = min_len;

            var match_pos = self.hasher.add(lh, @intCast(pos)); // TODO: rethink intCast

            var token: ?Token = null;

            var tries: usize = level.chain;
            if (min_len >= level.good) {
                // If we've got a match that's good enough, only look in 1/4 the chain.
                tries >>= 2;
            }
            while (match_pos != Hasher.not_found and tries > 0) : (tries -= 1) {
                const distance = pos - match_pos;
                if (distance > consts.match.max_distance or
                    match_pos < self.win.offset) break;
                const match_length = self.win.match(match_pos, pos);
                if (match_length > length) {
                    token = Token.initMatch(@intCast(distance), match_length);
                    if (length >= level.nice) {
                        // The match is good enough that we don't try to find a better one.
                        return token;
                    }
                    length = match_length;
                }
                match_pos = self.hasher.prev(match_pos);
            }

            return token;
        }

        fn flushTokens(self: *Self, final: bool) !void {
            try self.token_writer.writeBlock(self.tokens.tokens(), final, null);
            if (final) try self.token_writer.flush();
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

    pub fn writeBlock(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
        for (tokens) |t| {
            try expect(t.eql(self.expected[self.pos]));
            self.pos += 1;
        }
    }

    pub fn flush(_: *Self) !void {}
};

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

    // flush - process all data from window
    // If not flush preserve enough data to for the loghest match.
    // Returns null if there is not enough data.
    pub fn activeLookahead(self: *StreamWindow, flush: bool) ?[]const u8 {
        const preserve: usize = if (flush) 0 else consts.match.max_length;
        const lh = self.lookahead();
        return if (lh.len > preserve) lh else null;
    }

    pub fn history(self: *StreamWindow) []const u8 {
        return self.buffer[0..self.rp];
    }

    pub inline fn lookahead(self: *StreamWindow) []const u8 {
        assert(self.wp >= self.rp);
        return self.buffer[self.rp..self.wp];
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

    fn bulkAdd(self: *Hasher, b: []const u8, len: usize, idx: u32) void {
        if (len == 0 or b.len < consts.match.min_length) {
            return;
        }
        var hb =
            @as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24;
        _ = self.set(hashu(hb), idx);

        var i = idx;
        for (4..@min(len + 3, b.len)) |j| {
            hb = (hb << 8) | @as(u32, b[j]);
            i += 1;
            _ = self.set(hashu(hb), i);
        }
    }

    inline fn hash(b: *const [4]u8) u32 {
        return hashu(@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24);
    }

    inline fn hashu(v: u32) u32 {
        return (v *% mul) >> consts.hash.shift;
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

test "Hasher bulkAdd" {
    const data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit.";

    // one by one
    var h: Hasher = .{};
    for (data, 0..) |_, i| {
        _ = h.add(data[i..], @intCast(i));
    }

    // in bulk
    var bh: Hasher = .{};
    bh.bulkAdd(data, data.len, 0);

    try testing.expectEqualSlices(u32, &h.head, &bh.head);
    try testing.expectEqualSlices(u32, &h.chain, &bh.chain);
}

test "Token size" {
    // // TODO: remove this
    // print("size of Tokens {d}\n", .{
    //     @sizeOf(Tokens),
    // });
    try expect(@sizeOf(Token) == 4);
    try expect(@sizeOf(Tokens) == 131_080);
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

    const wrt = std.io.getStdOut().writer();

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

test "gzip compress file" {
    const input_file_name = "testdata/2600.txt.utf-8";
    var input = try std.fs.cwd().openFile(input_file_name, .{});
    defer input.close();

    const output_file_name = "testdata/output.gz";
    var output = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
    defer output.close();

    try gzip(input.reader(), output.writer());
}

test "zlib compress file" {
    const input_file_name = "testdata/2600.txt.utf-8";
    var input = try std.fs.cwd().openFile(input_file_name, .{});
    defer input.close();

    const output_file_name = "testdata/output.zz";
    var output = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
    defer output.close();

    try zlib(input.reader(), output.writer());
}

pub fn gzip(reader: anytype, writer: anytype) !void {
    var ev = envelope(reader, writer, .gzip);
    try ev.header();
    try deflate(ev.reader(), writer);
    try ev.footer();
}

pub fn zlib(reader: anytype, writer: anytype) !void {
    var ev = envelope(reader, writer, .zlib);
    try ev.header();
    try deflate(ev.reader(), writer);
    try ev.footer();
}

pub fn envelope(reader: anytype, writer: anytype, comptime kind: EnvelopeKind) Envelope(@TypeOf(reader), @TypeOf(writer), kind) {
    return .{ .rdr = reader, .wrt = writer };
}

const EnvelopeKind = enum {
    gzip,
    zlib,
};

/// Adds protocol header and footer for gzip or zlib compression. Needs to read
/// all uncompressed data to calculate cheksum. So accepts uncompressed data
/// reader, and provides reader for downstream deflate compressor.
fn Envelope(comptime ReaderType: type, comptime WriterType: type, comptime kind: EnvelopeKind) type {
    const HasherType = if (kind == .gzip)
        std.hash.Crc32
    else
        std.hash.Adler32;

    return struct {
        rdr: ReaderType,
        wrt: WriterType,
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
            return @truncate(self.bytes);
        }

        /// Writes protocol header to provided writer.
        pub fn header(self: *Self) !void {
            switch (kind) {
                .gzip => {
                    // GZIP 10 byte header (https://datatracker.ietf.org/doc/html/rfc1952#page-5):
                    //  - ID1 (IDentification 1), always 0x1f
                    //  - ID2 (IDentification 2), always 0x8b
                    //  - CM (Compression Method), always 8 = deflate
                    //  - FLG (Flags), all set to 0
                    //  - 4 bytes, MTIME (Modification time), not used, all set to zero
                    //  - XFL (eXtra FLags), all set to zero
                    //  - OS (Operating System), 03 = Unix
                    const gzipHeader = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 };
                    try self.wrt.writeAll(&gzipHeader);
                },
                .zlib => {
                    // ZLIB has a two-byte header (https://datatracker.ietf.org/doc/html/rfc1950#page-4):
                    // 1st byte:
                    //  - First four bits is the CINFO (compression info), which is 7 for the default deflate window size.
                    //  - The next four bits is the CM (compression method), which is 8 for deflate.
                    // 2nd byte:
                    //  - Two bits is the FLEVEL (compression level). Values are: 0=fastest, 1=fast, 2=default, 3=best.
                    //  - The next bit, FDICT, is set if a dictionary is given.
                    //  - The final five FCHECK bits form a mod-31 checksum.
                    //
                    // CINFO = 7, CM = 8, FLEVEL = 0b10, FDICT = 0, FCHECK = 0b11100
                    const zlibHeader = [_]u8{ 0x78, 0b10_0_11100 };
                    try self.wrt.writeAll(&zlibHeader);
                },
            }
        }

        /// Writes protocol footer to provided writer.
        pub fn footer(self: *Self) !void {
            var bits: [4]u8 = undefined;
            switch (kind) {
                .gzip => {
                    // GZIP 8 bytes footer
                    //  - 4 bytes, CRC32 (CRC-32)
                    //  - 4 bytes, ISIZE (Input SIZE) - size of the original (uncompressed) input data modulo 2^32
                    std.mem.writeInt(u32, &bits, self.chksum(), .little);
                    try self.wrt.writeAll(&bits);

                    std.mem.writeInt(u32, &bits, self.bytesRead(), .little);
                    try self.wrt.writeAll(&bits);
                },
                .zlib => {
                    // ZLIB (RFC 1950) is big-endian, unlike GZIP (RFC 1952).
                    // 4 bytes of ADLER32 (Adler-32 checksum)
                    // Checksum value of the uncompressed data (excluding any
                    // dictionary data) computed according to Adler-32
                    // algorithm.
                    std.mem.writeInt(u32, &bits, self.chksum(), .big);
                    try self.wrt.writeAll(&bits);
                },
            }
        }
    };
}

test "zlib FCHECK header 5 bits calculation example" {
    var h = [_]u8{ 0x78, 0b10_0_00000 };
    h[1] += 31 - @as(u8, @intCast(std.mem.readInt(u16, h[0..2], .big) % 31));
    try expect(h[1] == 0b10_0_11100);
    // print("{x} {x} {b}\n", .{ h[0], h[1], h[1] });
}
