const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Huffman = @import("huffman.zig").Huffman;
const BitReader = @import("bit_reader.zig").BitReader;

pub fn inflate(reader: anytype) Inflate(@TypeOf(reader)) {
    return Inflate(@TypeOf(reader)).init(reader);
}

// Non-compressible blocks are limited to 65,535 bytes.
// Backward pointer is limited in distance to 32K bytes and lengths to 258 bytes.

fn Inflate(comptime ReaderType: type) type {
    const BitReaderType = BitReader(ReaderType);
    return struct {
        rdr: BitReaderType,
        win: SlidingWindow = .{},

        // dynamic block huffman codes
        lit_h: Huffman(286) = .{}, // literals
        dst_h: Huffman(30) = .{}, // distances
        cl_h: Huffman(19) = .{}, // code length

        // current read state
        bfinal: u1 = 0,
        block_type: u2 = 0b11,
        state: ReadState = .gzip_header,

        const ReadState = enum {
            gzip_header,
            deflate_header,
            deflate_block,
            gzip_footer,
            end,
        };

        const Self = @This();

        pub fn init(rt: ReaderType) Self {
            return .{ .rdr = BitReaderType.init(rt) };
        }

        inline fn decodeLength(self: *Self, code: u16) !u16 {
            assert(code >= 256 and code <= 285);
            const bl = backwardLength(code);
            return bl.base_length + try self.rdr.readBits(bl.extra_bits);
        }

        inline fn decodeDistance(self: *Self, code: u16) !u16 {
            assert(code <= 29);
            const bd = backwardDistance(code);
            return bd.base_distance + try self.rdr.readBits(bd.extra_bits);
        }

        fn gzipHeader(self: *Self) !void {
            const magic1 = try self.rdr.readByte();
            const magic2 = try self.rdr.readByte();
            const method = try self.rdr.readByte();
            self.rdr.skipBytes(7); // flags, mtime(4), xflags, os
            if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08)
                return error.InvalidGzipHeader;
        }

        fn gzipFooter(self: *Self) !void {
            self.rdr.alignToByte();
            const chksum = try self.rdr.readU32();
            const size = try self.rdr.readU32();

            if (chksum != self.win.chksum()) return error.GzipFooterChecksum;
            if (size != self.win.size()) return error.GzipFooterSize;
        }

        fn nonCompressedBlock(self: *Self) !bool {
            self.rdr.alignToByte(); // skip 5 bits
            const len = try self.rdr.readU16();
            const nlen = try self.rdr.readU16();

            if (len != ~nlen) return error.DeflateWrongNlen;
            for (0..len) |_| {
                self.win.write(try self.rdr.readByte());
            }
            return true;
        }

        fn windowFull(self: *Self) bool {
            // 258 is largest back reference length.
            // That much bytes can be produced in single step.
            return self.win.free() < 258 + 1;
        }

        fn fixedBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                const code7 = try self.rdr.readLiteral(u7);

                if (code7 < 0b0010_111) { // 7 bits, 256-279, codes 0000_000 - 0010_111
                    if (code7 == 0) return true; // end of block code 256
                    const code: u16 = @as(u16, code7) + 256;
                    try self.fixedDistanceCode(code);
                } else if (code7 < 0b1011_111) { // 8 bits, 0-143, codes 0011_0000 through 1011_1111
                    const lit: u8 = (@as(u8, code7 - 0b0011_000) << 1) + try self.rdr.read(u1);
                    self.win.write(lit);
                } else if (code7 <= 0b1100_011) { // 8 bit, 280-287, codes 1100_0000 - 1100_0111
                    const code: u16 = (@as(u16, code7 - 0b1100011) << 1) + try self.rdr.read(u1) + 280;
                    try self.fixedDistanceCode(code);
                } else { // 9 bit, 144-255, codes 1_1001_0000 - 1_1111_1111
                    const lit: u8 = (@as(u8, code7 - 0b1100_100) << 2) + try self.rdr.readLiteral(u2) + 144;
                    self.win.write(lit);
                }
            }
            return false;
        }

        // Handles fixed block non literal (length) code.
        // Length code is followed by 5 bits of distance code.
        fn fixedDistanceCode(self: *Self, code: u16) !void {
            const length = try self.decodeLength(code);
            const distance = try self.decodeDistance(try self.rdr.read(u5));
            self.win.copy(length, distance);
        }

        fn initDynamicBlock(self: *Self) !void {
            const hlit: u16 = @as(u16, try self.rdr.read(u5)) + 257; // number of ll code entries present - 257
            const hdist: u16 = @as(u16, try self.rdr.read(u5)) + 1; // number of distance code entries - 1
            const hclen: u8 = @as(u8, try self.rdr.read(u4)) + 4; // hclen + 4 code lenths are encoded

            // lengths for code lengths
            var cl_l = [_]u4{0} ** 19;
            const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            for (0..hclen) |i| {
                cl_l[order[i]] = try self.rdr.read(u3);
            }
            self.cl_h.init(&cl_l);

            // literal code lengths
            var lit_l = [_]u4{0} ** (286);
            var pos: usize = 0;
            while (pos < hlit) {
                const sym = self.cl_h.find(self.rdr.peek7());
                self.rdr.advance(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &lit_l, pos);
            }

            // distance code lenths
            var dst_l = [_]u4{0} ** (30);
            pos = 0;
            while (pos < hdist) {
                const sym = self.cl_h.find(self.rdr.peek7());
                self.rdr.advance(sym.code_bits);
                pos += try self.dynamicCodeLength(sym.symbol, &dst_l, pos);
            }

            self.lit_h.init(&lit_l);
            self.dst_h.init(&dst_l);
        }

        fn dynamicBlock(self: *Self) !bool {
            while (!self.windowFull()) {
                const sym = self.lit_h.find(self.rdr.peek15());
                self.rdr.advance(sym.code_bits);

                const code = sym.symbol;
                if (code == 256) {
                    // end of block
                    return true;
                }
                if (code > 256) {
                    // decode backward pointer <length, distance>
                    const length = try self.decodeLength(code);

                    const dsm = self.dst_h.find(self.rdr.peek15()); // distance symbol
                    self.rdr.advance(dsm.code_bits);

                    const distance = try self.decodeDistance(dsm.symbol);
                    self.win.copy(length, distance);
                } else {
                    // literal
                    self.win.write(@intCast(code));
                }
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

        // Returns decompressed data from internal sliding window buffer.
        // Returned buffer can be any length between 0 and 65536 bytes,
        // 0 len means end of stream reached.
        pub fn read(self: *Self) ![]const u8 {
            while (true) {
                const buf = self.win.read();
                if (buf.len > 0) return buf;

                switch (self.state) {
                    .gzip_header => {
                        try self.gzipHeader();
                        self.state = .deflate_header;
                    },
                    .deflate_header => {
                        self.bfinal = try self.rdr.read(u1);
                        self.block_type = try self.rdr.read(u2);
                        self.state = .deflate_block;
                        if (self.block_type == 2) try self.initDynamicBlock();
                    },
                    .deflate_block => {
                        const done = switch (self.block_type) {
                            0 => try self.nonCompressedBlock(),
                            1 => try self.fixedBlock(),
                            2 => try self.dynamicBlock(),
                            else => unreachable,
                        };
                        if (done)
                            self.state = if (self.bfinal == 1) .gzip_footer else .deflate_header;
                    },
                    .gzip_footer => {
                        try self.gzipFooter();
                        self.state = .end;
                    },
                    .end => {
                        return buf;
                    },
                }
            }
        }
    };
}

