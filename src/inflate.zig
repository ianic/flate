const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Huffman = @import("huffman.zig").Huffman;
const BitReader = @import("bit_reader.zig").BitReader;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const consts = @import("consts.zig");
const wrapper = @import("wrapper.zig");

pub fn gzip(input_reader: anytype, output_writer: anytype) !void {
    try decompressWrapped(.gzip, input_reader, output_writer);
}

pub fn zlib(input_reader: anytype, output_writer: anytype) !void {
    try decompressWrapped(.zlib, input_reader, output_writer);
}

pub fn decompressWrapped(comptime kind: wrapper.Kind, input_reader: anytype, output_writer: anytype) !void {
    var inf = inflateReader(input_reader);
    // TODO: ovaj &inf.rdr mozda i nije najsretnije rjesenje
    var wrp = wrapper.init(kind, &inf.rdr, output_writer);
    try wrp.parseHeader();
    var writer = wrp.writer();
    while (try inf.nextChunk()) |buf| {
        try writer.writeAll(buf);
    }
    try wrp.parseFooter();
}

pub fn decompress(input_reader: anytype, output_writer: anytype) !void {
    var inf = inflateReader(input_reader);
    while (try inf.nextChunk()) |buf| {
        try output_writer.writeAll(buf);
    }
}

pub fn inflateReader(reader: anytype) Inflate(@TypeOf(reader)) {
    return Inflate(@TypeOf(reader)).init(reader);
}

