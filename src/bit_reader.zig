const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn bitReader(reader: anytype) BitReader(@TypeOf(reader)) {
    return BitReader(@TypeOf(reader)).init(reader);
}

pub fn BitReader(comptime ReaderType: type) type {
    return struct {
        rdr: ReaderType,
        bits: u32 = 0, // buffer of 32 bits
        eos: u8 = 0, // end of stream position
        align_bits: u3 = 0, // number of bits to skip to byte alignment

        const Self = @This();

        pub fn init(rdr: ReaderType) Self {
            var self = Self{ .rdr = rdr };
            for (0..4) |byte| {
                const b = self.rdr.readByte() catch break;
                self.bits += @as(u32, b) << @as(u5, @intCast(byte * 8));
                self.eos += 8;
            }
            return self;
        }

        pub fn read(self: *Self, comptime U: type) !U {
            const bit_count: u4 = @bitSizeOf(U);
            if (bit_count > self.eos) return error.EndOfStream;
            const v: U = @truncate(self.bits);
            self.advance(bit_count);
            return v;
        }

        pub fn readBit(self: *Self) anyerror!u1 {
            return try self.read(u1);
        }

        pub fn readBits(self: *Self, n: u4) !u16 {
            var mask: u16 = 0;
            for (0..n) |_| {
                mask = (mask << 1) + 1;
            }
            const v: u16 = @as(u16, @truncate(self.bits)) & mask;
            self.advance(n);
            return v;
        }

        pub inline fn readLiteral(self: *Self, comptime U: type) !U {
            return @bitReverse(try self.read(U));
        }

        pub fn readByte(self: *Self) !u8 {
            assert(self.align_bits == 0 and self.eos >= 8);
            const v: u8 = @truncate(self.bits);
            self.advanceBytes(1);
            return v;
        }

        pub fn readU32(self: *Self) !u32 {
            assert(self.align_bits == 0 and self.eos == 32);
            const v = self.bits;
            self.advanceBytes(4);
            return v;
        }

        pub fn readU16(self: *Self) !u16 {
            assert(self.align_bits == 0 and self.eos >= 16);
            const v: u16 = @truncate(self.bits);
            self.advanceBytes(2);
            return v;
        }

        pub fn skipBytes(self: *Self, n: usize) void {
            assert(self.align_bits == 0 and self.eos == 32);
            for (0..n) |_| {
                self.bits >>= 8;
                self.moreBits();
            }
        }

        pub fn peek15(self: *Self) u16 {
            const v: u15 = @truncate(self.bits);
            return @bitReverse(v);
        }

        pub fn peek7(self: *Self) u16 {
            const v: u7 = @truncate(self.bits);
            return @bitReverse(v);
        }

        pub fn peek(self: *Self, comptime U: type) !U {
            const u_bit_count: u4 = @bitSizeOf(U);
            if (u_bit_count > self.eos) return error.EndOfStream;
            return @truncate(self.bits);
        }

        pub fn advance(self: *Self, bit_count: u4) void {
            assert(bit_count <= self.eos);

            var bc: u4 = bit_count;
            while (bc > 0) {
                const ab: u4 = if (self.align_bits == 0) 8 else self.align_bits;
                const n: u4 = @min(bc, ab);

                //std.debug.print("n: {d}, bit_count: {d}\n", .{ n, bit_count });
                self.bits >>= n;
                self.eos -= n;
                if (n != 8)
                    self.align_bits -%= @intCast(n);

                if (self.eos == 24)
                    self.moreBits(); // refill upper byte

                bc -= n;
            }
        }

        inline fn advanceBytes(self: *Self, n: u3) void {
            for (0..n) |_| {
                self.bits >>= 8;
                self.eos -= 8;
                self.moreBits();
            }
        }

        pub fn alignToByte(self: *Self) void {
            self.advance(self.align_bits);
            self.align_bits = 0;
        }

        fn moreBits(self: *Self) void {
            // const b = self.rdr.readByte() catch return;
            // self.bits |= @as(u32, b) << 24;
            // self.eos = 32;

            var result: [1]u8 = undefined;
            const amt_read = self.rdr.read(result[0..]) catch 0;
            if (amt_read != 1) return;
            const b = result[0];
            self.bits |= @as(u32, b) << 24;
            self.eos = 32;
        }
    };
}

test "BitReader" {
    var fbs = std.io.fixedBufferStream(&[_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0x00, 0x00 });
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u8, 32), br.eos);
    try testing.expectEqual(@as(u32, 0xc9cd48f3), br.bits);

    try testing.expect(try br.read(u1) == 0b0000_0001);
    try testing.expect(try br.read(u2) == 0b0000_0001);
    try testing.expectEqual(@as(u8, 32 - 3), br.eos);
    try testing.expectEqual(@as(u3, 5), br.align_bits);

    try testing.expect(try br.peek(u8) == 0b0001_1110);
    try testing.expect(try br.peek(u9) == 0b1_0001_1110);
    br.advance(9);
    try testing.expectEqual(@as(u8, 28), br.eos);
    try testing.expectEqual(@as(u3, 4), br.align_bits);

    try testing.expect(try br.read(u4) == 0b0100);
    try testing.expectEqual(@as(u8, 32), br.eos);
    try testing.expectEqual(@as(u3, 0), br.align_bits);

    br.advance(1);
    try testing.expectEqual(@as(u3, 7), br.align_bits);
    br.advance(1);
    try testing.expectEqual(@as(u3, 6), br.align_bits);
    br.alignToByte();
    try testing.expectEqual(@as(u3, 0), br.align_bits);

    try testing.expectEqual(@as(u32, 0xc9), br.bits);
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
        try testing.expectEqual(@as(u8, c), try br.readLiteral(u8) - 0x30);
    }
    try testing.expectEqual(@as(u7, 0), try br.read(u7)); // end of block
    br.alignToByte();
    try testing.expectEqual(@as(u32, 0x0302010c), try br.readU32());
    try testing.expectEqual(@as(u16, 0xbbaa), try br.readU16());
    try testing.expectEqual(@as(u16, 0xddcc), try br.readU16());
}
