const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const hfd = @import("huffman_decoder.zig");
const BitReader = @import("bit_reader.zig").BitReader;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Wrapper = @import("wrapper.zig").Wrapper;
const Token = @import("Token.zig");
const codegen_order = @import("consts.zig").huffman.codegen_order;

pub fn decompress(comptime wrap: Wrapper, input_reader: anytype, output_writer: anytype) !void {
    var inf = decompressor(wrap, input_reader);
    while (try inf.nextChunk()) |buf| {
        try output_writer.writeAll(buf);
    }
}

pub fn decompressor(comptime wrap: Wrapper, reader: anytype) Inflate(wrap, @TypeOf(reader)) {
    return Inflate(wrap, @TypeOf(reader)).init(reader);
}

pub fn Inflate(comptime wrap: Wrapper, comptime ReaderType: type) type {
    const BitReaderType = BitReader(ReaderType);
    const F = BitReaderType.flag;

    return struct {
        bits: BitReaderType,
        win: SlidingWindow = .{},
        hasher: wrap.Hasher() = .{},

        // dynamic block huffman codes
        lit_h: hfd.LiteralDecoder = .{}, // literals
        dst_h: hfd.DistanceDecoder = .{}, // distances

        // current read state
        bfinal: u1 = 0,
        block_type: u2 = 0b11,
        state: ReadState = .protocol_header,

        const ReadState = enum {
            protocol_header,
            block_header,
            block,
            protocol_footer,
            end,
        };

        const Self = @This();

        pub fn init(rt: ReaderType) Self {
            return .{ .bits = BitReaderType.init(rt) };
        }

        inline fn windowFull(self: *Self) bool {
            // 258 is largest back reference length.
            // That much bytes can be produced in single step.
            return self.win.free() < 258 + 1;
        }

        fn blockHeader(self: *Self) !void {
            self.bfinal = try self.bits.read(u1);
            self.block_type = try self.bits.read(u2);
        }

        fn storedBlock(self: *Self) !bool {
            self.bits.alignToByte(); // skip 5 bits (block header is 3 bits)
            var len = try self.bits.read(u16);
            const nlen = try self.bits.read(u16);
            if (len != ~nlen) return error.DeflateWrongNlen;

            while (len > 0) {
                const buf = self.win.getWritable(len);
                try self.bits.readAll(buf);
                len -= @intCast(buf.len);
            }
            return true;
        }

        fn fixedBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                const code = try self.bits.readFixedCode();
                switch (code) {
                    0...255 => self.win.write(@intCast(code)),
                    256 => return true, // end of block
                    257...285 => try self.fixedDistanceCode(@intCast(code - 257)),
                    else => return error.Deflate,
                }
            }
            return false;
        }

        // Handles fixed block non literal (length) code.
        // Length code is followed by 5 bits of distance code.
        fn fixedDistanceCode(self: *Self, code: u8) !void {
            try self.bits.fill(5 + 5 + 13);
            const length = try self.decodeLength(code);
            const distance = try self.decodeDistance(try self.bits.readF(u5, F.buffered));
            self.win.writeCopy(length, distance);
        }

        inline fn decodeLength(self: *Self, code: u8) !u16 {
            assert(code <= 28);
            const ml = Token.matchLength(code);
            return if (ml.extra_bits == 0) // 0 - 5 extra bits
                ml.base
            else
                ml.base + try self.bits.readN(ml.extra_bits, F.buffered);
        }

        inline fn decodeDistance(self: *Self, code: u8) !u16 {
            assert(code <= 29);
            const md = Token.matchDistance(code);
            return if (md.extra_bits == 0) // 0 - 13 extra bits
                md.base
            else
                md.base + try self.bits.readN(md.extra_bits, F.buffered);
        }

        fn dynamicBlockHeader(self: *Self) !void {
            const hlit: u16 = @as(u16, try self.bits.read(u5)) + 257; // number of ll code entries present - 257
            const hdist: u16 = @as(u16, try self.bits.read(u5)) + 1; // number of distance code entries - 1
            const hclen: u8 = @as(u8, try self.bits.read(u4)) + 4; // hclen + 4 code lenths are encoded

            // lengths for code lengths
            var cl_l = [_]u4{0} ** 19;
            for (0..hclen) |i| {
                cl_l[codegen_order[i]] = try self.bits.read(u3);
            }
            var cl_h: hfd.CodegenDecoder = .{};
            cl_h.build(&cl_l);

            // literal code lengths
            var lit_l = [_]u4{0} ** (286);
            var pos: usize = 0;
            while (pos < hlit) {
                const sym = cl_h.find(try self.bits.peekF(u7, F.reverse));
                self.bits.shift(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &lit_l, pos);
            }

            // distance code lenths
            var dst_l = [_]u4{0} ** (30);
            pos = 0;
            while (pos < hdist) {
                const sym = cl_h.find(try self.bits.peekF(u7, F.reverse));
                self.bits.shift(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &dst_l, pos);
            }

            self.lit_h.build(&lit_l);
            self.dst_h.build(&dst_l);
        }

        // Decode code length symbol to code length.
        // Returns number of postitions advanced.
        fn dynamicCodeLength(self: *Self, code: u16, lens: []u4, pos: usize) !usize {
            assert(code <= 18);
            switch (code) {
                16 => {
                    // Copy the previous code length 3 - 6 times.
                    // The next 2 bits indicate repeat length
                    const n: u8 = @as(u8, try self.bits.read(u2)) + 3;
                    for (0..n) |i| {
                        lens[pos + i] = lens[pos + i - 1];
                    }
                    return n;
                },
                // Repeat a code length of 0 for 3 - 10 times. (3 bits of length)
                17 => return @as(u8, try self.bits.read(u3)) + 3,
                // Repeat a code length of 0 for 11 - 138 times (7 bits of length)
                18 => return @as(u8, try self.bits.read(u7)) + 11,
                else => {
                    // Represent code lengths of 0 - 15
                    lens[pos] = @intCast(code);
                    return 1;
                },
            }
        }

        fn dynamicBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                try self.bits.fill(15); // optimization so other bit reads can be buffered (avoiding one in hot path)
                const sym = try self.decodeSymbol(&self.lit_h);

                if (sym.kind == .literal) {
                    self.win.write(sym.symbol);
                    continue;
                }
                if (sym.kind == .end_of_block) {
                    return true;
                }

                // Decode match backreference <length, distance>
                try self.bits.fill(5 + 15 + 13); // so we can use buffered reads
                const length = try self.decodeLength(sym.symbol);
                const dsm = try self.decodeSymbol(&self.dst_h);
                const distance = try self.decodeDistance(dsm.symbol);
                self.win.writeCopy(length, distance);
            }
            return false;
        }

        // Peek 15 bits from bits reader (maximum code len is 15 bits). Use
        // decoder to find symbol for that code. We then know how many bits is
        // used. Shift bit reader for that much bits, those bits are used. And
        // return symbol.
        inline fn decodeSymbol(self: *Self, decoder: anytype) !hfd.Symbol {
            const sym = decoder.find(try self.bits.peekF(u15, F.buffered | F.reverse));
            self.bits.shift(sym.code_bits);
            return sym;
        }

        fn step(self: *Self) Error!void {
            switch (self.state) {
                .protocol_header => {
                    try self.parseHeader();
                    self.state = .block_header;
                },
                .block_header => {
                    try self.blockHeader();
                    self.state = .block;
                    if (self.block_type == 2) try self.dynamicBlockHeader();
                },
                .block => {
                    const done = switch (self.block_type) {
                        0 => try self.storedBlock(),
                        1 => try self.fixedBlock(),
                        2 => try self.dynamicBlock(),
                        else => return error.DeflateInvalidBlock,
                    };
                    if (done) {
                        self.state = if (self.bfinal == 1) .protocol_footer else .block_header;
                    }
                },
                .protocol_footer => {
                    self.bits.alignToByte();
                    try self.parseFooter();
                    self.state = .end;
                },
                .end => {},
            }
        }

        fn parseHeader(self: *Self) !void {
            try wrap.parseHeader(&self.bits);
        }

        fn parseFooter(self: *Self) !void {
            try wrap.parseFooter(&self.hasher, &self.bits);
        }

        /// Returns decompressed data from internal sliding window buffer.
        /// Returned buffer can be any length between 0 and 65536 bytes,
        /// null means end of stream reached.
        /// Can be used in iterator like loop without memcpy to another buffer:
        ///   while (try inflate.nextChunk()) |buf| { ... }
        pub fn nextChunk(self: *Self) Error!?[]const u8 {
            while (true) {
                const out = self.win.read();
                self.hasher.update(out);
                if (out.len > 0) return out;
                if (self.state == .end) return null;
                try self.step();
            }
        }

        // Reader interface implementation

        pub const Error = ReaderType.Error || error{
            EndOfStream,
            Deflate,
            DeflateInvalidBlock,
            DeflateWrongNlen,
            GzipFooterChecksum,
            GzipFooterSize,
            ZlibFooterChecksum,
            InvalidGzipHeader,
            InvalidZlibHeader,
        };
        pub const Reader = std.io.Reader(*Self, Error, read);

        /// Returns the number of bytes read. It may be less than buffer.len.
        /// If the number of bytes read is 0, it means end of stream.
        /// End of stream is not an error condition.
        pub fn read(self: *Self, buffer: []u8) Error!usize {
            while (true) {
                const out = self.win.readAtMost(buffer.len);
                if (out.len > 0) {
                    self.hasher.update(out);
                    @memcpy(buffer[0..out.len], out);
                    return out.len;
                }
                if (self.state == .end) return 0;
                try self.step();
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

// Allocates ~200K of internal buffers, most important are:
//   - 64K for sliding window
//   - 64K (2 * 32K of u16) for huffman codes
test "Struct sizes" {
    var fbs = std.io.fixedBufferStream("");
    const ReaderType = @TypeOf(fbs.reader());
    const inflate_size = @sizeOf(Inflate(.gzip, ReaderType));

    try testing.expectEqual(199352, inflate_size);
    try testing.expectEqual(
        @sizeOf(SlidingWindow) + @sizeOf(hfd.LiteralDecoder) + @sizeOf(hfd.DistanceDecoder) + 48,
        inflate_size,
    );
    try testing.expectEqual(65536 + 8 + 8, @sizeOf(SlidingWindow));
    try testing.expectEqual(8, @sizeOf(Wrapper.raw.Hasher()));
    try testing.expectEqual(24, @sizeOf(BitReader(ReaderType)));
    try testing.expectEqual(67132, @sizeOf(hfd.LiteralDecoder));
    try testing.expectEqual(66620, @sizeOf(hfd.DistanceDecoder));
}

test "flate decompress" {
    const cases = [_]struct {
        in: []const u8,
        out: []const u8,
    }{
        // non compressed block (type 0)
        .{
            .in = &[_]u8{
                0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
                'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
            },
            .out = "Hello world\n",
        },
        // fixed code block (type 1)
        .{
            .in = &[_]u8{
                0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate data block type 1
                0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
            },
            .out = "Hello world\n",
        },
        // dynamic block (type 2)
        .{
            .in = &[_]u8{
                0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02, // deflate data block type 2
                0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38,
                0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
            },
            .out = "ABCDEABCD ABCDEABCD",
        },
    };
    for (cases) |c| {
        var fb = std.io.fixedBufferStream(c.in);
        var al = std.ArrayList(u8).init(testing.allocator);
        defer al.deinit();

        try decompress(.raw, fb.reader(), al.writer());
        try testing.expectEqualStrings(c.out, al.items);
    }
}

test "gzip decompress" {
    const cases = [_]struct {
        in: []const u8,
        out: []const u8,
    }{
        // non compressed block (type 0)
        .{
            .in = &[_]u8{
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // gzip header (10 bytes)
                0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
                'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
                0xd5, 0xe0, 0x39, 0xb7, // gzip footer: checksum
                0x0c, 0x00, 0x00, 0x00, // gzip footer: size
            },
            .out = "Hello world\n",
        },
        // fixed code block (type 1)
        .{
            .in = &[_]u8{
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, // gzip header (10 bytes)
                0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate data block type 1
                0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
                0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00, // gzip footer (chksum, len)
            },
            .out = "Hello world\n",
        },
        // dynamic block (type 2)
        .{
            .in = &[_]u8{
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // gzip header (10 bytes)
                0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02, // deflate data block type 2
                0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38,
                0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
                0x17, 0x1c, 0x39, 0xb4, 0x13, 0x00, 0x00, 0x00, // gzip footer (chksum, len)
            },
            .out = "ABCDEABCD ABCDEABCD",
        },
        // gzip header with name
        .{
            .in = &[_]u8{
                0x1f, 0x8b, 0x08, 0x08, 0xe5, 0x70, 0xb1, 0x65, 0x00, 0x03, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e,
                0x74, 0x78, 0x74, 0x00, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1,
                0x02, 0x00, 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
            },
            .out = "Hello world\n",
        },
    };
    for (cases) |c| {
        var fb = std.io.fixedBufferStream(c.in);
        var al = std.ArrayList(u8).init(testing.allocator);
        defer al.deinit();

        try decompress(.gzip, fb.reader(), al.writer());
        try testing.expectEqualStrings(c.out, al.items);
    }
}

test "zlib decompress" {
    const cases = [_]struct {
        in: []const u8,
        out: []const u8,
    }{
        // non compressed block (type 0)
        .{
            .in = &[_]u8{
                0x78, 0b10_0_11100, // zlib header (2 bytes)
                0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
                'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
                0x1c, 0xf2, 0x04, 0x47, // zlib footer: checksum
            },
            .out = "Hello world\n",
        },
    };
    for (cases) |c| {
        var fb = std.io.fixedBufferStream(c.in);
        var al = std.ArrayList(u8).init(testing.allocator);
        defer al.deinit();

        try decompress(.zlib, fb.reader(), al.writer());
        try testing.expectEqualStrings(c.out, al.items);
    }
}
