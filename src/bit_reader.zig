const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn bitReader(reader: anytype) BitReader(@TypeOf(reader)) {
    return BitReader(@TypeOf(reader)).init(reader);
}

pub fn BitReader(comptime ReaderType: type) type {
    return struct {
        rdr: ReaderType,
        bits: u64 = 0, // buffer of 64 bits
        eos: u8 = 0, // end of stream position

        const Self = @This();

        pub fn init(rdr: ReaderType) Self {
            var self = Self{ .rdr = rdr };
            self.ensureBits(1, 0) catch {};
            return self;
        }

        // Ensure that n bits are available in buffer.
        // Reads from underlaying reader if more bits are needed.
        // Returns error if not enough bits found.
        pub inline fn ensureBits(self: *Self, nice: u6, must: u6) !void {
            if (nice > self.eos) {
                // read more bits from underlaying reader
                var buf: [8]u8 = [_]u8{0} ** 8;

                const empty_bytes =
                    @as(u8, if (self.eos & 0x7 == 0) 8 else 7) - // 8 for 8, 16, 24..., 7 otherwise
                    (self.eos >> 3); // 0 for 0-7, 1 for 8-16, ... same as / 8

                const bytes_read = self.rdr.read(buf[0..empty_bytes]) catch 0;
                if (bytes_read > 0) {
                    const u: u64 = std.mem.readInt(u64, buf[0..8], .little);
                    self.bits |= u << @as(u6, @intCast(self.eos));
                    self.eos += 8 * @as(u8, @intCast(bytes_read));
                }
                // than check again
                if (must > self.eos) return error.EndOfStream;
            }
        }

        // Read exactly buf.len bytes into buf.
        pub fn readAll(self: *Self, buf: []u8) !void {
            assert(self.alignBits() == 0);

            var n: usize = 0;
            while (self.eos > 0 and n < buf.len) {
                buf[n] = self.readBuffered(u8);
                n += 1;
            }
            try self.rdr.readNoEof(buf[n..]);
        }

        // Read bit size of U number of bits and advance stream.
        pub inline fn read(self: *Self, comptime U: type) !U {
            const n: u6 = @bitSizeOf(U);
            try self.ensureBits(n, n);
            const u: U = @truncate(self.bits);
            self.advance(n);
            return u;
        }

        // Read assuming that bit size of U number of bits are availabel in bits buffer.
        pub inline fn readBuffered(self: *Self, comptime U: type) U {
            const n: u6 = @bitSizeOf(U);
            const u: U = @truncate(self.bits);
            self.advance(n);
            return u;
        }

        // Huffman codes are packed starting with the most-significant bit of the code.
        pub inline fn readCode(self: *Self, comptime U: type) !U {
            return @bitReverse(try self.read(U));
        }

        pub inline fn readBufferedCode(self: *Self, comptime U: type) U {
            return @bitReverse(self.readBuffered(U));
        }

        // Read n number of bits.
        pub inline fn readBits(self: *Self, n: u4) !u16 {
            try self.ensureBits(n, n);
            const mask: u16 = (@as(u16, 1) << n) - 1;
            const u: u16 = @as(u16, @truncate(self.bits)) & mask;
            self.advance(n);
            return u;
        }

        pub inline fn readBufferedBits(self: *Self, n: u4) u16 {
            const mask: u16 = (@as(u16, 1) << n) - 1;
            const u: u16 = @as(u16, @truncate(self.bits)) & mask;
            self.advance(n);
            return u;
        }

        // Get bits from buffer, don't advance buffer.
        pub inline fn peek(self: *Self, comptime U: type) !U {
            const n: u4 = @bitSizeOf(U);
            try self.ensureBits(n, n);
            return @truncate(self.bits);
        }

        pub inline fn peekBuffered(self: *Self, comptime U: type) U {
            return @truncate(self.bits);
        }

        pub inline fn peekCode(self: *Self, comptime U: type) !U {
            return @bitReverse(try self.peek(U));
        }

        pub inline fn peekBufferedCode(self: *Self, comptime U: type) U {
            return @bitReverse(@as(U, @truncate(self.bits)));
        }

        pub inline fn advance(self: *Self, n: u6) void {
            assert(n <= self.eos);
            self.bits >>= n;
            self.eos -= n;
        }

        pub inline fn skipBytes(self: *Self, n: u16) !void {
            for (0..n) |_| {
                try self.ensureBits(8, 8);
                self.advance(8);
            }
        }

        // Number of bits to align stream to the byte boundary.
        inline fn alignBits(self: *Self) u3 {
            return @intCast(self.eos & 0x7);
        }

        // Align stream to the byte boundary.
        pub inline fn alignToByte(self: *Self) void {
            const ab = self.alignBits();
            if (ab > 0) self.advance(ab);
        }

        // Skip zero terminated string.
        pub fn skipStringZ(self: *Self) !void {
            while (true) {
                if (try self.read(u8) == 0) break;
            }
        }
    };
}

