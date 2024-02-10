const std = @import("std");
const io = std.io;
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const Token = @import("Token.zig");
const consts = @import("consts.zig");
const BlockWriter = @import("block_writer.zig").BlockWriter;
const Container = @import("container.zig").Container;
const SlidingWindow = @import("SlidingWindow.zig");
const Lookup = @import("Lookup.zig");

/// Trades between speed and compression size.
/// Starts with level 4: in [zlib](https://github.com/madler/zlib/blob/abd3d1a28930f89375d4b41408b39f6c1be157b2/deflate.c#L115C1-L117C43)
/// levels 1-3 are using different algorithm to perform faster but with less
/// compression. That is not implemented here.
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

/// Algorithm knobs for each level.
const LevelArgs = struct {
    good: u16, // Do less lookups if we already have match of this length.
    nice: u16, // Stop looking for better match if we found match with at least this length.
    lazy: u16, // Don't do lazy match find if got match with at least this length.
    chain: u16, // How many lookups for previous match to perform.

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

/// Compress plain data from reader into compressed stream written to writer.
pub fn compress(comptime container: Container, reader: anytype, writer: anytype, level: Level) !void {
    var c = try compressor(container, writer, level);
    try c.compress(reader);
    try c.close();
}

/// Create compressor for writer type.
pub fn compressor(comptime container: Container, writer: anytype, level: Level) !Compressor(
    container,
    @TypeOf(writer),
) {
    return try Compressor(container, @TypeOf(writer)).init(writer, level);
}

/// Compressor type.
pub fn Compressor(comptime container: Container, comptime WriterType: type) type {
    const TokenWriterType = BlockWriter(WriterType);
    return Deflate(container, WriterType, TokenWriterType);
}

/// Default compression algorithm. Has two steps: tokenization and token
/// encoding.
///
/// Tokenization takes uncompressed input stream and produces list of tokens.
/// Each token can be literal (byte of data) or match (backrefernce to previous
/// data with length and distance). Tokenization accumulators 32K tokens, when
/// full or `flush` is called tokens are passed to the `block_writer`. Level
/// defines how hard (how slow) it tries to find match.
///
/// Block writer will decide which type of deflate block to write (stored, fixed,
/// dynamic) and encode tokens to the output byte stream. Client has to call
/// `close` to write block with the final bit set.
///
/// Container defines type of header and footer which can be gzip, zlib or raw.
/// They all share same deflate body. Raw has no header or footer just deflate
/// body.
///
/// Compression algorithm explained in rfc-1951 (slightly edited for this case):
///
///   The compressor uses a chained hash table `lookup` to find duplicated
///   strings, using a hash function that operates on 4-byte sequences. At any
///   given point during compression, let XYZW be the next 4 input bytes
///   (lookahead) to be examined (not necessarily all different, of course).
///   First, the compressor examines the hash chain for XYZW. If the chain is
///   empty, the compressor simply writes out X as a literal byte and advances
///   one byte in the input. If the hash chain is not empty, indicating that the
///   sequence XYZW (or, if we are unlucky, some other 4 bytes with the same
///   hash function value) has occurred recently, the compressor compares all
///   strings on the XYZW hash chain with the actual input data sequence
///   starting at the current point, and selects the longest match.
///
///   To improve overall compression, the compressor defers the selection of
///   matches ("lazy matching"): after a match of length N has been found, the
///   compressor searches for a longer match starting at the next input byte. If
///   it finds a longer match, it truncates the previous match to a length of
///   one (thus producing a single literal byte) and then emits the longer
///   match. Otherwise, it emits the original match, and, as described above,
///   advances N bytes before continuing.
///
///
/// Allocates statically ~400K (192K lookup, 128K tokens, 64K window).
///
/// Deflate function accepts BlockWriterType so we can change that in test to test
/// just tokenization part.
///
fn Deflate(comptime container: Container, comptime WriterType: type, comptime BlockWriterType: type) type {
    return struct {
        lookup: Lookup = .{},
        win: SlidingWindow = .{},
        tokens: Tokens = .{},
        wrt: WriterType,
        block_writer: BlockWriterType,
        level: LevelArgs,
        hasher: container.Hasher() = .{},

        // Match and literal at the previous position.
        // Used for lazy match finding in processWindow.
        prev_match: ?Token = null,
        prev_literal: ?u8 = null,

        const Self = @This();
        pub fn init(wrt: WriterType, level: Level) !Self {
            const self = Self{
                .wrt = wrt,
                .block_writer = BlockWriterType.init(wrt),
                .level = LevelArgs.get(level),
            };
            try container.writeHeader(self.wrt);
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

        fn windowAdvance(self: *Self, step: u16, lh: []const u8, pos: u16) void {
            // current position is already added in findMatch
            self.lookup.bulkAdd(lh[1..], step - 1, pos + 1);
            self.win.advance(step);
        }

        // Add previous literal (if any) to the tokens list.
        fn addPrevLiteral(self: *Self) !void {
            if (self.prev_literal) |l| try self.addToken(Token.initLiteral(l));
        }

        // Add match to the tokens list, reset prev pointers.
        // Returns length of the added match.
        fn addMatch(self: *Self, m: Token) !u16 {
            try self.addToken(m);
            self.prev_literal = null;
            self.prev_match = null;
            return m.length();
        }

        fn addToken(self: *Self, token: Token) !void {
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

            // Hot path loop!
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
            try self.block_writer.write(self.tokens.tokens(), final, self.win.tokensBuffer());
            try self.block_writer.flush();
            self.tokens.reset();
            self.win.flush();
        }

        // Flush internal buffers to the output writer. Writes deflate block to
        // the writer. Internal tokens buffer is empty after this.
        pub fn flush(self: *Self) !void {
            try self.tokenize(.flush);
        }

        // Slide win and if needed lookup tables.
        fn slide(self: *Self) void {
            const n = self.win.slide();
            self.lookup.slide(n);
        }

        // Flush internal buffers and write deflate final block.
        pub fn close(self: *Self) !void {
            try self.tokenize(.final);
            try container.writeFooter(&self.hasher, self.wrt);
        }

        pub fn setWriter(self: *Self, new_writer: WriterType) void {
            self.block_writer.setWriter(new_writer);
            self.wrt = new_writer;
        }

        // Writes all data from the input reader of uncompressed data.
        // It is up to the caller to call flush or close if there is need to
        // output compressed blocks.
        pub fn compress(self: *Self, reader: anytype) !void {
            while (true) {
                // read from rdr into win
                const buf = self.win.writable();
                if (buf.len == 0) {
                    try self.tokenize(.none);
                    self.slide();
                    continue;
                }
                const n = try reader.readAll(buf);
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
        pub const Error = BlockWriterType.Error;

        // Write `input` of uncompressed data.
        pub fn write(self: *Self, input: []const u8) !usize {
            var fbs = io.fixedBufferStream(input);
            try self.compress(fbs.reader());
            return input.len;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

// Tokens store
const Tokens = struct {
    list: [consts.deflate.tokens]Token = undefined,
    pos: usize = 0,

    fn add(self: *Tokens, t: Token) void {
        self.list[self.pos] = t;
        self.pos += 1;
    }

    fn full(self: *Tokens) bool {
        return self.pos == self.list.len;
    }

    fn reset(self: *Tokens) void {
        self.pos = 0;
    }

    fn tokens(self: *Tokens) []const Token {
        return self.list[0..self.pos];
    }
};

/// Creates huffman only deflate blocks. Disables Lempel-Ziv match searching and
/// only performs Huffman entropy encoding. Results in faster compression, much
/// less memory requirements during compression but bigger compressed sizes.
///
pub fn HuffmanCompressor(comptime container: Container, comptime WriterType: type) type {
    return SimpleCompressor(.huffman, container, WriterType);
}

pub fn huffmanCompressor(comptime container: Container, writer: anytype) !HuffmanCompressor(container, @TypeOf(writer)) {
    return try HuffmanCompressor(container, @TypeOf(writer)).init(writer);
}

pub fn huffmanCompress(comptime container: Container, reader: anytype, writer: anytype) !void {
    var c = try huffmanCompressor(container, writer);
    try c.compress(reader);
    try c.close();
}

/// Creates store blocks only. Data are not compressed only packed into deflate
/// store blocks. That adds 9 bytes of header for each block. Max stored block
/// size is 64K. Block is emitted when flush is called on on close.
///
pub fn StoreCompressor(comptime container: Container, comptime WriterType: type) type {
    return SimpleCompressor(.store, container, WriterType);
}

pub fn storeCompressor(comptime container: Container, writer: anytype) !StoreCompressor(container, @TypeOf(writer)) {
    return try StoreCompressor(container, @TypeOf(writer)).init(writer);
}

pub fn storeCompress(comptime container: Container, reader: anytype, writer: anytype) !void {
    var c = try storeCompressor(container, writer);
    try c.compress(reader);
    try c.close();
}

const SimpleCompressorKind = enum {
    huffman,
    store,
};

fn simpleCompressor(
    comptime kind: SimpleCompressorKind,
    comptime container: Container,
    writer: anytype,
) !SimpleCompressor(kind, container, @TypeOf(writer)) {
    return try SimpleCompressor(kind, container, @TypeOf(writer)).init(writer);
}

fn SimpleCompressor(
    comptime kind: SimpleCompressorKind,
    comptime container: Container,
    comptime WriterType: type,
) type {
    const BlockWriterType = BlockWriter(WriterType);
    return struct {
        buffer: [65535]u8 = undefined, // because store blocks are limited to 65535 bytes
        wp: usize = 0,

        wrt: WriterType,
        block_writer: BlockWriterType,
        hasher: container.Hasher() = .{},

        const Self = @This();

        pub fn init(wrt: WriterType) !Self {
            const self = Self{
                .wrt = wrt,
                .block_writer = BlockWriterType.init(wrt),
            };
            try container.writeHeader(self.wrt);
            return self;
        }

        pub fn flush(self: *Self) !void {
            try self.flushBuffer(false);
        }

        pub fn close(self: *Self) !void {
            try self.flushBuffer(true);
            try container.writeFooter(&self.hasher, self.wrt);
        }

        fn flushBuffer(self: *Self, final: bool) !void {
            const buf = self.buffer[0..self.wp];
            switch (kind) {
                .huffman => try self.block_writer.huffmanBlock(buf, final),
                .store => try self.block_writer.storedBlock(buf, final),
            }
            try self.block_writer.flush();
            self.wp = 0;
        }

        // Writes all data from the input reader of uncompressed data.
        // It is up to the caller to call flush or close if there is need to
        // output compressed blocks.
        pub fn compress(self: *Self, reader: anytype) !void {
            while (true) {
                // read from rdr into buffer
                const buf = self.buffer[self.wp..];
                if (buf.len == 0) {
                    try self.flushBuffer(false);
                    continue;
                }
                const n = try reader.readAll(buf);
                self.hasher.update(buf[0..n]);
                self.wp += n;
                if (n < buf.len) break; // no more data in reader
            }
        }

        // Writer interface

        pub const Writer = io.Writer(*Self, Error, write);
        pub const Error = BlockWriterType.Error;

        // Write `input` of uncompressed data.
        pub fn write(self: *Self, input: []const u8) !usize {
            var fbs = io.fixedBufferStream(input);
            try self.compress(fbs.reader());
            return input.len;
        }

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
        .{
            .data = "ABCDEABCD ABCDEABCD",
            .tokens = &[_]Token{
                L('A'), L('B'),   L('C'), L('D'), L('E'), L('A'), L('B'), L('C'), L('D'), L(' '),
                L('A'), M(10, 8),
            },
        },
    };

    for (cases) |c| {
        inline for (Container.list) |container| { // for each wrapping
            var cw = io.countingWriter(io.null_writer);
            const cww = cw.writer();
            var df = try Deflate(container, @TypeOf(cww), TestTokenWriter).init(cww, .default);

            _ = try df.write(c.data);
            try df.flush();

            // df.token_writer.show();
            try expect(df.block_writer.pos == c.tokens.len); // number of tokens written
            try testing.expectEqualSlices(Token, df.block_writer.get(), c.tokens); // tokens match

            try testing.expectEqual(container.headerSize(), cw.bytes_written);
            try df.close();
            try testing.expectEqual(container.size(), cw.bytes_written);
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
    pub fn write(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
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
    try expect(@sizeOf(SlidingWindow) == window_size);

    const Bw = BlockWriter(@TypeOf(io.null_writer));
    // huffman bit writer internal: 11480
    const hbw_size = 11472; // 11.2k
    try expect(@sizeOf(Bw) == hbw_size);

    const D = Deflate(.raw, @TypeOf(io.null_writer), Bw);
    // 404744, 395.26K
    // ?Token: 6, ?u8: 2, level: 8
    try expect(@sizeOf(D) == tokens_size + lookup_size + window_size + hbw_size + 24);
    //print("Delfate size: {d} {d}\n", .{ @sizeOf(D), tokens_size + lookup_size + hbw_size + window_size });

    // current std lib deflate allocation:
    // 797_901, 779.2k
    // measured with:
    // var la = std.heap.logToWriterAllocator(testing.allocator, io.getStdOut().writer());
    // const allocator = la.allocator();
    // var cmp = try std.compress.deflate.compressor(allocator, io.null_writer, .{});
    // defer cmp.deinit();

    const HOC = HuffmanCompressor(.raw, @TypeOf(io.null_writer));
    //print("size of HOC {d}\n", .{@sizeOf(HOC)});
    try expect(@sizeOf(HOC) == 77024);
    // 64K buffer
    // 11480 huffman_encoded
    // 8 buffer write pointer
}

test "deflate file tokenization" {
    const levels = [_]Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const cases = [_]struct {
        data: []const u8, // uncompressed content
        // expected number of tokens producet in deflate tokenization
        tokens_count: [levels.len]usize = .{0} ** levels.len,
    }{
        .{
            .data = @embedFile("testdata/rfc1951.txt"),
            .tokens_count = .{ 7675, 7672, 7599, 7594, 7598, 7599 },
        },

        .{
            .data = @embedFile("testdata/huffman-null-max.input"),
            .tokens_count = .{ 257, 257, 257, 257, 257, 257 },
        },
        .{
            .data = @embedFile("testdata/huffman-pi.input"),
            .tokens_count = .{ 2570, 2564, 2564, 2564, 2564, 2564 },
        },
        .{
            .data = @embedFile("testdata/huffman-text.input"),
            .tokens_count = .{ 235, 234, 234, 234, 234, 234 },
        },
        .{
            .data = @embedFile("testdata/fuzzing/roundtrip1"),
            .tokens_count = .{ 333, 331, 331, 331, 331, 331 },
        },
        .{
            .data = @embedFile("testdata/fuzzing/roundtrip2"),
            .tokens_count = .{ 334, 334, 334, 334, 334, 334 },
        },
    };

    for (cases) |case| { // for each case
        const data = case.data;

        for (levels, 0..) |level, i| { // for each compression level
            var original = io.fixedBufferStream(data);

            // buffer for decompressed data
            var al = std.ArrayList(u8).init(testing.allocator);
            defer al.deinit();
            const writer = al.writer();

            // create compressor
            const WriterType = @TypeOf(writer);
            const TokenWriter = TokenDecoder(@TypeOf(writer));
            var cmp = try Deflate(.raw, WriterType, TokenWriter).init(writer, level);

            // Stream uncompressed `orignal` data to the compressor. It will
            // produce tokens list and pass that list to the TokenDecoder. This
            // TokenDecoder uses CircularBuffer from inflate to convert list of
            // tokens back to the uncompressed stream.
            try cmp.compress(original.reader());
            try cmp.flush();
            const expected_count = case.tokens_count[i];
            const actual = cmp.block_writer.tokens_count;
            if (expected_count == 0) {
                print("actual token count {d}\n", .{actual});
            } else {
                try testing.expectEqual(expected_count, actual);
            }

            try testing.expectEqual(data.len, al.items.len);
            try testing.expectEqualSlices(u8, data, al.items);
        }
    }
}

fn TokenDecoder(comptime WriterType: type) type {
    return struct {
        const CircularBuffer = @import("CircularBuffer.zig");
        hist: CircularBuffer = .{},
        wrt: WriterType,
        tokens_count: usize = 0,

        const Self = @This();

        pub fn init(wrt: WriterType) Self {
            return .{ .wrt = wrt };
        }

        pub fn write(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
            self.tokens_count += tokens.len;
            for (tokens) |t| {
                switch (t.kind) {
                    .literal => self.hist.write(t.literal()),
                    .match => try self.hist.writeMatch(t.length(), t.distance()),
                }
                if (self.hist.free() < 285) try self.flushWin();
            }
            try self.flushWin();
        }

        fn flushWin(self: *Self) !void {
            while (true) {
                const buf = self.hist.read();
                if (buf.len == 0) break;
                try self.wrt.writeAll(buf);
            }
        }

        pub fn flush(_: *Self) !void {}
    };
}

test "store simple compressor" {
    const data = "Hello world!";
    const expected = [_]u8{
        0x1, // block type 0, final bit set
        0xc, 0x0, // len = 12
        0xf3, 0xff, // ~len
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '!', //
        //0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21,
    };

    var fbs = std.io.fixedBufferStream(data);
    var al = std.ArrayList(u8).init(testing.allocator);
    defer al.deinit();

    var cmp = try storeCompressor(.raw, al.writer());
    try cmp.compress(fbs.reader());
    try cmp.close();
    try testing.expectEqualSlices(u8, &expected, al.items);

    fbs.reset();
    try al.resize(0);

    // huffman only compresoor will also emit store block for this small sample
    var hc = try huffmanCompressor(.raw, al.writer());
    try hc.compress(fbs.reader());
    try hc.close();
    try testing.expectEqualSlices(u8, &expected, al.items);
}
