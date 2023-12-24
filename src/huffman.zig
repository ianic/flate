const std = @import("std");
const testing = std.testing;

/// Creates huffman tree codes from list of code lengths.
/// `next` reads from stream and returns decoded symbol.
pub fn Huffman(comptime alphabet_size: u16) type {
    return struct {
        const Symbol = struct {
            symbol: u16,
            code: u16,
            code_len: u4,

            pub fn asc(_: void, a: Symbol, b: Symbol) bool {
                if (a.code_len == b.code_len) {
                    return a.symbol < b.symbol;
                }
                return a.code_len < b.code_len;
            }
        };

        symbols: [alphabet_size]Symbol, // all symbols in alaphabet, sorted by code_len, symbol
        head: usize, // location of first used symbol, with code_len > 0

        const Self = @This();

        pub fn init(lens: []const u4) Self {
            var self = Self{ .symbols = undefined, .head = 0 };
            // init alphabet with code_lens
            for (&self.symbols, 0..) |*s, i| {
                s.code_len = if (i < lens.len) lens[i] else 0;
                s.symbol = @intCast(i);
                s.code = 0;
            }
            std.sort.insertion(Symbol, &self.symbols, {}, Symbol.asc);

            // find first symbol with code
            var head: usize = 0;
            for (self.symbols) |s| {
                if (s.code_len != 0) break;
                head += 1;
            }
            // used symbols from alphabet
            self.head = head;
            const symbols = self.symbols[head..];

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

        // Number of used symbols in alphabet.
        fn len(self: Self) usize {
            return alphabet_size - self.head;
        }

        // Retruns symbol at index.
        fn at(self: Self, idx: usize) Symbol {
            return self.symbols[idx + self.head];
        }

        // Finds next symbol in stream presented by readBit fn.
        pub fn next(
            self: Self,
            context: anytype,
            comptime readBit: fn (@TypeOf(context)) anyerror!u1,
        ) !u16 {
            const min = self.at(0).code_len;

            // read first min code_len bytes
            var code: u16 = 0;
            for (0..min) |_| {
                code = code << 1;
                code += try readBit(context);
            }

            var code_len: u16 = min;
            var i: usize = 0;
            while (i < self.len()) : (code_len += 1) {
                while (true) { // check symbols with code_len
                    const sym = self.at(i);
                    if (sym.code_len != code_len) break;
                    if (sym.code == code) return sym.symbol;
                    i += 1;
                }
                // read 1 more bit
                code = code << 1;
                code += try readBit(context);
            }
            return error.CodeNotFound;
        }
    };
}

test "Huffman init/next" {
    // example data from: https://youtu.be/SJPvNi4HrWQ?t=8423
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

    const data = [2]u8{
        0b11_11_0111, 0b10_001_011,
    };

    var fbs = std.io.fixedBufferStream(&data);
    var rdr = std.io.bitReader(.little, fbs.reader());
    const readBit = struct {
        pub fn readBit(br: *std.io.BitReader(.little, std.io.FixedBufferStream([]const u8).Reader)) anyerror!u1 {
            return try br.readBitsNoEof(u1, 1);
        }
    }.readBit;

    try testing.expectEqual(@as(u16, 0), try h.next(&rdr, readBit));
    try testing.expectEqual(@as(u16, 16), try h.next(&rdr, readBit));
    try testing.expectEqual(@as(u16, 17), try h.next(&rdr, readBit));
    try testing.expectEqual(@as(u16, 1), try h.next(&rdr, readBit));
    try testing.expectEqual(@as(u16, 18), try h.next(&rdr, readBit));
    try testing.expectError(error.EndOfStream, h.next(&rdr, readBit));
}
