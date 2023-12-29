const std = @import("std");
const testing = std.testing;

const Symbol = struct {
    symbol: u16, // symbol from alphabet
    code_bits: u4, // code bits count

    // Sorting less than function.
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
pub fn Huffman(comptime alphabet_size: u16) type {
    const max_code_bits = if (alphabet_size == 19) 7 else 15;
    const small_lookup_bits = switch (alphabet_size) {
        286 => 9,
        30 => 9,
        19 => 0,
        else => unreachable,
    };
    const small_lookup_shift = max_code_bits - small_lookup_bits;
    const lookup_not_found = 0xffff;

    return struct {
        // all symbols in alaphabet, sorted by code_len, symbol
        symbols: [alphabet_size]Symbol = undefined,
        // lookup table code -> symbol index
        lookup: [2 << max_code_bits]u16 = undefined,
        // small lookup table
        lookup_s: [2 << small_lookup_bits]u16 = undefined,

        const Self = @This();

        /// Builds symbols and lookup tables from list of code lens for each symbol.
        pub fn build(self: *Self, lens: []const u4) void {
            // init alphabet with code_bits
            for (&self.symbols, 0..) |*s, i| {
                s.code_bits = if (i < lens.len) lens[i] else 0;
                s.symbol = @intCast(i);
            }
            std.sort.heap(Symbol, &self.symbols, {}, Symbol.asc);

            // assign code to symbols
            // reference: https://youtu.be/9_YEGLe33NA?list=PLU4IQLU9e_OrY8oASHx0u3IXAL9TOdidm&t=2639
            var code: u16 = 0;
            var code_s: u16 = 0;
            for (self.symbols, 0..) |sym, i| {
                if (sym.code_bits == 0) continue; // skip unused

                const next = code + (@as(u16, 1) << (max_code_bits - sym.code_bits));

                if (sym.code_bits <= small_lookup_bits) {
                    const next_s = next >> small_lookup_shift;
                    for (code_s..next_s) |j|
                        self.lookup_s[j] = @intCast(i);
                    code_s = next_s;
                } else {
                    // assign symbol index to all codes between current and next code
                    for (code..next) |j|
                        self.lookup[j] = @intCast(i);
                }
                code = next;
            }
            for (code_s..self.lookup_s.len) |i|
                self.lookup_s[i] = lookup_not_found;
        }

        /// Finds symbol for lookup table code.
        pub inline fn find(self: *Self, code: u16) Symbol {
            if (small_lookup_bits > 0) {
                const code_s = code >> small_lookup_shift;
                const idx = self.lookup_s[code_s];
                if (idx != lookup_not_found) return self.symbols[idx];
            }
            return self.symbols[self.lookup[code]];
        }
    };
}

test "Huffman init/find" {
    // example data from: https://youtu.be/SJPvNi4HrWQ?t=8423
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    var h: Huffman(19) = .{};
    h.build(&code_lens);

    // unused symbols
    for (0..12) |i| {
        try testing.expectEqual(@as(u16, 0), h.symbols[i].code_bits);
    }

    const data = [_]struct {
        sym: Symbol,
        code: u16,
    }{
        .{
            .code = 0b0000_000,
            .sym = .{ .symbol = 3, .code_bits = 2 },
        },
        .{
            .code = 0b0100_000,
            .sym = .{ .symbol = 18, .code_bits = 2 },
        },
        .{
            .code = 0b100_0000,
            .sym = .{ .symbol = 1, .code_bits = 3 },
        },
        .{
            .code = 0b1010_000,
            .sym = .{ .symbol = 4, .code_bits = 3 },
        },
        .{
            .code = 0b1100_000,
            .sym = .{ .symbol = 17, .code_bits = 3 },
        },
        .{
            .code = 0b1110_000,
            .sym = .{ .symbol = 0, .code_bits = 3 },
        },
        .{
            .code = 0b1111_000,
            .sym = .{ .symbol = 16, .code_bits = 3 },
        },
    };

    for (data, 12..) |d, i| {
        try testing.expectEqual(d.sym.symbol, h.symbols[i].symbol);
        const sym_from_code = h.find(d.code);
        try testing.expectEqual(d.sym.symbol, sym_from_code.symbol);
    }

    // All possible codes for each symbol.
    // Lookup table has 126 elements, to cover all possible 7 bit codes.
    for (0b0000_000..0b0100_000) |c| // 0..32 (32)
        try testing.expectEqual(@as(u16, 3), h.find(@intCast(c)).symbol);

    for (0b0100_000..0b1000_000) |c| // 32..64 (32)
        try testing.expectEqual(@as(u16, 18), h.find(@intCast(c)).symbol);

    for (0b1000_000..0b1010_000) |c| // 64..80 (16)
        try testing.expectEqual(@as(u16, 1), h.find(@intCast(c)).symbol);

    for (0b1010_000..0b1100_000) |c| // 80..96 (16)
        try testing.expectEqual(@as(u16, 4), h.find(@intCast(c)).symbol);

    for (0b1100_000..0b1110_000) |c| // 96..112 (16)
        try testing.expectEqual(@as(u16, 17), h.find(@intCast(c)).symbol);

    for (0b1110_000..0b1111_000) |c| // 112..120 (8)
        try testing.expectEqual(@as(u16, 0), h.find(@intCast(c)).symbol);

    for (0b1111_000..0b1_0000_000) |c| // 120...128 (8)
        try testing.expectEqual(@as(u16, 16), h.find(@intCast(c)).symbol);
}