fn backwardLength(c: u16) BackwardLength {
    return backward_lengths[c - 257];
}

const BackwardLength = struct {
    code: u16,
    extra_bits: u4,
    base_length: u16,
};

const backward_lengths = [_]BackwardLength{
    .{ .code = 257, .extra_bits = 0, .base_length = 3 },
    .{ .code = 258, .extra_bits = 0, .base_length = 4 },
    .{ .code = 259, .extra_bits = 0, .base_length = 5 },
    .{ .code = 260, .extra_bits = 0, .base_length = 6 },
    .{ .code = 261, .extra_bits = 0, .base_length = 7 },
    .{ .code = 262, .extra_bits = 0, .base_length = 8 },
    .{ .code = 263, .extra_bits = 0, .base_length = 9 },
    .{ .code = 264, .extra_bits = 0, .base_length = 10 },
    .{ .code = 265, .extra_bits = 1, .base_length = 11 },
    .{ .code = 266, .extra_bits = 1, .base_length = 13 },
    .{ .code = 267, .extra_bits = 1, .base_length = 15 },
    .{ .code = 268, .extra_bits = 1, .base_length = 17 },
    .{ .code = 269, .extra_bits = 2, .base_length = 19 },
    .{ .code = 270, .extra_bits = 2, .base_length = 23 },
    .{ .code = 271, .extra_bits = 2, .base_length = 27 },
    .{ .code = 272, .extra_bits = 2, .base_length = 31 },
    .{ .code = 273, .extra_bits = 3, .base_length = 35 },
    .{ .code = 274, .extra_bits = 3, .base_length = 43 },
    .{ .code = 275, .extra_bits = 3, .base_length = 51 },
    .{ .code = 276, .extra_bits = 3, .base_length = 59 },
    .{ .code = 277, .extra_bits = 4, .base_length = 67 },
    .{ .code = 278, .extra_bits = 4, .base_length = 83 },
    .{ .code = 279, .extra_bits = 4, .base_length = 99 },
    .{ .code = 280, .extra_bits = 4, .base_length = 115 },
    .{ .code = 281, .extra_bits = 5, .base_length = 131 },
    .{ .code = 282, .extra_bits = 5, .base_length = 163 },
    .{ .code = 283, .extra_bits = 5, .base_length = 195 },
    .{ .code = 284, .extra_bits = 5, .base_length = 227 },
    .{ .code = 285, .extra_bits = 0, .base_length = 258 },
};

