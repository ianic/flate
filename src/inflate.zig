const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Huffman = @import("huffman.zig").Huffman;
const BitReader = @import("bit_reader.zig").BitReader;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const consts = @import("consts.zig");
const Wrapper = @import("wrapper.zig").Wrapper;
const Token = @import("Token.zig");

pub fn decompress(comptime wrap: Wrapper, input_reader: anytype, output_writer: anytype) !void {
    var inf = decompressor(wrap, input_reader);
    while (try inf.nextChunk()) |buf| {
        try output_writer.writeAll(buf);
    }
}

pub fn decompressor(comptime wrap: Wrapper, reader: anytype) Inflate(wrap, @TypeOf(reader)) {
    return Inflate(wrap, @TypeOf(reader)).init(reader);
}

/// Allocates 196K of internal buffers:
///   - 64K for sliding window
///   - 2 * 32K of u16 for huffman codes
///
pub fn Inflate(comptime wrap: Wrapper, comptime ReaderType: type) type {
    const BitReaderType = BitReader(ReaderType);
    return struct {
        rdr: BitReaderType,
        win: SlidingWindow = .{},
        hasher: wrap.Hasher() = .{},

        // dynamic block huffman codes
        lit_h: Huffman(286) = .{}, // literals
        dst_h: Huffman(30) = .{}, // distances
        cl_h: Huffman(19) = .{}, // code length

        // current read state
        bfinal: u1 = 0,
        block_type: u2 = 0b11,
        state: ReadState = .protocol_header,

        const ReadState = enum {
            protocol_header,
            header,
            block,
            protocol_footer,
            end,
        };

        const Self = @This();

        pub fn init(rt: ReaderType) Self {
            return .{ .rdr = BitReaderType.init(rt) };
        }

        inline fn decodeLength(self: *Self, code: u8) !u16 {
            assert(code <= 28);
            const ml = Token.matchLength(code);
            return if (ml.extra_bits == 0)
                ml.base
            else
                ml.base + self.rdr.readBufferedBits(ml.extra_bits);
        }

        inline fn decodeDistance(self: *Self, code: u8) !u16 {
            assert(code <= 29);
            const mo = Token.matchOffset(code);
            return if (mo.extra_bits == 0)
                mo.base
            else
                mo.base + self.rdr.readBufferedBits(mo.extra_bits);
        }

        fn nonCompressedBlock(self: *Self) !bool {
            self.rdr.alignToByte(); // skip 5 bits
            var len = try self.rdr.read(u16);
            const nlen = try self.rdr.read(u16);
            if (len != ~nlen) return error.DeflateWrongNlen;

            while (len > 0) {
                const buf = self.win.getWritable(len);
                try self.rdr.readAll(buf);
                len -= @intCast(buf.len);
            }
            return true;
        }

        inline fn windowFull(self: *Self) bool {
            // 258 is largest back reference length.
            // That much bytes can be produced in single step.
            return self.win.free() < 258 + 1;
        }

        fn fixedBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                try self.rdr.ensureBits(7 + 2, 7);
                const code7 = self.rdr.readBufferedCode(u7);

                if (code7 < 0b0010_111) { // 7 bits, 256-279, codes 0000_000 - 0010_111
                    if (code7 == 0) return true; // end of block code 256
                    try self.fixedDistanceCode(code7);
                } else if (code7 < 0b1011_111) { // 8 bits, 0-143, codes 0011_0000 through 1011_1111
                    const lit: u8 = (@as(u8, code7 - 0b0011_000) << 1) + self.rdr.readBuffered(u1);
                    self.win.write(lit);
                } else if (code7 <= 0b1100_011) { // 8 bit, 280-287, codes 1100_0000 - 1100_0111
                    // TODO hit this branch in test
                    const code: u8 = (@as(u8, code7 - 0b1100011) << 1) + self.rdr.readBuffered(u1) + (280 - 257);
                    try self.fixedDistanceCode(code);
                } else { // 9 bit, 144-255, codes 1_1001_0000 - 1_1111_1111
                    const lit: u8 = (@as(u8, code7 - 0b1100_100) << 2) + self.rdr.readBufferedCode(u2) + 144;
                    self.win.write(lit);
                }
            }
            return false;
        }

        // Handles fixed block non literal (length) code.
        // Length code is followed by 5 bits of distance code.
        fn fixedDistanceCode(self: *Self, code: u8) !void {
            try self.rdr.ensureBits(5 + 5 + 13, 5);
            const length = try self.decodeLength(code);
            const distance = try self.decodeDistance(self.rdr.readBuffered(u5));
            self.win.writeCopy(length, distance);
        }

        fn initDynamicBlock(self: *Self) !void {
            const hlit: u16 = @as(u16, try self.rdr.read(u5)) + 257; // number of ll code entries present - 257
            const hdist: u16 = @as(u16, try self.rdr.read(u5)) + 1; // number of distance code entries - 1
            const hclen: u8 = @as(u8, try self.rdr.read(u4)) + 4; // hclen + 4 code lenths are encoded

            // lengths for code lengths
            var cl_l = [_]u4{0} ** 19;
            const order = consts.huffman.codegen_order;
            for (0..hclen) |i| {
                cl_l[order[i]] = try self.rdr.read(u3);
            }
            self.cl_h.build(&cl_l);

            // literal code lengths
            var lit_l = [_]u4{0} ** (286);
            var pos: usize = 0;
            while (pos < hlit) {
                const sym = self.cl_h.find(try self.rdr.peekCode(u7));
                self.rdr.advance(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &lit_l, pos);
            }

            // distance code lenths
            var dst_l = [_]u4{0} ** (30);
            pos = 0;
            while (pos < hdist) {
                const sym = self.cl_h.find(try self.rdr.peekCode(u7));
                self.rdr.advance(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &dst_l, pos);
            }

            self.lit_h.build(&lit_l);
            self.dst_h.build(&dst_l);
        }

        fn dynamicBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                try self.rdr.ensureBits(15, 2);
                const sym = self.lit_h.find(self.rdr.peekBufferedCode(u15));
                self.rdr.advance(sym.code_bits);

                if (sym.kind == .literal) {
                    self.win.write(sym.symbol);
                    continue;
                }
                if (sym.kind == .end_of_block) {
                    // end of block
                    return true;
                }

                // decode backward pointer <length, distance>
                try self.rdr.ensureBits(33, 2);
                const length = try self.decodeLength(sym.symbol);

                const dsm = self.dst_h.find(self.rdr.peekBufferedCode(u15)); // distance symbol
                self.rdr.advance(dsm.code_bits);

                const distance = try self.decodeDistance(dsm.symbol);
                self.win.writeCopy(length, distance);
            }
            return false;
        }

        // Decode code length symbol to code length.
        // Returns number of postitions advanced.
        fn dynamicCodeLength(self: *Self, code: u16, lens: []u4, pos: usize) !usize {
            assert(code <= 18);
            switch (code) {
                16 => {
                    // Copy the previous code length 3 - 6 times.
                    // The next 2 bits indicate repeat length
                    const n: u8 = @as(u8, try self.rdr.read(u2)) + 3;
                    for (0..n) |i| {
                        lens[pos + i] = lens[pos + i - 1];
                    }
                    return n;
                },
                // Repeat a code length of 0 for 3 - 10 times. (3 bits of length)
                17 => return @as(u8, try self.rdr.read(u3)) + 3,
                // Repeat a code length of 0 for 11 - 138 times (7 bits of length)
                18 => return @as(u8, try self.rdr.read(u7)) + 11,
                else => {
                    // Represent code lengths of 0 - 15
                    lens[pos] = @intCast(code);
                    return 1;
                },
            }
        }

        fn step(self: *Self) Error!void {
            switch (self.state) {
                .protocol_header => {
                    try self.parseHeader();
                    self.state = .header;
                },
                .header => {
                    self.bfinal = try self.rdr.read(u1);
                    self.block_type = try self.rdr.read(u2);
                    self.state = .block;
                    if (self.block_type == 2) try self.initDynamicBlock();
                },
                .block => {
                    const done = switch (self.block_type) {
                        0 => try self.nonCompressedBlock(),
                        1 => try self.fixedBlock(),
                        2 => try self.dynamicBlock(),
                        else => unreachable,
                    };
                    if (done) {
                        self.state = if (self.bfinal == 1) .protocol_footer else .header;
                    }
                },
                .protocol_footer => {
                    self.rdr.alignToByte();
                    try self.parseFooter();
                    self.state = .end;
                },
                .end => {},
            }
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

        // reader interface implementation

        pub const Error = ReaderType.Error || error{
            EndOfStream,
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

        fn parseHeader(self: *Self) !void {
            try wrap.parseHeader(&self.rdr);
        }

        fn parseFooter(self: *Self) !void {
            try wrap.parseFooter(&self.hasher, &self.rdr);
        }
    };
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
