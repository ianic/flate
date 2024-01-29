const std = @import("std");
const testing = std.testing;

pub const Symbol = packed struct {
    pub const Kind = enum(u2) {
        literal,
        end_of_block,
        backreference,
    };

    symbol: u8, // symbol from alphabet
    code_bits: u4, // code bits count
    kind: Kind,

    // Sorting less than function.
    pub fn asc(_: void, a: Symbol, b: Symbol) bool {
        if (a.code_bits == b.code_bits) {
            if (a.kind == b.kind) {
                return a.symbol < b.symbol;
            }
            return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        }
        return a.code_bits < b.code_bits;
    }
};

pub const LiteralDecoder = HuffmanDecoder(286, 15, 9);
pub const OffsetDecoder = HuffmanDecoder(30, 15, 9);
pub const CodegenDecoder = HuffmanDecoder(19, 7, 0);

/// Creates huffman tree codes from list of code lengths.
fn HuffmanDecoder(
    comptime alphabet_size: u16,
    comptime max_code_bits: u4,
    comptime small_lookup_bits: u4,
) type {
    const small_lookup_shift = max_code_bits - small_lookup_bits;

    return struct {
        // all symbols in alaphabet, sorted by code_len, symbol
        symbols: [alphabet_size]Symbol = undefined,
        // lookup table code -> symbol
        lookup: [1 << max_code_bits]Symbol = undefined,
        // small lookup table
        lookup_s: [1 << small_lookup_bits]Symbol = undefined,

        const Self = @This();

        /// Builds symbols and lookup tables from list of code lens for each symbol.
        pub fn build(self: *Self, lens: []const u4) void {
            // init alphabet with code_bits
            for (self.symbols, 0..) |_, i| {
                const cb: u4 = if (i < lens.len) lens[i] else 0;
                self.symbols[i] = if (i < 256)
                    .{ .kind = .literal, .symbol = @intCast(i), .code_bits = cb }
                else if (i == 256)
                    .{ .kind = .end_of_block, .symbol = 0xff, .code_bits = cb }
                else
                    .{ .kind = .backreference, .symbol = @intCast(i - 257), .code_bits = cb };
            }
            std.sort.heap(Symbol, &self.symbols, {}, Symbol.asc);

            // assign code to symbols
            // reference: https://youtu.be/9_YEGLe33NA?list=PLU4IQLU9e_OrY8oASHx0u3IXAL9TOdidm&t=2639
            var code: u16 = 0;
            var code_s: u16 = 0;
            for (self.symbols) |sym| {
                if (sym.code_bits == 0) continue; // skip unused

                const next = code + (@as(u16, 1) << (max_code_bits - sym.code_bits));

                if (sym.code_bits <= small_lookup_bits) {
                    // fill small lookup table
                    const next_s = next >> small_lookup_shift;
                    for (code_s..next_s) |j|
                        self.lookup_s[j] = sym;
                    code_s = next_s;
                } else {
                    // fill lookup table
                    // assign symbol to all codes between current and next code
                    for (code..next) |j|
                        self.lookup[j] = sym;
                }
                code = next;
            }
            for (code_s..self.lookup_s.len) |i|
                self.lookup_s[i].code_bits = 0; // unused
        }

        /// Finds symbol for lookup table code.
        pub inline fn find(self: *Self, code: u16) Symbol {
            if (small_lookup_bits > 0) {
                const code_s = code >> small_lookup_shift;
                const sym = self.lookup_s[code_s];
                if (sym.code_bits != 0) return sym;
            }
            return self.lookup[code];
        }
    };
}

test "Huffman init/find" {
    // example data from: https://youtu.be/SJPvNi4HrWQ?t=8423
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    var h: CodegenDecoder = .{};
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
            .sym = .{ .symbol = 3, .code_bits = 2, .kind = .literal },
        },
        .{
            .code = 0b0100_000,
            .sym = .{ .symbol = 18, .code_bits = 2, .kind = .literal },
        },
        .{
            .code = 0b100_0000,
            .sym = .{ .symbol = 1, .code_bits = 3, .kind = .literal },
        },
        .{
            .code = 0b1010_000,
            .sym = .{ .symbol = 4, .code_bits = 3, .kind = .literal },
        },
        .{
            .code = 0b1100_000,
            .sym = .{ .symbol = 17, .code_bits = 3, .kind = .literal },
        },
        .{
            .code = 0b1110_000,
            .sym = .{ .symbol = 0, .code_bits = 3, .kind = .literal },
        },
        .{
            .code = 0b1111_000,
            .sym = .{ .symbol = 16, .code_bits = 3, .kind = .literal },
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
