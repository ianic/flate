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
    good: u16, // do less lookups if we already have match of this length
    nice: u16, // stop looking for better match if we found match with at least this length
    lazy: u16, // don't do lazy match find if got match with at least this length
    chain: u16, // how many lookups for previous match to perform

    pub fn get(compression: Compression) Level {
        return switch (compression) {
            .default => .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
            .best => .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
        };
    }
};

pub fn Deflate(comptime WriterType: type) type {
    const level = Level.get(.default);

    return struct {
        lookup: Lookup = .{},
        win: Window = .{},
        tokens: Tokens = .{},
        token_writer: WriterType,

        // Match and literal at the previous position.
        // Used for lazy match finding in processWindow.
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
                var step: u16 = 1; // 1 in the case of literal, match length otherwise
                const pos: u16 = self.win.pos();
                const literal = lh[0]; // literal at current position
                const min_len: u16 = if (self.prev_match) |m| m.length() else 0;

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
                self.windowAdvance(step, lh, pos);
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

        inline fn windowAdvance(self: *Self, step: u16, lh: []const u8, pos: u16) void {
            // assuming current position is already added in findMatch
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
            var chain: usize = level.chain;
            if (len >= level.good) {
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
                    if (new_len >= level.nice) {
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

        // slide win and if needed lookup tables
        inline fn slide(self: *Self) void {
            const n = self.win.slide();
            self.lookup.slide(n);
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

const Window = struct {
    const hist_len = consts.history.len;
    const buffer_len = 2 * hist_len;
    const min_lookahead = consts.match.min_length + consts.match.max_length;
    const max_rp = buffer_len - min_lookahead;

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position

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

    const n = win.slide();
    try expect(n == 32757);
    try expect(win.buffer[win.rp] == 0xab);
    try expect(win.rp == Window.hist_len - 111);
    try expect(win.wp == Window.hist_len - 11);
    try expect(win.lookahead().len == 100);
}

test "struct sizes" {
    try expect(@sizeOf(Token) == 4);
    try expect(@sizeOf(Tokens) == 131_080);
    try expect(@sizeOf(Lookup) == 393_216);
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
    const input_file_name = "benchdata/2600.txt.utf-8";
    var input = try std.fs.cwd().openFile(input_file_name, .{});
    defer input.close();

    const output_file_name = "benchdata/output.gz";
    var output = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
    defer output.close();

    try gzip(input.reader(), output.writer());
}

test "zlib compress file" {
    const input_file_name = "benchdata/2600.txt.utf-8";
    var input = try std.fs.cwd().openFile(input_file_name, .{});
    defer input.close();

    const output_file_name = "benchdata/output.zz";
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

    inline fn set(self: *Lookup, h: u16, idx: u16) u16 {
        const p = self.head[h];
        self.head[h] = idx;
        self.chain[idx] = p;
        return p;
    }

    // Slide all positions in head and chain for n.
    pub fn slide(self: *Lookup, n: u16) void {
        // TODO: try vector slide
        for (&self.head) |*v| {
            v.* -|= n;
        }
        for (&self.chain) |*v| {
            v.* -|= n;
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
    inline fn hash(b: *const [4]u8) u16 {
        return hashu(@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24);
    }

    inline fn hashu(v: u32) u16 {
        return @intCast((v *% prime4) >> 16);
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
            try testing.expect(prev == i - 8);
        } else {
            try testing.expect(prev == 0);
        }
    }

    const v = Lookup.hash(data[2 .. 2 + 4]);
    try testing.expect(h.head[v] == 2 + 16);
    try testing.expect(h.chain[2 + 16] == 2 + 8);
    try testing.expect(h.chain[2 + 8] == 2);
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