/// Allocates 196K of internal buffers:
///   - 64K for sliding window
///   - 2 * 32K of u16 for huffman codes
///
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
        state: ReadState = .header,

        const ReadState = enum {
            header,
            block,
            end,
        };

        const Self = @This();

        pub fn init(rt: ReaderType) Self {
            return .{ .rdr = BitReaderType.init(rt) };
        }

        inline fn decodeLength(self: *Self, code: u8) !u16 {
            assert(code <= 28);
            const bl = backwardLength(code);
            return if (bl.extra_bits == 0)
                bl.base_length
            else
                bl.base_length + self.rdr.readBufferedBits(bl.extra_bits);
        }

        inline fn decodeDistance(self: *Self, code: u8) !u16 {
            assert(code <= 29);
            const bd = backwardDistance(code);
            return if (bd.extra_bits == 0)
                bd.base_distance
            else
                bd.base_distance + self.rdr.readBufferedBits(bd.extra_bits);
        }

        // fn gzipHeader(self: *Self) !void {
        //     const magic1 = try self.rdr.read(u8);
        //     const magic2 = try self.rdr.read(u8);
        //     const method = try self.rdr.read(u8);
        //     const flags = try self.rdr.read(u8);
        //     try self.rdr.skipBytes(6); // mtime(4), xflags, os
        //     if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08)
        //         return error.InvalidGzipHeader;
        //     // Flags description: https://www.rfc-editor.org/rfc/rfc1952.html#page-5
        //     if (flags != 0) {
        //         if (flags & 0b0000_0100 != 0) { // FEXTRA
        //             const extra_len = try self.rdr.read(u16);
        //             try self.rdr.skipBytes(extra_len);
        //         }
        //         if (flags & 0b0000_1000 != 0) { // FNAME
        //             try self.rdr.skipStringZ();
        //         }
        //         if (flags & 0b0001_0000 != 0) { // FCOMMENT
        //             try self.rdr.skipStringZ();
        //         }
        //         if (flags & 0b0000_0010 != 0) { // FHCRC
        //             try self.rdr.skipBytes(2);
        //         }
        //     }
        // }

        // fn gzipFooter(self: *Self) !void {
        //     self.rdr.alignToByte();
        //     const chksum = try self.rdr.read(u32);
        //     const size = try self.rdr.read(u32);

        //     if (chksum != self.win.chksum()) return error.GzipFooterChecksum;
        //     if (size != self.win.size()) return error.GzipFooterSize;
        // }

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
                        self.state = .header;
                        if (self.bfinal == 1) {
                            self.rdr.alignToByte();
                            self.state = .end;
                        }
                    }
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
                if (out.len > 0) return out;
                if (self.state == .end) return null;
                try self.step();
            }
        }

        // reader interface implementation

        pub const Error = ReaderType.Error || error{ EndOfStream, DeflateWrongNlen };
        pub const Reader = std.io.Reader(*Self, Error, read);

        /// Returns the number of bytes read. It may be less than buffer.len.
        /// If the number of bytes read is 0, it means end of stream.
        /// End of stream is not an error condition.
        pub fn read(self: *Self, buffer: []u8) Error!usize {
            while (true) {
                const out = self.win.readAtMost(buffer.len);
                if (out.len > 0) {
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

fn backwardLength(c: u16) BackwardLength {
    return backward_lengths[c];
}

const BackwardLength = struct {
    base_length: u16,
    extra_bits: u4,
};

const backward_lengths = [_]BackwardLength{
    .{ .extra_bits = 0, .base_length = 3 }, // code = 257
    .{ .extra_bits = 0, .base_length = 4 }, // code = 258
    .{ .extra_bits = 0, .base_length = 5 }, // code = 259
    .{ .extra_bits = 0, .base_length = 6 }, // code = 260
    .{ .extra_bits = 0, .base_length = 7 }, // code = 261
    .{ .extra_bits = 0, .base_length = 8 }, // code = 262
    .{ .extra_bits = 0, .base_length = 9 }, // code = 263
    .{ .extra_bits = 0, .base_length = 10 }, // code = 264
    .{ .extra_bits = 1, .base_length = 11 }, // code = 265
    .{ .extra_bits = 1, .base_length = 13 }, // code = 266
    .{ .extra_bits = 1, .base_length = 15 }, // code = 267
    .{ .extra_bits = 1, .base_length = 17 }, // code = 268
    .{ .extra_bits = 2, .base_length = 19 }, // code = 269
    .{ .extra_bits = 2, .base_length = 23 }, // code = 270
    .{ .extra_bits = 2, .base_length = 27 }, // code = 271
    .{ .extra_bits = 2, .base_length = 31 }, // code = 272
    .{ .extra_bits = 3, .base_length = 35 }, // code = 273
    .{ .extra_bits = 3, .base_length = 43 }, // code = 274
    .{ .extra_bits = 3, .base_length = 51 }, // code = 275
    .{ .extra_bits = 3, .base_length = 59 }, // code = 276
    .{ .extra_bits = 4, .base_length = 67 }, // code = 277
    .{ .extra_bits = 4, .base_length = 83 }, // code = 278
    .{ .extra_bits = 4, .base_length = 99 }, // code = 279
    .{ .extra_bits = 4, .base_length = 115 }, // code = 280
    .{ .extra_bits = 5, .base_length = 131 }, // code = 281
    .{ .extra_bits = 5, .base_length = 163 }, // code = 282
    .{ .extra_bits = 5, .base_length = 195 }, // code = 283
    .{ .extra_bits = 5, .base_length = 227 }, // code = 284
    .{ .extra_bits = 0, .base_length = 258 }, // code = 285
};

fn backwardDistance(c: u8) BackwardDistance {
    return backward_distances[c];
}

const BackwardDistance = struct {
    base_distance: u16,
    extra_bits: u4,
};

const backward_distances = [_]BackwardDistance{
    .{ .extra_bits = 0, .base_distance = 1 }, // code = 0
    .{ .extra_bits = 0, .base_distance = 2 }, // code = 1
    .{ .extra_bits = 0, .base_distance = 3 }, // code = 2
    .{ .extra_bits = 0, .base_distance = 4 }, // code = 3
    .{ .extra_bits = 1, .base_distance = 5 }, // code = 4
    .{ .extra_bits = 1, .base_distance = 7 }, // code = 5
    .{ .extra_bits = 2, .base_distance = 9 }, // code = 6
    .{ .extra_bits = 2, .base_distance = 13 }, // code = 7
    .{ .extra_bits = 3, .base_distance = 17 }, // code = 8
    .{ .extra_bits = 3, .base_distance = 25 }, // code = 9
    .{ .extra_bits = 4, .base_distance = 33 }, // code = 10
    .{ .extra_bits = 4, .base_distance = 49 }, // code = 11
    .{ .extra_bits = 5, .base_distance = 65 }, // code = 12
    .{ .extra_bits = 5, .base_distance = 97 }, // code = 13
    .{ .extra_bits = 6, .base_distance = 129 }, // code = 14
    .{ .extra_bits = 6, .base_distance = 193 }, // code = 15
    .{ .extra_bits = 7, .base_distance = 257 }, // code = 16
    .{ .extra_bits = 7, .base_distance = 385 }, // code = 17
    .{ .extra_bits = 8, .base_distance = 513 }, // code = 18
    .{ .extra_bits = 8, .base_distance = 769 }, // code = 19
    .{ .extra_bits = 9, .base_distance = 1025 }, // code = 20
    .{ .extra_bits = 9, .base_distance = 1537 }, // code = 21
    .{ .extra_bits = 10, .base_distance = 2049 }, // code = 22
    .{ .extra_bits = 10, .base_distance = 3073 }, // code = 23
    .{ .extra_bits = 11, .base_distance = 4097 }, // code = 24
    .{ .extra_bits = 11, .base_distance = 6145 }, // code = 25
    .{ .extra_bits = 12, .base_distance = 8193 }, // code = 26
    .{ .extra_bits = 12, .base_distance = 12289 }, // code = 27
    .{ .extra_bits = 13, .base_distance = 16385 }, // code = 28
    .{ .extra_bits = 13, .base_distance = 24577 }, // code = 29
};

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

        try decompress(fb.reader(), al.writer());
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

        try gzip(fb.reader(), al.writer());
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
                0x47, 0x04, 0xf2, 0x1c, // zlib footer: checksum
            },
            .out = "Hello world\n",
        },
    };
    for (cases) |c| {
        var fb = std.io.fixedBufferStream(c.in);
        var al = std.ArrayList(u8).init(testing.allocator);
        defer al.deinit();

        try zlib(fb.reader(), al.writer());
        try testing.expectEqualStrings(c.out, al.items);
    }
}
