const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn bitReader(reader: anytype) BitReader(@TypeOf(reader)) {
    return BitReader(@TypeOf(reader)).init(reader);
}

// Terminology:
// ensure - check that buffer has n bit, fill from underlying reader if bits are missing
// advance - shift buffer for n bits, bits are consumed
//
// read      - ensure, get data, advance
// peak      - ensure, get data
// readBuffered  - get data, advance (no ensure, assumes that enough number of bits exists in buffer)
// peakBuffered  - get data (no ensure, no advance)
// code      - do the bit reverse
pub fn BitReader(comptime ReaderType: type) type {
    return struct {
        // underlying reader
        rdr: ReaderType,
        // buffer of 64 bits
        bits: u64 = 0,
        // number of bits in the buffer
        nbits: u8 = 0,

        const Self = @This();

        pub fn init(rdr: ReaderType) Self {
            var self = Self{ .rdr = rdr };
            self.fill(1) catch {};
            return self;
        }

        // Ensure that `nice` or at least `must` bits are available in buffer.
        // Reads from underlying reader if there is no `nice` bits in buffer.
        // Returns error if `must` bits can't be read.
        pub inline fn fill(self: *Self, nice: u6) !void {
            if (self.nbits >= nice)
                return; // we have enought bits

            // read more bits from underlying reader
            var buf: [8]u8 = [_]u8{0} ** 8;
            // number of empty bytes in bits
            const empty_bytes =
                @as(u8, if (self.nbits & 0x7 == 0) 8 else 7) - // 8 for 8, 16, 24..., 7 otherwise
                (self.nbits >> 3); // 0 for 0-7, 1 for 8-16, ... same as / 8

            const bytes_read = self.rdr.read(buf[0..empty_bytes]) catch 0;
            if (bytes_read > 0) {
                const u: u64 = std.mem.readInt(u64, buf[0..8], .little);
                self.bits |= u << @as(u6, @intCast(self.nbits));
                self.nbits += 8 * @as(u8, @intCast(bytes_read));
                return;
            }

            if (self.bits == 0)
                return error.EndOfStream;
        }

        // Read exactly buf.len bytes into buf.
        pub fn readAll(self: *Self, buf: []u8) !void {
            assert(self.alignBits() == 0);

            var n: usize = 0;
            while (self.nbits > 0 and n < buf.len) {
                buf[n] = try self.read(u8, flag.buffered);
                n += 1;
            }
            try self.rdr.readNoEof(buf[n..]);
        }

        pub const flag = struct {
            pub const peek: u3 = 0b001;
            pub const buffered: u3 = 0b010;
            pub const reverse: u3 = 0b100;
        };

        pub inline fn read(self: *Self, comptime U: type, comptime how: u3) !U {
            const n: u6 = @bitSizeOf(U);
            switch (how) {
                0 => {
                    try self.fill(n);
                    const u: U = @truncate(self.bits);
                    self.shift(n);
                    return u;
                },
                (flag.peek) => {
                    try self.fill(n);
                    return @as(U, @truncate(self.bits));
                },
                flag.buffered => {
                    const u: U = @truncate(self.bits);
                    self.shift(n);
                    return u;
                },
                (flag.reverse) => {
                    try self.fill(n);
                    const u: U = @truncate(self.bits);
                    self.shift(n);
                    return @bitReverse(u);
                },
                (flag.peek | flag.reverse) => {
                    try self.fill(n);
                    return @bitReverse(@as(U, @truncate(self.bits)));
                },
                (flag.buffered | flag.reverse) => {
                    const u: U = @truncate(self.bits);
                    self.shift(n);
                    return @bitReverse(u);
                },
                (flag.peek | flag.buffered | flag.reverse) => {
                    return @bitReverse(@as(U, @truncate(self.bits)));
                },
                else => unreachable,
            }
        }

        pub inline fn readN(self: *Self, n: u4, comptime how: u3) !u16 {
            switch (how) {
                0 => {
                    try self.fill(n);
                },
                flag.buffered => {},
                else => unreachable,
            }
            const mask: u16 = (@as(u16, 1) << n) - 1;
            const u: u16 = @as(u16, @truncate(self.bits)) & mask;
            self.shift(n);
            return u;
        }

        // Advance buffer for n bits.
        pub inline fn shift(self: *Self, n: u6) void {
            assert(n <= self.nbits);
            self.bits >>= n;
            self.nbits -= n;
        }

        // Skip n bytes.
        pub inline fn skipBytes(self: *Self, n: u16) !void {
            for (0..n) |_| {
                try self.fill(8);
                self.shift(8);
            }
        }

        // Number of bits to align stream to the byte boundary.
        inline fn alignBits(self: *Self) u3 {
            return @intCast(self.nbits & 0x7);
        }

        // Align stream to the byte boundary.
        pub inline fn alignToByte(self: *Self) void {
            const ab = self.alignBits();
            if (ab > 0) self.shift(ab);
        }

        // Skip zero terminated string.
        pub fn skipStringZ(self: *Self) !void {
            while (true) {
                if (try self.read(u8, 0) == 0) break;
            }
        }

        // Read deflate fixed fixed code.
        // Reads first 7 bits, and then mybe 1 or 2 more to get full 7,8 or 9 bit code.
        // ref: https://datatracker.ietf.org/doc/html/rfc1951#page-12
        //         Lit Value    Bits        Codes
        //          ---------    ----        -----
        //            0 - 143     8          00110000 through
        //                                   10111111
        //          144 - 255     9          110010000 through
        //                                   111111111
        //          256 - 279     7          0000000 through
        //                                   0010111
        //          280 - 287     8          11000000 through
        //                                   11000111
        pub fn readFixedCode(self: *Self) !u16 {
            try self.fill(7 + 2);
            const code7 = try self.read(u7, flag.buffered | flag.reverse);
            if (code7 <= 0b0010_111) { // 7 bits, 256-279, codes 0000_000 - 0010_111
                return @as(u16, code7) + 256;
            } else if (code7 <= 0b1011_111) { // 8 bits, 0-143, codes 0011_0000 through 1011_1111
                return (@as(u16, code7) << 1) + @as(u16, try self.read(u1, flag.buffered)) - 0b0011_0000;
            } else if (code7 <= 0b1100_011) { // 8 bit, 280-287, codes 1100_0000 - 1100_0111
                return (@as(u16, code7 - 0b1100000) << 1) + try self.read(u1, flag.buffered) + 280;
            } else { // 9 bit, 144-255, codes 1_1001_0000 - 1_1111_1111
                return (@as(u16, code7 - 0b1100_100) << 2) + @as(u16, try self.read(u2, flag.buffered | flag.reverse)) + 144;
            }
        }
    };
}

