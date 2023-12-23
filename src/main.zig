const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

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
    var gs = gzStat(stdin.reader());
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

fn gzStat(reader: anytype) GzStat(@TypeOf(reader)) {
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
                    1 => try self.fixedCodesBlock(),
                    2 => try self.dynamicCodesBlock(),
                    else => unreachable,
                }
                if (bfinal == 1) break;
            }
        }

        fn fixedCodesBlock(self: *Self) !void {
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

        fn dynamicCodesBlock(self: *Self) !void {
            // number of ll code entries present - 257
            const hlit = try self.readBits(u16, 5) + 257;
            // nuber of distance code entries - 1
            const hdist = try self.readBits(u8, 5) + 1;
            // hclen + 4 code lenths are encoded
            const hclen = try self.readBits(u8, 4) + 4;
            std.debug.print("hlit: {d}, hdist: {d}, hclen: {d}\n", .{ hlit, hdist, hclen });

            var cl = [_]u8{0} ** 19;
            const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            var i: u8 = 0;
            while (i < hclen) : (i += 1) {
                const len = try self.readBits(u3, 3);
                cl[order[i]] = len;
                std.debug.print("len {b}\n", .{len});
            }
            std.debug.print("cl {d}\n", .{cl});

            return error.NotImplemented;
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

test "block2 example" {
    // zig fmt: off
    const data = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02, 0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38, 0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
        0x17, 0x1c, 0x39, 0xb4, 0x13, 0x00, 0x00, 0x00,
    };
    // zig fmt: on

    var fbs = std.io.fixedBufferStream(&data);
    var gs = gzStat(fbs.reader());
    try gs.parse();
}

// block header type 2 image:
// https://youtu.be/SJPvNi4HrWQ?list=PLU4IQLU9e_OrY8oASHx0u3IXAL9TOdidm&t=7413

test "length to codes" {
    var cl = [_]u8{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    std.sort.insertion(u8, &cl, {}, std.sort.asc(u8));
    var s: usize = 0;
    for (cl) |v| {
        if (v != 0) break;
        s += 1;
    }
    std.debug.print("cl {d}", .{cl[s..]});
    assign(cl[s..]);
}

fn assign(l: []const u8) void {
    const n = l.len;
    const h: u16 = l[n - 1];
    var b: u16 = 0;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const li = l[i];
        const s: u4 = @as(u4, @intCast((h - li)));
        const p = b >> s;
        std.debug.print("{b} {d} {b}\n", .{ b, li, p });
        b += @as(u16, 1) << s;
    }
}

pub fn Huffman(comptime alphabet_size: u16) type {
    return struct {
        const Symbol = struct {
            symbol: u8,
            code: u16,
            code_len: u4,

            pub fn asc(_: void, a: Symbol, b: Symbol) bool {
                if (a.code_len == b.code_len) {
                    return a.symbol < b.symbol;
                }
                return a.code_len < b.code_len;
            }
        };

        alphabet: [alphabet_size]Symbol, // all symbols in alaphabet
        head: usize, // location of first used symbol, with code_len > 0

        const Self = @This();

        pub fn init(code_lens: []const u4) Self {
            var self = Self{ .alphabet = undefined, .head = 0 };
            // init alphabet with code_lens
            for (&self.alphabet, 0..) |*s, i| {
                s.code_len = if (i < code_lens.len) code_lens[i] else 0;
                s.symbol = @as(u8, @intCast(i));
                s.code = 0;
            }
            std.sort.insertion(Symbol, &self.alphabet, {}, Symbol.asc);

            // find first symbol with code
            var head: usize = 0;
            for (self.alphabet) |s| {
                if (s.code_len != 0) break;
                head += 1;
            }
            // used symbols from alphabet
            self.head = head;
            const symbols = self.alphabet[head..];

            // assign code to symbols
            // reference: https://youtu.be/9_YEGLe33NA?list=PLU4IQLU9e_OrY8oASHx0u3IXAL9TOdidm&t=2639
            const max_len = symbols[symbols.len - 1].code_len;
            var code: u16 = 0;
            for (symbols) |*sym| {
                const shift = max_len - sym.code_len;
                sym.code = code >> shift;
                code += @as(u16, 1) << shift;
            }

            return self;
        }

        fn len(self: Self) usize {
            return alphabet_size - self.head;
        }

        fn at(self: Self, idx: usize) Symbol {
            return self.alphabet[idx + self.head];
        }

        pub fn lookup(
            self: *Self,
            context: anytype,
            comptime readBit: fn (@TypeOf(context)) u16,
        ) !u8 {
            const min = self.at(0).code_len;
            const max = self.at(self.len() - 1).code_len;

            var code: u16 = 0;
            var code_len: u16 = 0;
            var i: usize = 0;
            while (code_len <= max) : (code_len += 1) {
                if (code_len >= min) {
                    while (true) {
                        const sym = &self.at(i);
                        //std.debug.print("compare: {b} {d} {} {d}\n", .{ code, code_len, sym, i });
                        if (sym.code_len != code_len) break;
                        if (sym.code == code) {
                            // std.debug.print("return: {b} {d} {} {d}\n", .{ code, code_len, sym, i });
                            return sym.symbol;
                        }
                        i += 1;
                    }
                }

                code = code << 1;
                code += readBit(context);
            }
            return error.CodeNotFound;
        }
    };
}

const EOS = error.EndOfStream;

test "Huffman init" {
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    const H = Huffman(19);
    var h = H.init(&code_lens);

    try testing.expectEqual(@as(usize, 7), h.len());
    try testing.expectEqual(H.Symbol{ .symbol = 3, .code = 0b00, .code_len = 2 }, h.at(0));
    try testing.expectEqual(H.Symbol{ .symbol = 18, .code = 0b01, .code_len = 2 }, h.at(1));
    try testing.expectEqual(H.Symbol{ .symbol = 1, .code = 0b100, .code_len = 3 }, h.at(2));
    try testing.expectEqual(H.Symbol{ .symbol = 4, .code = 0b101, .code_len = 3 }, h.at(3));
    try testing.expectEqual(H.Symbol{ .symbol = 17, .code = 0b110, .code_len = 3 }, h.at(4));
    try testing.expectEqual(H.Symbol{ .symbol = 0, .code = 0b1110, .code_len = 4 }, h.at(5));
    try testing.expectEqual(H.Symbol{ .symbol = 16, .code = 0b1111, .code_len = 4 }, h.at(6));

    // for (h.symbols) |s| {
    //     std.debug.print("{}\n", .{s});
    // }

    const data = [2]u8{
        0b11_11_0111, 0b10_001_011,
    };

    var fbs = std.io.fixedBufferStream(&data);
    var rdr = std.io.bitReader(.little, fbs.reader());

    const s = struct {
        pub fn inner(br: *std.io.BitReader(.little, std.io.FixedBufferStream([]const u8).Reader)) u16 {
            const u = br.readBitsNoEof(u1, 1) catch unreachable;
            return u;
        }
    };

    try testing.expectEqual(@as(u8, 0), try h.lookup(&rdr, s.inner));
    try testing.expectEqual(@as(u8, 16), try h.lookup(&rdr, s.inner));
    try testing.expectEqual(@as(u8, 17), try h.lookup(&rdr, s.inner));
    try testing.expectEqual(@as(u8, 1), try h.lookup(&rdr, s.inner));

    try testing.expectEqual(@as(u8, 18), try h.lookup(&rdr, s.inner));
    // try testing.expectError(error.EndOfStream, h.lookup(&rdr, s.inner));
}