test "BitReader" {
    var fbs = std.io.fixedBufferStream(&[_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0x00, 0x00 });
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u8, 48), br.eos);
    try testing.expectEqual(@as(u64, 0xc9cd48f3), br.bits);

    try testing.expect(try br.read(u1) == 0b0000_0001);
    try testing.expect(try br.read(u2) == 0b0000_0001);
    try testing.expectEqual(@as(u8, 48 - 3), br.eos);
    try testing.expectEqual(@as(u3, 5), br.alignBits());

    try testing.expect(try br.peek(u8) == 0b0001_1110);
    try testing.expect(try br.peek(u9) == 0b1_0001_1110);
    br.advance(9);
    try testing.expectEqual(@as(u8, 36), br.eos);
    try testing.expectEqual(@as(u3, 4), br.alignBits());

    try testing.expect(try br.read(u4) == 0b0100);
    try testing.expectEqual(@as(u8, 32), br.eos);
    try testing.expectEqual(@as(u3, 0), br.alignBits());

    br.advance(1);
    try testing.expectEqual(@as(u3, 7), br.alignBits());
    br.advance(1);
    try testing.expectEqual(@as(u3, 6), br.alignBits());
    br.alignToByte();
    try testing.expectEqual(@as(u3, 0), br.alignBits());

    try testing.expectEqual(@as(u64, 0xc9), br.bits);
    try testing.expectEqual(@as(u16, 0x9), try br.readBits(4));
    try testing.expectEqual(@as(u16, 0xc), try br.readBits(4));
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

    try testing.expectEqual(@as(u1, 1), try br.read(u1)); // bfinal
    try testing.expectEqual(@as(u2, 1), try br.read(u2)); // block_type

    for ("Hello world\n") |c| {
        try testing.expectEqual(@as(u8, c), try br.readCode(u8) - 0x30);
    }
    try testing.expectEqual(@as(u7, 0), try br.read(u7)); // end of block
    br.alignToByte();
    try testing.expectEqual(@as(u32, 0x0302010c), try br.read(u32));
    try testing.expectEqual(@as(u16, 0xbbaa), try br.read(u16));
    try testing.expectEqual(@as(u16, 0xddcc), try br.read(u16));
}

test "BitReader init" {
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    };
    var fbs = std.io.fixedBufferStream(&data);
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u64, 0x08_07_06_05_04_03_02_01), br.bits);
    br.advance(8);
    try testing.expectEqual(@as(u64, 0x00_08_07_06_05_04_03_02), br.bits);
    try br.ensureBits(60, 0); // fill with 1 byte
    try testing.expectEqual(@as(u64, 0x01_08_07_06_05_04_03_02), br.bits);
    br.advance(8 * 4 + 4);
    try testing.expectEqual(@as(u64, 0x00_00_00_00_00_10_80_70), br.bits);

    try br.ensureBits(60, 0); // fill with 4 bytes (shift by 4)
    try testing.expectEqual(@as(u64, 0x00_50_40_30_20_10_80_70), br.bits);
    try testing.expectEqual(@as(u8, 8 * 7 + 4), br.eos);

    br.advance(@intCast(br.eos)); // clear buffer
    try br.ensureBits(8, 8); // refill with the rest of the bytes
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
    try testing.expect(br.eos == 0);
    try testing.expect(br.bits == 0);

    try testing.expectEqualSlices(u8, data[0..16], &out);
}
