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
            self.moreBits();
            return self;
        }

        pub inline fn read(self: *Self, comptime U: type) !U {
            const bit_count: u4 = @bitSizeOf(U);
            if (bit_count > self.eos) return error.EndOfStream;
            const v: U = @truncate(self.bits);
            self.advance(bit_count);
            return v;
        }

        pub inline fn readBits(self: *Self, n: u4) !u16 {
            if (n == 0) return 0;
            const mask: u16 = @as(u16, 0xffff) >> (15 - n + 1);
            const v: u16 = @as(u16, @truncate(self.bits)) & mask;
            self.advance(n);
            return v;
        }

        pub inline fn readLiteral(self: *Self, comptime U: type) !U {
            return @bitReverse(try self.read(U));
        }

        pub inline fn readU8(self: *Self) !u8 {
            // assert(self.eos >= 8);
            if (self.eos < 8) return error.EndOfStream;
            const v: u8 = @truncate(self.bits);
            // self.advanceBytes(1);
            self.advance(8);
            return v;
        }

        pub inline fn readU32(self: *Self) !u32 {
            assert(self.eos >= 32);
            const v: u32 = @truncate(self.bits);
            //self.advanceBytes(4);
            self.advance(32);
            return v;
        }

        pub inline fn readU16(self: *Self) !u16 {
            assert(self.eos >= 16);
            const v: u16 = @truncate(self.bits);
            //self.advanceBytes(2);
            self.advance(16);
            return v;
        }

        pub inline fn peek15(self: *Self) u16 {
            const v: u15 = @truncate(self.bits);
            return @bitReverse(v);
        }

        pub inline fn peek7(self: *Self) u16 {
            const v: u7 = @truncate(self.bits);
            return @bitReverse(v);
        }

        pub fn peek(self: *Self, comptime U: type) !U {
            const u_bit_count: u4 = @bitSizeOf(U);
            if (u_bit_count > self.eos) return error.EndOfStream;
            return @truncate(self.bits);
        }

        pub inline fn advance(self: *Self, n: u6) void {
            assert(n <= self.eos);

            self.bits >>= n;
            self.eos -= n;

            if (self.eos <= 32)
                self.moreBits(); // refill upper byte(s)
        }

        inline fn moreBits(self: *Self) void {
            var buf: [8]u8 = undefined;
            const empty_bytes = 7 - (self.eos >> 3); // 8 - (self.eos / 8)
            const bytes_read = self.rdr.read(buf[0..empty_bytes]) catch 0;
            for (0..bytes_read) |i| {
                self.bits |= @as(u64, buf[i]) << @as(u6, @intCast(self.eos));
                self.eos += 8;
            }
        }

        pub inline fn skipBytes(self: *Self, n: u3) void {
            for (0..n) |_| self.advance(8);
        }

        inline fn alignBits(self: *Self) u3 {
            return @intCast(self.eos % 8);
        }

        pub inline fn alignToByte(self: *Self) void {
            const ab = self.alignBits();
            if (ab > 0) self.advance(ab);
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
        try testing.expectEqual(@as(u8, c), try br.readLiteral(u8) - 0x30);
    }
    try testing.expectEqual(@as(u7, 0), try br.read(u7)); // end of block
    br.alignToByte();
    try testing.expectEqual(@as(u32, 0x0302010c), try br.readU32());
    try testing.expectEqual(@as(u16, 0xbbaa), try br.readU16());
    try testing.expectEqual(@as(u16, 0xddcc), try br.readU16());
}