fn backwardDistance(c: u16) BackwardDistance {
    return backward_distances[c];
}

const BackwardDistance = struct {
    code: u8,
    extra_bits: u4,
    base_distance: u16,
};

const backward_distances = [_]BackwardDistance{
    .{ .code = 0, .extra_bits = 0, .base_distance = 1 },
    .{ .code = 1, .extra_bits = 0, .base_distance = 2 },
    .{ .code = 2, .extra_bits = 0, .base_distance = 3 },
    .{ .code = 3, .extra_bits = 0, .base_distance = 4 },
    .{ .code = 4, .extra_bits = 1, .base_distance = 5 },
    .{ .code = 5, .extra_bits = 1, .base_distance = 7 },
    .{ .code = 6, .extra_bits = 2, .base_distance = 9 },
    .{ .code = 7, .extra_bits = 2, .base_distance = 13 },
    .{ .code = 8, .extra_bits = 3, .base_distance = 17 },
    .{ .code = 9, .extra_bits = 3, .base_distance = 25 },
    .{ .code = 10, .extra_bits = 4, .base_distance = 33 },
    .{ .code = 11, .extra_bits = 4, .base_distance = 49 },
    .{ .code = 12, .extra_bits = 5, .base_distance = 65 },
    .{ .code = 13, .extra_bits = 5, .base_distance = 97 },
    .{ .code = 14, .extra_bits = 6, .base_distance = 129 },
    .{ .code = 15, .extra_bits = 6, .base_distance = 193 },
    .{ .code = 16, .extra_bits = 7, .base_distance = 257 },
    .{ .code = 17, .extra_bits = 7, .base_distance = 385 },
    .{ .code = 18, .extra_bits = 8, .base_distance = 513 },
    .{ .code = 19, .extra_bits = 8, .base_distance = 769 },
    .{ .code = 20, .extra_bits = 9, .base_distance = 1025 },
    .{ .code = 21, .extra_bits = 9, .base_distance = 1537 },
    .{ .code = 22, .extra_bits = 10, .base_distance = 2049 },
    .{ .code = 23, .extra_bits = 10, .base_distance = 3073 },
    .{ .code = 24, .extra_bits = 11, .base_distance = 4097 },
    .{ .code = 25, .extra_bits = 11, .base_distance = 6145 },
    .{ .code = 26, .extra_bits = 12, .base_distance = 8193 },
    .{ .code = 27, .extra_bits = 12, .base_distance = 12289 },
    .{ .code = 28, .extra_bits = 13, .base_distance = 16385 },
    .{ .code = 29, .extra_bits = 13, .base_distance = 24577 },
};

test "inflate test cases" {
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
    };
    for (cases) |c| {
        var fb = std.io.fixedBufferStream(c.in);
        var il = inflate(fb.reader());
        try testing.expectEqualStrings(c.out, try il.read());
        try testing.expect((try il.read()).len == 0);
    }
}

const SlidingWindow = struct {
    const mask = 0xffff; // 64K - 1
    const buffer_len = mask + 1; // 64K buffer

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0, // write position
    rp: usize = 0, // read position
    crc: std.hash.Crc32 = std.hash.Crc32.init(),

    pub fn writeAll(self: *SlidingWindow, buf: []const u8) void {
        for (buf) |c| self.write(c);
    }

    pub fn write(self: *SlidingWindow, b: u8) void {
        assert(self.wp - self.rp < mask);
        self.buffer[self.wp & mask] = b;
        self.wp += 1;
    }

    pub fn copy(self: *SlidingWindow, length: u16, distance: u16) void {
        assert(self.wp - self.rp < mask);
        var from: usize = self.wp - distance;
        const from_end: usize = from + length;
        var to: usize = self.wp;
        const to_end: usize = to + length;

        self.wp += length;

        // fast path for
        // non overlapping buffers
        // start and and at the same circle
        if (to > from_end and ((from >> 16) == (to_end >> 16))) {
            @memcpy(self.buffer[to & mask .. to_end & mask], self.buffer[from & mask .. from_end & mask]);
            return;
        }

        // slow path
        while (to < to_end) {
            self.buffer[to & mask] = self.buffer[from & mask];
            to += 1;
            from += 1;
        }
    }

    pub fn read(self: *SlidingWindow) []const u8 {
        return self.readAtMost(buffer_len);
    }

    pub fn readAtMost(self: *SlidingWindow, max: usize) []const u8 {
        const rb = self.readBlock(max);
        defer self.rp += rb.len;
        const buf = self.buffer[rb.head..rb.tail];
        self.crc.update(buf);
        return buf;
    }

    const ReadBlock = struct {
        head: usize,
        tail: usize,
        len: usize,
    };

    // Returns position of continous read block data.
    inline fn readBlock(self: *SlidingWindow, max: usize) ReadBlock {
        const r = self.rp & mask;
        const w = self.wp & mask;
        const n = @min(
            max,
            if (w >= r) w - r else buffer_len - r,
        );
        return .{
            .head = r,
            .tail = r + n,
            .len = n,
        };
    }

    pub fn free(self: *SlidingWindow) usize {
        return buffer_len - (self.wp - self.rp);
    }

    pub fn chksum(self: *SlidingWindow) u32 {
        return self.crc.final();
    }

    // bytes written
    pub fn size(self: *SlidingWindow) u32 {
        return @intCast(self.wp);
    }
};

