const std = @import("std");
const testing = std.testing;

const Symbol = struct {
    symbol: u16, // symbol from alphabet
    code: u16, // huffman code for the symbol
    code_bits: u4, // code bits count

    // for sort
    pub fn asc(_: void, a: Symbol, b: Symbol) bool {
        if (a.code_bits < b.code_bits)
            return true
        else if (a.code_bits > b.code_bits)
            return false
        else
            return a.symbol < b.symbol;
    }
};

/// Creates huffman tree codes from list of code lengths.
/// `next` reads from stream and returns decoded symbol.
pub fn Huffman(comptime alphabet_size: u16) type {
    const max_code_bits = if (alphabet_size == 19) 7 else 15;

    return struct {
        symbols: [alphabet_size]Symbol = undefined, // all symbols in alaphabet, sorted by code_len, symbol
        head: usize = 0, // location of first used symbol, with code_len > 0
        lookup: [2 << max_code_bits]u16 = undefined, // lookup table code -> symbol index

        const Self = @This();

        pub fn init(self: *Self, lens: []const u4) void {
            // init alphabet with code_lens
            for (&self.symbols, 0..) |*s, i| {
                s.code_bits = if (i < lens.len) lens[i] else 0;
                s.symbol = @intCast(i);
                // s.code = 0;
            }
            std.sort.heap(Symbol, &self.symbols, {}, Symbol.asc);

            // TODO: treba li mi ovaj head
            // find first symbol with code
            var head: usize = 0;
            for (self.symbols) |s| {
                if (s.code_bits != 0) break;
                head += 1;
            }
            // used symbols from alphabet
            self.head = head;
            const symbols = self.symbols[head..];

            // assign code to symbols
            // reference: https://youtu.be/9_YEGLe33NA?list=PLU4IQLU9e_OrY8oASHx0u3IXAL9TOdidm&t=2639
            var code: u16 = 0;
            for (symbols, 0..) |*sym, i| {
                const shift = max_code_bits - sym.code_bits;
                sym.code = code >> shift;

                const idx: u16 = @intCast(i);
                self.lookup[code] = idx;

                const prev = code;
                code += @as(u16, 1) << shift;
                for (prev..code) |j|
                    self.lookup[j] = idx;
            }
        }

        // Number of used symbols in alphabet.
        fn len(self: *Self) usize {
            return alphabet_size - self.head;
        }

        // Retruns symbol at index.
        inline fn at(self: *Self, idx: usize) Symbol {
            return self.symbols[idx + self.head];
        }

        pub inline fn find(self: *Self, code: u16) Symbol {
            return self.symbols[self.lookup[code] + self.head];
        }
    };
}

test "Huffman init/next" {
    // example data from: https://youtu.be/SJPvNi4HrWQ?t=8423
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    var h: Huffman(19) = .{};
    h.init(&code_lens);

    try testing.expectEqual(@as(usize, 7), h.len());
    try testing.expectEqual(Symbol{ .symbol = 3, .code = 0b00, .code_bits = 2 }, h.at(0));
    try testing.expectEqual(Symbol{ .symbol = 18, .code = 0b01, .code_bits = 2 }, h.at(1));
    try testing.expectEqual(Symbol{ .symbol = 1, .code = 0b100, .code_bits = 3 }, h.at(2));
    try testing.expectEqual(Symbol{ .symbol = 4, .code = 0b101, .code_bits = 3 }, h.at(3));
    try testing.expectEqual(Symbol{ .symbol = 17, .code = 0b110, .code_bits = 3 }, h.at(4));
    try testing.expectEqual(Symbol{ .symbol = 0, .code = 0b1110, .code_bits = 4 }, h.at(5));
    try testing.expectEqual(Symbol{ .symbol = 16, .code = 0b1111, .code_bits = 4 }, h.at(6));

    try testing.expectEqual(@as(u16, 3), h.find(0b0000).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0001).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0010).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0011).symbol);

    try testing.expectEqual(@as(u16, 18), h.find(0b0010_0000).symbol);
    try testing.expectEqual(@as(u16, 18), h.find(0b0010_0001).symbol);

    try testing.expectEqual(@as(u16, 1), h.find(0b0100_0000).symbol);
}

test "Huffman lookup" {
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    var h: Huffman(19) = .{};
    h.init(&code_lens);

    try testing.expectEqual(@as(u16, 3), h.find(0b0000_000).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0000_001).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0000_010).symbol);
    try testing.expectEqual(@as(u16, 3), h.find(0b0000_011).symbol);

    try testing.expectEqual(@as(u16, 18), h.find(0b0100_000).symbol);
    try testing.expectEqual(@as(u16, 18), h.find(0b0101_000).symbol);
    try testing.expectEqual(@as(u16, 18), h.find(0b0110_000).symbol);
    try testing.expectEqual(@as(u16, 18), h.find(0b0111_000).symbol);

    try testing.expectEqual(@as(u16, 1), h.find(0b1000_000).symbol);
    try testing.expectEqual(@as(u16, 1), h.find(0b1001_000).symbol);

    try testing.expectEqual(@as(u16, 4), h.find(0b1010_000).symbol);
    try testing.expectEqual(@as(u16, 4), h.find(0b1011_000).symbol);

    try testing.expectEqual(@as(u16, 17), h.find(0b1100_000).symbol);
    try testing.expectEqual(@as(u16, 17), h.find(0b1101_000).symbol);

    try testing.expectEqual(@as(u16, 0), h.find(0b1110_000).symbol);

    try testing.expectEqual(@as(u16, 16), h.find(0b1111_000).symbol);
}
