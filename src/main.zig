const std = @import("std");
const assert = std.debug.assert;

// zig fmt: off
    const dataBlockType01 = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7,
        0x0c, 0x00, 0x00, 0x00,
    };
    const dataBlockType00 = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff,
        'H', 'e', 'l',  'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a,
        0xd5, 0xe0, 0x39, 0xb7,
        0x0c, 0x00, 0x00, 0x00,
    };
// zig fmt: on

pub fn main() !void {
    // var fbs = std.io.fixedBufferStream(&dataBlockType01);
    // try gzStat(fbs.reader());

    const stdin = std.io.getStdIn();
    var gs = gzStatInit(stdin.reader());
    try gs.parse();
    //try helloWorldBlockType01();
    //try helloWorldBlockType00();
}

fn helloWorldBlockType01() !void {
    const stdout_file = std.io.getStdOut().writer();
    try stdout_file.writeAll(&dataBlockType01);
}

fn helloWorldBlockType00() !void {
    const stdout_file = std.io.getStdOut().writer();
    try stdout_file.writeAll(&dataBlockType00);
}

fn gzStatInit(reader: anytype) GzStat(@TypeOf(reader)) {
    return GzStat(@TypeOf(reader)).init(reader);
}

fn GzStat(comptime ReaderType: type) type {
    const BitReaderType = std.io.BitReader(.little, ReaderType);
    return struct {
        br: BitReaderType,

        const Self = @This();

        pub fn init(br: ReaderType) Self {
            return .{
                .br = BitReaderType.init(br),
            };
        }

        fn readByte(self: *Self) !u8 {
            return self.br.readBitsNoEof(u8, 8);
        }

        fn skipBytes(self: *Self, n: usize) !void {
            var i = n;
            while (i > 0) : (i -= 1) {
                _ = try self.readByte();
            }
        }

        fn gzipHeader(self: *Self) !void {
            const magic1 = try self.readByte();
            const magic2 = try self.readByte();
            const method = try self.readByte();
            try self.skipBytes(7); // flags, mtime(4), xflags, os
            if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08)
                return error.InvalidGzipHeader;
        }

        inline fn readBits(self: *Self, comptime U: type, bits: usize) !U {
            return try self.br.readBitsNoEof(U, bits);
        }

        inline fn readLiteralBits(self: *Self, comptime U: type, bits: usize) !U {
            return @bitReverse(try self.br.readBitsNoEof(U, bits));
        }

        inline fn readLength(self: *Self, code: u16) !u16 {
            assert(code >= 256 and code <= 285);
            const idx: usize = code - 256 - 1;
            const l = lengths[idx];
            assert(l.code == code);
            return if (l.extra_bits > 0)
                l.base_length + try self.readBits(u16, l.extra_bits)
            else
                l.base_length;
        }

        inline fn readDistance(self: *Self) !u16 {
            const code = try self.readBits(u5, 5);
            assert(code <= 29);
            const d = distances[code];
            assert(d.code == code);
            return if (d.extra_bits > 0)
                d.base_distance + try self.readBits(u16, d.extra_bits)
            else
                d.base_distance;
        }

        pub fn parse(self: *Self) !void {
            try self.gzipHeader();

            while (true) {
                const bfinal = try self.readBits(u1, 1);
                const block_type = try self.readBits(u2, 2);
                switch (block_type) {
                    0 => unreachable,
                    1 => try self.block01(),
                    else => unreachable,
                }
                if (bfinal == 1) break;
            }
        }

        fn block01(self: *Self) !void {
            while (true) {
                const code7 = try self.readLiteralBits(u7, 7);
                std.debug.print("\ncode7: {b:0<7}", .{code7});

                if (code7 < 0b0010_111) { // 7 bits, 256-279, codes 0000_000 - 0010_111
                    if (code7 == 0) break; // end of block code 256
                    const code: u16 = @as(u16, code7) + 256;
                    try self.printLengthDistance(code);
                } else if (code7 < 0b1011_111) { // 8 bits, 0-143, codes 0011_0000 through 1011_1111
                    const lit: u8 = (@as(u8, code7 - 0b0011_000) << 1) + try self.readBits(u1, 1);
                    printLiteral(lit);
                } else if (code7 <= 0b1100_011) { // 8 bit, 280-287, codes 1100_0000 - 1100_0111
                    const code: u16 = (@as(u16, code7 - 0b1100011) << 1) + try self.readBits(u1, 1) + 280;
                    try self.printLengthDistance(code);
                } else { // 9 bit, 144-255, codes 1_1001_0000 - 1_1111_1111
                    const lit: u8 = (@as(u8, code7 - 0b1100_100) << 2) + try self.readLiteralBits(u2, 2) + 144;
                    printLiteral(lit);
                }
            }
        }

        fn printLengthDistance(self: *Self, code: u16) !void {
            const length = try self.readLength(code);
            const distance = try self.readDistance();

            std.debug.print(" code: {d}, length: {d}", .{ code, length });
            std.debug.print(" distance: {d}", .{distance});
        }
    };
}

fn printLiteral(lit: u8) void {
    // if (code >= 144) {
    //     std.debug.print(" code: {b:0>9}", .{code});
    // } else {
    //     std.debug.print(" code: {b:0>8} ", .{code});
    // }
    std.debug.print(" literal: 0x{x}", .{lit});
    if (std.ascii.isPrint(lit)) {
        std.debug.print(" {c}", .{lit});
    }
}

const lengths = [_]struct {
    code: u16,
    extra_bits: u8,
    base_length: u16,
}{
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

const distances = [_]struct {
    code: u8,
    extra_bits: u8,
    base_distance: u16,
}{
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
};