// example from: https://youtu.be/SJPvNi4HrWQ?t=3558
test "SlidingWindow copy" {
    var sw: SlidingWindow = .{};

    sw.writeAll("a salad; ");
    sw.copy(5, 9);
    sw.copy(2, 3);

    try testing.expectEqualStrings("a salad; a salsa", sw.read());
}

test "SlidingWindow copy overlap" {
    var sw: SlidingWindow = .{};

    sw.writeAll("a b c ");
    sw.copy(8, 4);
    sw.write('d');

    try testing.expectEqualStrings("a b c b c b c d", sw.read());
}

test "SlidingWindow readAtMost" {
    var sw: SlidingWindow = .{};

    sw.writeAll("0123456789");
    sw.copy(50, 10);

    try testing.expectEqualStrings("0123456789" ** 6, sw.buffer[sw.rp..sw.wp]);
    for (0..6) |i| {
        try testing.expectEqual(i * 10, sw.rp);
        try testing.expectEqualStrings("0123456789", sw.readAtMost(10));
    }
    try testing.expectEqualStrings("", sw.readAtMost(10));
    try testing.expectEqualStrings("", sw.read());
}

test "SlidingWindow circular buffer" {
    var sw: SlidingWindow = .{};

    const data = "0123456789abcdef" ** (1024 / 16);
    sw.writeAll(data);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024 * 63), sw.free());

    sw.copy(62 * 1024, 1024);
    try testing.expectEqual(@as(usize, 0), sw.rp);
    try testing.expectEqual(@as(usize, 63 * 1024), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.free());

    sw.writeAll(data[0..200]);
    _ = sw.readAtMost(1024); // make some space
    sw.writeAll(data); // overflows write position
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 1024), sw.rp);
    try testing.expectEqual(@as(usize, 1024 - 200), sw.free());

    const rb = sw.readBlock(SlidingWindow.buffer_len);
    try testing.expectEqual(@as(usize, 65536 - 1024), rb.len);
    try testing.expectEqual(@as(usize, 1024), rb.head);
    try testing.expectEqual(@as(usize, 65536), rb.tail);

    try testing.expectEqual(@as(usize, 65536 - 1024), sw.read().len); // read to the end of the buffer
    try testing.expectEqual(@as(usize, 200 + 65536), sw.wp);
    try testing.expectEqual(@as(usize, 65536), sw.rp);
    try testing.expectEqual(@as(usize, 65536 - 200), sw.free());

    try testing.expectEqual(@as(usize, 200), sw.read().len); // read the rest
}

test "SlidingWindow write over border" {
    var sw: SlidingWindow = .{};
    sw.wp = sw.buffer.len - 15;
    sw.rp = sw.wp;

    sw.writeAll("0123456789");
    sw.writeAll("abcdefghij");

    try testing.expectEqual(sw.buffer.len + 5, sw.wp);
    try testing.expectEqual(sw.buffer.len - 15, sw.rp);

    try testing.expectEqualStrings("0123456789abcde", sw.read());
    try testing.expectEqualStrings("fghij", sw.read());

    try testing.expect(sw.wp == sw.rp);
}

test "SlidingWindow copy over border" {
    var sw: SlidingWindow = .{};
    sw.wp = sw.buffer.len - 15;
    sw.rp = sw.wp;

    sw.writeAll("0123456789");
    sw.copy(15, 5);

    try testing.expectEqualStrings("012345678956789", sw.read());
    try testing.expectEqualStrings("5678956789", sw.read());

    sw.copy(20, 25);
    try testing.expectEqualStrings("01234567895678956789", sw.read());
}