test "BitReader" {
    var fbs = std.io.fixedBufferStream(&[_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0x00, 0x00 });
    var br = bitReader(fbs.reader());
    const F = BitReader(@TypeOf(fbs.reader())).flag;

    try testing.expectEqual(@as(u8, 48), br.nbits);
    try testing.expectEqual(@as(u64, 0xc9cd48f3), br.bits);

    try testing.expect(try br.read(u1, 0) == 0b0000_0001);
    try testing.expect(try br.read(u2, 0) == 0b0000_0001);
    try testing.expectEqual(@as(u8, 48 - 3), br.nbits);
    try testing.expectEqual(@as(u3, 5), br.alignBits());

    try testing.expect(try br.read(u8, F.peek) == 0b0001_1110);
    try testing.expect(try br.read(u9, F.peek) == 0b1_0001_1110);
    br.shift(9);
    try testing.expectEqual(@as(u8, 36), br.nbits);
    try testing.expectEqual(@as(u3, 4), br.alignBits());

    try testing.expect(try br.read(u4, 0) == 0b0100);
    try testing.expectEqual(@as(u8, 32), br.nbits);
    try testing.expectEqual(@as(u3, 0), br.alignBits());

    br.shift(1);
    try testing.expectEqual(@as(u3, 7), br.alignBits());
    br.shift(1);
    try testing.expectEqual(@as(u3, 6), br.alignBits());
    br.alignToByte();
    try testing.expectEqual(@as(u3, 0), br.alignBits());

    try testing.expectEqual(@as(u64, 0xc9), br.bits);
    try testing.expectEqual(@as(u16, 0x9), try br.readN(4, 0));
    try testing.expectEqual(@as(u16, 0xc), try br.readN(4, 0));
}

test "BitReader read block type 1 data" {
    const data = [_]u8{
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate data block type 1
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0x0c, 0x01, 0x02, 0x03, //
        0xaa, 0xbb, 0xcc, 0xdd,
    };
    var fbs = std.io.fixedBufferStream(&data);
    var br = bitReader(fbs.reader());
    const F = BitReader(@TypeOf(fbs.reader())).flag;

    try testing.expectEqual(@as(u1, 1), try br.read(u1, 0)); // bfinal
    try testing.expectEqual(@as(u2, 1), try br.read(u2, 0)); // block_type

    for ("Hello world\n") |c| {
        try testing.expectEqual(@as(u8, c), try br.read(u8, F.reverse) - 0x30);
    }
    try testing.expectEqual(@as(u7, 0), try br.read(u7, 0)); // end of block
    br.alignToByte();
    try testing.expectEqual(@as(u32, 0x0302010c), try br.read(u32, 0));
    try testing.expectEqual(@as(u16, 0xbbaa), try br.read(u16, 0));
    try testing.expectEqual(@as(u16, 0xddcc), try br.read(u16, 0));
}

test "BitReader init" {
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    };
    var fbs = std.io.fixedBufferStream(&data);
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u64, 0x08_07_06_05_04_03_02_01), br.bits);
    br.shift(8);
    try testing.expectEqual(@as(u64, 0x00_08_07_06_05_04_03_02), br.bits);
    try br.fill(60); // fill with 1 byte
    try testing.expectEqual(@as(u64, 0x01_08_07_06_05_04_03_02), br.bits);
    br.shift(8 * 4 + 4);
    try testing.expectEqual(@as(u64, 0x00_00_00_00_00_10_80_70), br.bits);

    try br.fill(60); // fill with 4 bytes (shift by 4)
    try testing.expectEqual(@as(u64, 0x00_50_40_30_20_10_80_70), br.bits);
    try testing.expectEqual(@as(u8, 8 * 7 + 4), br.nbits);

    br.shift(@intCast(br.nbits)); // clear buffer
    try br.fill(8); // refill with the rest of the bytes
    try testing.expectEqual(@as(u64, 0x00_00_00_00_00_08_07_06), br.bits);
}

test "BitReader readAll" {
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    };
    var fbs = std.io.fixedBufferStream(&data);
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u64, 0x08_07_06_05_04_03_02_01), br.bits);

    var out: [16]u8 = undefined;
    try br.readAll(out[0..]);
    try testing.expect(br.nbits == 0);
    try testing.expect(br.bits == 0);

    try testing.expectEqualSlices(u8, data[0..16], &out);
}

test "BitReader readFixedCode" {
    const fixed_codes = @import("huffman_encoder.zig").fixed_codes;

    var fbs = std.io.fixedBufferStream(&fixed_codes);
    var rdr = bitReader(fbs.reader());

    for (0..286) |c| {
        try testing.expectEqual(c, try rdr.readFixedCode());
    }
    try testing.expect(rdr.nbits == 0);
}
