const std = @import("std");
const io = std.io;

const deflate_const = @import("deflate_const.zig");
const hm_code = @import("huffman_code.zig");
const token = @import("token.zig");

// The first length code.
const length_codes_start = 257;

// The number of codegen codes.
const codegen_code_count = 19;
const bad_code = 255;

// buffer_flush_size indicates the buffer size
// after which bytes are flushed to the writer.
// Should preferably be a multiple of 6, since
// we accumulate 6 bytes between writes to the buffer.
const buffer_flush_size = 240;

// buffer_size is the actual output byte buffer size.
// It must have additional headroom for a flush
// which can contain up to 8 bytes.
const buffer_size = buffer_flush_size + 8;

// The number of extra bits needed by length code X - LENGTH_CODES_START.
var length_extra_bits = [_]u8{
    0, 0, 0, // 257
    0, 0, 0, 0, 0, 1, 1, 1, 1, 2, // 260
    2, 2, 2, 3, 3, 3, 3, 4, 4, 4, // 270
    4, 5, 5, 5, 5, 0, // 280
};

// The length indicated by length code X - LENGTH_CODES_START.
var length_base = [_]u32{
    0,  1,  2,  3,   4,   5,   6,   7,   8,   10,
    12, 14, 16, 20,  24,  28,  32,  40,  48,  56,
    64, 80, 96, 112, 128, 160, 192, 224, 255,
};

// offset code word extra bits.
var offset_extra_bits = [_]i8{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
    4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

var offset_base = [_]u32{
    0x000000, 0x000001, 0x000002, 0x000003, 0x000004,
    0x000006, 0x000008, 0x00000c, 0x000010, 0x000018,
    0x000020, 0x000030, 0x000040, 0x000060, 0x000080,
    0x0000c0, 0x000100, 0x000180, 0x000200, 0x000300,
    0x000400, 0x000600, 0x000800, 0x000c00, 0x001000,
    0x001800, 0x002000, 0x003000, 0x004000, 0x006000,
};

// The odd order in which the codegen code sizes are written.
var codegen_order = [_]u32{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

pub fn HuffmanBitWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        pub const Error = WriterType.Error;

        // writer is the underlying writer.
        // Do not use it directly; use the write method, which ensures
        // that Write errors are sticky.
        inner_writer: WriterType,
        bytes_written: usize,

        // Data waiting to be written is bytes[0 .. nbytes]
        // and then the low nbits of bits.  Data is always written
        // sequentially into the bytes array.
        bits: u64,
        nbits: u32, // number of bits
        bytes: [buffer_size]u8,
        codegen_freq: [codegen_code_count]u16,
        nbytes: u32, // number of bytes
        literal_freq: [deflate_const.max_num_lit]u16,
        offset_freq: [deflate_const.offset_code_count]u16,
        codegen: [deflate_const.max_num_lit + deflate_const.offset_code_count + 1]u8,
        literal_encoding: hm_code.LiteralEncoder,
        offset_encoding: hm_code.OffsetEncoder,
        codegen_encoding: hm_code.CodegenEncoder,
        err: bool = false,
        fixed_literal_encoding: hm_code.LiteralEncoder,
        fixed_offset_encoding: hm_code.OffsetEncoder,
        huff_offset: hm_code.OffsetEncoder,

        pub fn reset(self: *Self, new_writer: WriterType) void {
            self.inner_writer = new_writer;
            self.bytes_written = 0;
            self.bits = 0;
            self.nbits = 0;
            self.nbytes = 0;
            self.err = false;
        }

        pub fn flush(self: *Self) Error!void {
            if (self.err) {
                self.nbits = 0;
                return;
            }
            var n = self.nbytes;
            while (self.nbits != 0) {
                self.bytes[n] = @as(u8, @truncate(self.bits));
                self.bits >>= 8;
                if (self.nbits > 8) { // Avoid underflow
                    self.nbits -= 8;
                } else {
                    self.nbits = 0;
                }
                n += 1;
            }
            self.bits = 0;
            try self.write(self.bytes[0..n]);
            self.nbytes = 0;
        }

        fn write(self: *Self, b: []const u8) Error!void {
            if (self.err) {
                return;
            }
            self.bytes_written += try self.inner_writer.write(b);
        }

        fn writeBits(self: *Self, b: u32, nb: u32) Error!void {
            if (self.err) {
                return;
            }
            self.bits |= @as(u64, @intCast(b)) << @as(u6, @intCast(self.nbits));
            self.nbits += nb;
            if (self.nbits >= 48) {
                const bits = self.bits;
                self.bits >>= 48;
                self.nbits -= 48;
                var n = self.nbytes;
                var bytes = self.bytes[n..][0..6];
                bytes[0] = @as(u8, @truncate(bits));
                bytes[1] = @as(u8, @truncate(bits >> 8));
                bytes[2] = @as(u8, @truncate(bits >> 16));
                bytes[3] = @as(u8, @truncate(bits >> 24));
                bytes[4] = @as(u8, @truncate(bits >> 32));
                bytes[5] = @as(u8, @truncate(bits >> 40));
                n += 6;
                if (n >= buffer_flush_size) {
                    try self.write(self.bytes[0..n]);
                    n = 0;
                }
                self.nbytes = n;
            }
        }

        pub fn writeBytes(self: *Self, bytes: []const u8) Error!void {
            if (self.err) {
                return;
            }
            var n = self.nbytes;
            if (self.nbits & 7 != 0) {
                self.err = true; // unfinished bits
                return;
            }
            while (self.nbits != 0) {
                self.bytes[n] = @as(u8, @truncate(self.bits));
                self.bits >>= 8;
                self.nbits -= 8;
                n += 1;
            }
            if (n != 0) {
                try self.write(self.bytes[0..n]);
            }
            self.nbytes = 0;
            try self.write(bytes);
        }

        // RFC 1951 3.2.7 specifies a special run-length encoding for specifying
        // the literal and offset lengths arrays (which are concatenated into a single
        // array).  This method generates that run-length encoding.
        //
        // The result is written into the codegen array, and the frequencies
        // of each code is written into the codegen_freq array.
        // Codes 0-15 are single byte codes. Codes 16-18 are followed by additional
        // information. Code bad_code is an end marker
        //
        // num_literals: The number of literals in literal_encoding
        // num_offsets: The number of offsets in offset_encoding
        // lit_enc: The literal encoder to use
        // off_enc: The offset encoder to use
        fn generateCodegen(
            self: *Self,
            num_literals: u32,
            num_offsets: u32,
            lit_enc: *hm_code.LiteralEncoder,
            off_enc: *hm_code.OffsetEncoder,
        ) void {
            for (self.codegen_freq, 0..) |_, i| {
                self.codegen_freq[i] = 0;
            }

            // Note that we are using codegen both as a temporary variable for holding
            // a copy of the frequencies, and as the place where we put the result.
            // This is fine because the output is always shorter than the input used
            // so far.
            var codegen = &self.codegen; // cache
            // Copy the concatenated code sizes to codegen. Put a marker at the end.
            var cgnl = codegen[0..num_literals];
            for (cgnl, 0..) |_, i| {
                cgnl[i] = @as(u8, @intCast(lit_enc.codes[i].len));
            }

            cgnl = codegen[num_literals .. num_literals + num_offsets];
            for (cgnl, 0..) |_, i| {
                cgnl[i] = @as(u8, @intCast(off_enc.codes[i].len));
            }
            codegen[num_literals + num_offsets] = bad_code;

            var size = codegen[0];
            var count: i32 = 1;
            var out_index: u32 = 0;
            var in_index: u32 = 1;
            while (size != bad_code) : (in_index += 1) {
                // INVARIANT: We have seen "count" copies of size that have not yet
                // had output generated for them.
                const next_size = codegen[in_index];
                if (next_size == size) {
                    count += 1;
                    continue;
                }
                // We need to generate codegen indicating "count" of size.
                if (size != 0) {
                    codegen[out_index] = size;
                    out_index += 1;
                    self.codegen_freq[size] += 1;
                    count -= 1;
                    while (count >= 3) {
                        var n: i32 = 6;
                        if (n > count) {
                            n = count;
                        }
                        codegen[out_index] = 16;
                        out_index += 1;
                        codegen[out_index] = @as(u8, @intCast(n - 3));
                        out_index += 1;
                        self.codegen_freq[16] += 1;
                        count -= n;
                    }
                } else {
                    while (count >= 11) {
                        var n: i32 = 138;
                        if (n > count) {
                            n = count;
                        }
                        codegen[out_index] = 18;
                        out_index += 1;
                        codegen[out_index] = @as(u8, @intCast(n - 11));
                        out_index += 1;
                        self.codegen_freq[18] += 1;
                        count -= n;
                    }
                    if (count >= 3) {
                        // 3 <= count <= 10
                        codegen[out_index] = 17;
                        out_index += 1;
                        codegen[out_index] = @as(u8, @intCast(count - 3));
                        out_index += 1;
                        self.codegen_freq[17] += 1;
                        count = 0;
                    }
                }
                count -= 1;
                while (count >= 0) : (count -= 1) {
                    codegen[out_index] = size;
                    out_index += 1;
                    self.codegen_freq[size] += 1;
                }
                // Set up invariant for next time through the loop.
                size = next_size;
                count = 1;
            }
            // Marker indicating the end of the codegen.
            codegen[out_index] = bad_code;
        }

        // dynamicSize returns the size of dynamically encoded data in bits.
        fn dynamicSize(
            self: *Self,
            lit_enc: *hm_code.LiteralEncoder, // literal encoder
            off_enc: *hm_code.OffsetEncoder, // offset encoder
            extra_bits: u32,
        ) DynamicSize {
            var num_codegens = self.codegen_freq.len;
            while (num_codegens > 4 and self.codegen_freq[codegen_order[num_codegens - 1]] == 0) {
                num_codegens -= 1;
            }
            const header = 3 + 5 + 5 + 4 + (3 * num_codegens) +
                self.codegen_encoding.bitLength(self.codegen_freq[0..]) +
                self.codegen_freq[16] * 2 +
                self.codegen_freq[17] * 3 +
                self.codegen_freq[18] * 7;
            const size = header +
                lit_enc.bitLength(&self.literal_freq) +
                off_enc.bitLength(&self.offset_freq) +
                extra_bits;

            return DynamicSize{
                .size = @as(u32, @intCast(size)),
                .num_codegens = @as(u32, @intCast(num_codegens)),
            };
        }

        // fixedSize returns the size of dynamically encoded data in bits.
        fn fixedSize(self: *Self, extra_bits: u32) u32 {
            return 3 +
                self.fixed_literal_encoding.bitLength(&self.literal_freq) +
                self.fixed_offset_encoding.bitLength(&self.offset_freq) +
                extra_bits;
        }

        // storedSizeFits calculates the stored size, including header.
        // The function returns the size in bits and whether the block
        // fits inside a single block.
        fn storedSizeFits(in: ?[]const u8) StoredSize {
            if (in == null) {
                return .{ .size = 0, .storable = false };
            }
            if (in.?.len <= deflate_const.max_store_block_size) {
                return .{ .size = @as(u32, @intCast((in.?.len + 5) * 8)), .storable = true };
            }
            return .{ .size = 0, .storable = false };
        }

        fn writeCode(self: *Self, c: hm_code.HuffCode) Error!void {
            if (self.err) {
                return;
            }
            self.bits |= @as(u64, @intCast(c.code)) << @as(u6, @intCast(self.nbits));
            self.nbits += @as(u32, @intCast(c.len));
            if (self.nbits >= 48) {
                const bits = self.bits;
                self.bits >>= 48;
                self.nbits -= 48;
                var n = self.nbytes;
                var bytes = self.bytes[n..][0..6];
                bytes[0] = @as(u8, @truncate(bits));
                bytes[1] = @as(u8, @truncate(bits >> 8));
                bytes[2] = @as(u8, @truncate(bits >> 16));
                bytes[3] = @as(u8, @truncate(bits >> 24));
                bytes[4] = @as(u8, @truncate(bits >> 32));
                bytes[5] = @as(u8, @truncate(bits >> 40));
                n += 6;
                if (n >= buffer_flush_size) {
                    try self.write(self.bytes[0..n]);
                    n = 0;
                }
                self.nbytes = n;
            }
        }

        // Write the header of a dynamic Huffman block to the output stream.
        //
        //  num_literals: The number of literals specified in codegen
        //  num_offsets: The number of offsets specified in codegen
        //  num_codegens: The number of codegens used in codegen
        //  is_eof: Is it the end-of-file? (end of stream)
        fn writeDynamicHeader(
            self: *Self,
            num_literals: u32,
            num_offsets: u32,
            num_codegens: u32,
            is_eof: bool,
        ) Error!void {
            if (self.err) {
                return;
            }
            var first_bits: u32 = 4;
            if (is_eof) {
                first_bits = 5;
            }
            try self.writeBits(first_bits, 3);
            try self.writeBits(@as(u32, @intCast(num_literals - 257)), 5);
            try self.writeBits(@as(u32, @intCast(num_offsets - 1)), 5);
            try self.writeBits(@as(u32, @intCast(num_codegens - 4)), 4);

            var i: u32 = 0;
            while (i < num_codegens) : (i += 1) {
                const value = @as(u32, @intCast(self.codegen_encoding.codes[codegen_order[i]].len));
                try self.writeBits(@as(u32, @intCast(value)), 3);
            }

            i = 0;
            while (true) {
                const code_word: u32 = @as(u32, @intCast(self.codegen[i]));
                i += 1;
                if (code_word == bad_code) {
                    break;
                }
                try self.writeCode(self.codegen_encoding.codes[@as(u32, @intCast(code_word))]);

                switch (code_word) {
                    16 => {
                        try self.writeBits(@as(u32, @intCast(self.codegen[i])), 2);
                        i += 1;
                    },
                    17 => {
                        try self.writeBits(@as(u32, @intCast(self.codegen[i])), 3);
                        i += 1;
                    },
                    18 => {
                        try self.writeBits(@as(u32, @intCast(self.codegen[i])), 7);
                        i += 1;
                    },
                    else => {},
                }
            }
        }

        pub fn writeStoredHeader(self: *Self, length: usize, is_eof: bool) Error!void {
            if (self.err) {
                return;
            }
            var flag: u32 = 0;
            if (is_eof) {
                flag = 1;
            }
            try self.writeBits(flag, 3);
            try self.flush();
            try self.writeBits(@as(u32, @intCast(length)), 16);
            try self.writeBits(@as(u32, @intCast(~@as(u16, @intCast(length)))), 16);
        }

        fn writeFixedHeader(self: *Self, is_eof: bool) Error!void {
            if (self.err) {
                return;
            }
            // Indicate that we are a fixed Huffman block
            var value: u32 = 2;
            if (is_eof) {
                value = 3;
            }
            try self.writeBits(value, 3);
        }

        // Write a block of tokens with the smallest encoding.
        // The original input can be supplied, and if the huffman encoded data
        // is larger than the original bytes, the data will be written as a
        // stored block.
        // If the input is null, the tokens will always be Huffman encoded.
        pub fn writeBlock(
            self: *Self,
            tokens: []const token.Token,
            eof: bool,
            input: ?[]const u8,
        ) Error!void {
            if (self.err) {
                return;
            }

            const lit_and_off = self.indexTokens(tokens);
            const num_literals = lit_and_off.num_literals;
            const num_offsets = lit_and_off.num_offsets;

            var extra_bits: u32 = 0;
            const ret = storedSizeFits(input);
            const stored_size = ret.size;
            const storable = ret.storable;

            if (storable) {
                // We only bother calculating the costs of the extra bits required by
                // the length of offset fields (which will be the same for both fixed
                // and dynamic encoding), if we need to compare those two encodings
                // against stored encoding.
                var length_code: u32 = length_codes_start + 8;
                while (length_code < num_literals) : (length_code += 1) {
                    // First eight length codes have extra size = 0.
                    extra_bits += @as(u32, @intCast(self.literal_freq[length_code])) *
                        @as(u32, @intCast(length_extra_bits[length_code - length_codes_start]));
                }
                var offset_code: u32 = 4;
                while (offset_code < num_offsets) : (offset_code += 1) {
                    // First four offset codes have extra size = 0.
                    extra_bits += @as(u32, @intCast(self.offset_freq[offset_code])) *
                        @as(u32, @intCast(offset_extra_bits[offset_code]));
                }
            }

            // Figure out smallest code.
            // Fixed Huffman baseline.
            var literal_encoding = &self.fixed_literal_encoding;
            var offset_encoding = &self.fixed_offset_encoding;
            var size = self.fixedSize(extra_bits);

            // Dynamic Huffman?
            var num_codegens: u32 = 0;

            // Generate codegen and codegenFrequencies, which indicates how to encode
            // the literal_encoding and the offset_encoding.
            self.generateCodegen(
                num_literals,
                num_offsets,
                &self.literal_encoding,
                &self.offset_encoding,
            );
            self.codegen_encoding.generate(self.codegen_freq[0..], 7);
            const dynamic_size = self.dynamicSize(
                &self.literal_encoding,
                &self.offset_encoding,
                extra_bits,
            );
            const dyn_size = dynamic_size.size;
            num_codegens = dynamic_size.num_codegens;

            if (dyn_size < size) {
                size = dyn_size;
                literal_encoding = &self.literal_encoding;
                offset_encoding = &self.offset_encoding;
            }

            // Stored bytes?
            if (storable and stored_size < size) {
                try self.writeStoredHeader(input.?.len, eof);
                try self.writeBytes(input.?);
                return;
            }

            // Huffman.
            if (@intFromPtr(literal_encoding) == @intFromPtr(&self.fixed_literal_encoding)) {
                try self.writeFixedHeader(eof);
            } else {
                try self.writeDynamicHeader(num_literals, num_offsets, num_codegens, eof);
            }

            // Write the tokens.
            try self.writeTokens(tokens, &literal_encoding.codes, &offset_encoding.codes);
        }

        // writeBlockDynamic encodes a block using a dynamic Huffman table.
        // This should be used if the symbols used have a disproportionate
        // histogram distribution.
        // If input is supplied and the compression savings are below 1/16th of the
        // input size the block is stored.
        pub fn writeBlockDynamic(
            self: *Self,
            tokens: []const token.Token,
            eof: bool,
            input: ?[]const u8,
        ) Error!void {
            if (self.err) {
                return;
            }

            const total_tokens = self.indexTokens(tokens);
            const num_literals = total_tokens.num_literals;
            const num_offsets = total_tokens.num_offsets;

            // Generate codegen and codegenFrequencies, which indicates how to encode
            // the literal_encoding and the offset_encoding.
            self.generateCodegen(
                num_literals,
                num_offsets,
                &self.literal_encoding,
                &self.offset_encoding,
            );
            self.codegen_encoding.generate(self.codegen_freq[0..], 7);
            const dynamic_size = self.dynamicSize(&self.literal_encoding, &self.offset_encoding, 0);
            const size = dynamic_size.size;
            const num_codegens = dynamic_size.num_codegens;

            // Store bytes, if we don't get a reasonable improvement.

            const stored_size = storedSizeFits(input);
            const ssize = stored_size.size;
            const storable = stored_size.storable;
            if (storable and ssize < (size + (size >> 4))) {
                try self.writeStoredHeader(input.?.len, eof);
                try self.writeBytes(input.?);
                return;
            }

            // Write Huffman table.
            try self.writeDynamicHeader(num_literals, num_offsets, num_codegens, eof);

            // Write the tokens.
            try self.writeTokens(tokens, &self.literal_encoding.codes, &self.offset_encoding.codes);
        }

        const TotalIndexedTokens = struct {
            num_literals: u32,
            num_offsets: u32,
        };

        // Indexes a slice of tokens followed by an end_block_marker, and updates
        // literal_freq and offset_freq, and generates literal_encoding
        // and offset_encoding.
        // The number of literal and offset tokens is returned.
        fn indexTokens(self: *Self, tokens: []const token.Token) TotalIndexedTokens {
            var num_literals: u32 = 0;
            var num_offsets: u32 = 0;

            for (self.literal_freq, 0..) |_, i| {
                self.literal_freq[i] = 0;
            }
            for (self.offset_freq, 0..) |_, i| {
                self.offset_freq[i] = 0;
            }

            for (tokens) |t| {
                if (t < token.match_type) {
                    self.literal_freq[token.literal(t)] += 1;
                    continue;
                }
                const length = token.length(t);
                const offset = token.offset(t);
                self.literal_freq[length_codes_start + token.lengthCode(length)] += 1;
                self.offset_freq[token.offsetCode(offset)] += 1;
            }
            // add end_block_marker token at the end
            self.literal_freq[token.literal(deflate_const.end_block_marker)] += 1;

            // get the number of literals
            num_literals = @as(u32, @intCast(self.literal_freq.len));
            while (self.literal_freq[num_literals - 1] == 0) {
                num_literals -= 1;
            }
            // get the number of offsets
            num_offsets = @as(u32, @intCast(self.offset_freq.len));
            while (num_offsets > 0 and self.offset_freq[num_offsets - 1] == 0) {
                num_offsets -= 1;
            }
            if (num_offsets == 0) {
                // We haven't found a single match. If we want to go with the dynamic encoding,
                // we should count at least one offset to be sure that the offset huffman tree could be encoded.
                self.offset_freq[0] = 1;
                num_offsets = 1;
            }
            self.literal_encoding.generate(&self.literal_freq, 15);
            self.offset_encoding.generate(&self.offset_freq, 15);
            return TotalIndexedTokens{
                .num_literals = num_literals,
                .num_offsets = num_offsets,
            };
        }

        // Writes a slice of tokens to the output followed by and end_block_marker.
        // codes for literal and offset encoding must be supplied.
        fn writeTokens(
            self: *Self,
            tokens: []const token.Token,
            le_codes: []hm_code.HuffCode,
            oe_codes: []hm_code.HuffCode,
        ) Error!void {
            if (self.err) {
                return;
            }
            for (tokens) |t| {
                if (t < token.match_type) {
                    try self.writeCode(le_codes[token.literal(t)]);
                    continue;
                }
                // Write the length
                const length = token.length(t);
                const length_code = token.lengthCode(length);
                try self.writeCode(le_codes[length_code + length_codes_start]);
                const extra_length_bits = @as(u32, @intCast(length_extra_bits[length_code]));
                if (extra_length_bits > 0) {
                    const extra_length = @as(u32, @intCast(length - length_base[length_code]));
                    try self.writeBits(extra_length, extra_length_bits);
                }
                // Write the offset
                const offset = token.offset(t);
                const offset_code = token.offsetCode(offset);
                try self.writeCode(oe_codes[offset_code]);
                const extra_offset_bits = @as(u32, @intCast(offset_extra_bits[offset_code]));
                if (extra_offset_bits > 0) {
                    const extra_offset = @as(u32, @intCast(offset - offset_base[offset_code]));
                    try self.writeBits(extra_offset, extra_offset_bits);
                }
            }
            // add end_block_marker at the end
            try self.writeCode(le_codes[token.literal(deflate_const.end_block_marker)]);
        }

        // Encodes a block of bytes as either Huffman encoded literals or uncompressed bytes
        // if the results only gains very little from compression.
        pub fn writeBlockHuff(self: *Self, eof: bool, input: []const u8) Error!void {
            if (self.err) {
                return;
            }

            // Clear histogram
            for (self.literal_freq, 0..) |_, i| {
                self.literal_freq[i] = 0;
            }

            // Add everything as literals
            histogram(input, &self.literal_freq);

            self.literal_freq[deflate_const.end_block_marker] = 1;

            const num_literals = deflate_const.end_block_marker + 1;
            self.offset_freq[0] = 1;
            const num_offsets = 1;

            self.literal_encoding.generate(&self.literal_freq, 15);

            // Figure out smallest code.
            // Always use dynamic Huffman or Store
            var num_codegens: u32 = 0;

            // Generate codegen and codegenFrequencies, which indicates how to encode
            // the literal_encoding and the offset_encoding.
            self.generateCodegen(
                num_literals,
                num_offsets,
                &self.literal_encoding,
                &self.huff_offset,
            );
            self.codegen_encoding.generate(self.codegen_freq[0..], 7);
            const dynamic_size = self.dynamicSize(&self.literal_encoding, &self.huff_offset, 0);
            const size = dynamic_size.size;
            num_codegens = dynamic_size.num_codegens;

            // Store bytes, if we don't get a reasonable improvement.

            const stored_size_ret = storedSizeFits(input);
            const ssize = stored_size_ret.size;
            const storable = stored_size_ret.storable;

            if (storable and ssize < (size + (size >> 4))) {
                try self.writeStoredHeader(input.len, eof);
                try self.writeBytes(input);
                return;
            }

            // Huffman.
            try self.writeDynamicHeader(num_literals, num_offsets, num_codegens, eof);
            const encoding = self.literal_encoding.codes[0..257];
            var n = self.nbytes;
            for (input) |t| {
                // Bitwriting inlined, ~30% speedup
                const c = encoding[t];
                self.bits |= @as(u64, @intCast(c.code)) << @as(u6, @intCast(self.nbits));
                self.nbits += @as(u32, @intCast(c.len));
                if (self.nbits < 48) {
                    continue;
                }
                // Store 6 bytes
                const bits = self.bits;
                self.bits >>= 48;
                self.nbits -= 48;
                var bytes = self.bytes[n..][0..6];
                bytes[0] = @as(u8, @truncate(bits));
                bytes[1] = @as(u8, @truncate(bits >> 8));
                bytes[2] = @as(u8, @truncate(bits >> 16));
                bytes[3] = @as(u8, @truncate(bits >> 24));
                bytes[4] = @as(u8, @truncate(bits >> 32));
                bytes[5] = @as(u8, @truncate(bits >> 40));
                n += 6;
                if (n < buffer_flush_size) {
                    continue;
                }
                try self.write(self.bytes[0..n]);
                if (self.err) {
                    return; // Return early in the event of write failures
                }
                n = 0;
            }
            self.nbytes = n;
            try self.writeCode(encoding[deflate_const.end_block_marker]);
        }
    };
}

const DynamicSize = struct {
    size: u32,
    num_codegens: u32,
};

const StoredSize = struct {
    size: u32,
    storable: bool,
};

pub fn huffmanBitWriter(writer: anytype) HuffmanBitWriter(@TypeOf(writer)) {
    var offset_freq = [1]u16{0} ** deflate_const.offset_code_count;
    offset_freq[0] = 1;
    // huff_offset is a static offset encoder used for huffman only encoding.
    // It can be reused since we will not be encoding offset values.
    var huff_offset: hm_code.OffsetEncoder = .{};
    huff_offset.generate(offset_freq[0..], 15);

    return HuffmanBitWriter(@TypeOf(writer)){
        .inner_writer = writer,
        .bytes_written = 0,
        .bits = 0,
        .nbits = 0,
        .nbytes = 0,
        .bytes = undefined, //[1]u8{0} ** buffer_size,
        .codegen_freq = undefined, // [1]u16{0} ** codegen_code_count,
        .literal_freq = undefined,
        .offset_freq = undefined,
        .codegen = undefined,
        .literal_encoding = .{},
        .codegen_encoding = .{},
        .offset_encoding = .{},
        .fixed_literal_encoding = hm_code.fixedLiteralEncoder(),
        .fixed_offset_encoding = hm_code.fixedOffsetEncoder(),
        .huff_offset = huff_offset,
    };
}

// histogram accumulates a histogram of b in h.
//
// h.len must be >= 256, and h's elements must be all zeroes.
fn histogram(b: []const u8, h: *[286]u16) void {
    var lh = h.*[0..256];
    for (b) |t| {
        lh[t] += 1;
    }
}

// tests
const expect = std.testing.expect;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const ArrayList = std.ArrayList;

test "writeBlockHuff" {
    // Tests huffman encoding against reference files to detect possible regressions.
    // If encoding/bit allocation changes you can regenerate these files

    try testBlockHuff(
        "huffman-null-max.input",
        "huffman-null-max.golden",
    );
    try testBlockHuff(
        "huffman-pi.input",
        "huffman-pi.golden",
    );
    try testBlockHuff(
        "huffman-rand-1k.input",
        "huffman-rand-1k.golden",
    );
    try testBlockHuff(
        "huffman-rand-limit.input",
        "huffman-rand-limit.golden",
    );
    try testBlockHuff(
        "huffman-rand-max.input",
        "huffman-rand-max.golden",
    );
    try testBlockHuff(
        "huffman-shifts.input",
        "huffman-shifts.golden",
    );
    try testBlockHuff(
        "huffman-text.input",
        "huffman-text.golden",
    );
    try testBlockHuff(
        "huffman-text-shift.input",
        "huffman-text-shift.golden",
    );
    try testBlockHuff(
        "huffman-zero.input",
        "huffman-zero.golden",
    );
}

fn testBlockHuff(comptime in_name: []const u8, comptime want_name: []const u8) !void {
    const in: []const u8 = @embedFile("testdata/" ++ in_name);
    const want: []const u8 = @embedFile("testdata/" ++ want_name);

    var buf = ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    var bw = huffmanBitWriter(buf.writer());
    try bw.writeBlockHuff(false, in);
    try bw.flush();

    try std.testing.expectEqualSlices(u8, want, buf.items);

    // Test if the writer produces the same output after reset.
    var buf_after_reset = ArrayList(u8).init(testing.allocator);
    defer buf_after_reset.deinit();

    bw.reset(buf_after_reset.writer());

    try bw.writeBlockHuff(false, in);
    try bw.flush();

    try std.testing.expectEqualSlices(u8, buf.items, buf_after_reset.items);
    try std.testing.expectEqualSlices(u8, want, buf_after_reset.items);

    try testWriterEOF(.write_huffman_block, &[0]token.Token{}, in);
}

const HuffTest = struct {
    tokens: []const token.Token,
    input: []const u8 = "", // File name of input data matching the tokens.
    want: []const u8 = "", // File name of data with the expected output with input available.
    want_no_input: []const u8 = "", // File name of the expected output when no input is available.
};

fn L(c: u8) token.Token {
    return token.literalToken(c);
}

fn M(l: u32, d: u32) token.Token {
    return token.matchToken(l - 3, d - 1);
}

const writeBlockTests = blk: {
    @setEvalBranchQuota(4096 * 2);

    const ml = M(258, 1); // Maximum length token. Used to reduce the size of writeBlockTests

    break :blk &[_]HuffTest{
        HuffTest{
            .input = "huffman-null-max.input",
            .want = "huffman-null-max.{s}.expect",
            .want_no_input = "huffman-null-max.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L(0x0), ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,     ml,     ml, ml, ml,
                ml,     ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, L(0x0), L(0x0),
            },
        },
        HuffTest{
            .input = "huffman-pi.input",
            .want = "huffman-pi.{s}.expect",
            .want_no_input = "huffman-pi.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L('3'),     L('.'),     L('1'),     L('4'),     L('1'),     L('5'),     L('9'),     L('2'),
                L('6'),     L('5'),     L('3'),     L('5'),     L('8'),     L('9'),     L('7'),     L('9'),
                L('3'),     L('2'),     L('3'),     L('8'),     L('4'),     L('6'),     L('2'),     L('6'),
                L('4'),     L('3'),     L('3'),     L('8'),     L('3'),     L('2'),     L('7'),     L('9'),
                L('5'),     L('0'),     L('2'),     L('8'),     L('8'),     L('4'),     L('1'),     L('9'),
                L('7'),     L('1'),     L('6'),     L('9'),     L('3'),     L('9'),     L('9'),     L('3'),
                L('7'),     L('5'),     L('1'),     L('0'),     L('5'),     L('8'),     L('2'),     L('0'),
                L('9'),     L('7'),     L('4'),     L('9'),     L('4'),     L('4'),     L('5'),     L('9'),
                L('2'),     L('3'),     L('0'),     L('7'),     L('8'),     L('1'),     L('6'),     L('4'),
                L('0'),     L('6'),     L('2'),     L('8'),     L('6'),     L('2'),     L('0'),     L('8'),
                L('9'),     L('9'),     L('8'),     L('6'),     L('2'),     L('8'),     L('0'),     L('3'),
                L('4'),     L('8'),     L('2'),     L('5'),     L('3'),     L('4'),     L('2'),     L('1'),
                L('1'),     L('7'),     L('0'),     L('6'),     L('7'),     L('9'),     L('8'),     L('2'),
                L('1'),     L('4'),     L('8'),     L('0'),     L('8'),     L('6'),     L('5'),     L('1'),
                L('3'),     L('2'),     L('8'),     L('2'),     L('3'),     L('0'),     L('6'),     L('6'),
                L('4'),     L('7'),     L('0'),     L('9'),     L('3'),     L('8'),     L('4'),     L('4'),
                L('6'),     L('0'),     L('9'),     L('5'),     L('5'),     L('0'),     L('5'),     L('8'),
                L('2'),     L('2'),     L('3'),     L('1'),     L('7'),     L('2'),     L('5'),     L('3'),
                L('5'),     L('9'),     L('4'),     L('0'),     L('8'),     L('1'),     L('2'),     L('8'),
                L('4'),     L('8'),     L('1'),     L('1'),     L('1'),     L('7'),     L('4'),     M(4, 127),
                L('4'),     L('1'),     L('0'),     L('2'),     L('7'),     L('0'),     L('1'),     L('9'),
                L('3'),     L('8'),     L('5'),     L('2'),     L('1'),     L('1'),     L('0'),     L('5'),
                L('5'),     L('5'),     L('9'),     L('6'),     L('4'),     L('4'),     L('6'),     L('2'),
                L('2'),     L('9'),     L('4'),     L('8'),     L('9'),     L('5'),     L('4'),     L('9'),
                L('3'),     L('0'),     L('3'),     L('8'),     L('1'),     M(4, 19),   L('2'),     L('8'),
                L('8'),     L('1'),     L('0'),     L('9'),     L('7'),     L('5'),     L('6'),     L('6'),
                L('5'),     L('9'),     L('3'),     L('3'),     L('4'),     L('4'),     L('6'),     M(4, 72),
                L('7'),     L('5'),     L('6'),     L('4'),     L('8'),     L('2'),     L('3'),     L('3'),
                L('7'),     L('8'),     L('6'),     L('7'),     L('8'),     L('3'),     L('1'),     L('6'),
                L('5'),     L('2'),     L('7'),     L('1'),     L('2'),     L('0'),     L('1'),     L('9'),
                L('0'),     L('9'),     L('1'),     L('4'),     M(4, 27),   L('5'),     L('6'),     L('6'),
                L('9'),     L('2'),     L('3'),     L('4'),     L('6'),     M(4, 179),  L('6'),     L('1'),
                L('0'),     L('4'),     L('5'),     L('4'),     L('3'),     L('2'),     L('6'),     M(4, 51),
                L('1'),     L('3'),     L('3'),     L('9'),     L('3'),     L('6'),     L('0'),     L('7'),
                L('2'),     L('6'),     L('0'),     L('2'),     L('4'),     L('9'),     L('1'),     L('4'),
                L('1'),     L('2'),     L('7'),     L('3'),     L('7'),     L('2'),     L('4'),     L('5'),
                L('8'),     L('7'),     L('0'),     L('0'),     L('6'),     L('6'),     L('0'),     L('6'),
                L('3'),     L('1'),     L('5'),     L('5'),     L('8'),     L('8'),     L('1'),     L('7'),
                L('4'),     L('8'),     L('8'),     L('1'),     L('5'),     L('2'),     L('0'),     L('9'),
                L('2'),     L('0'),     L('9'),     L('6'),     L('2'),     L('8'),     L('2'),     L('9'),
                L('2'),     L('5'),     L('4'),     L('0'),     L('9'),     L('1'),     L('7'),     L('1'),
                L('5'),     L('3'),     L('6'),     L('4'),     L('3'),     L('6'),     L('7'),     L('8'),
                L('9'),     L('2'),     L('5'),     L('9'),     L('0'),     L('3'),     L('6'),     L('0'),
                L('0'),     L('1'),     L('1'),     L('3'),     L('3'),     L('0'),     L('5'),     L('3'),
                L('0'),     L('5'),     L('4'),     L('8'),     L('8'),     L('2'),     L('0'),     L('4'),
                L('6'),     L('6'),     L('5'),     L('2'),     L('1'),     L('3'),     L('8'),     L('4'),
                L('1'),     L('4'),     L('6'),     L('9'),     L('5'),     L('1'),     L('9'),     L('4'),
                L('1'),     L('5'),     L('1'),     L('1'),     L('6'),     L('0'),     L('9'),     L('4'),
                L('3'),     L('3'),     L('0'),     L('5'),     L('7'),     L('2'),     L('7'),     L('0'),
                L('3'),     L('6'),     L('5'),     L('7'),     L('5'),     L('9'),     L('5'),     L('9'),
                L('1'),     L('9'),     L('5'),     L('3'),     L('0'),     L('9'),     L('2'),     L('1'),
                L('8'),     L('6'),     L('1'),     L('1'),     L('7'),     M(4, 234),  L('3'),     L('2'),
                M(4, 10),   L('9'),     L('3'),     L('1'),     L('0'),     L('5'),     L('1'),     L('1'),
                L('8'),     L('5'),     L('4'),     L('8'),     L('0'),     L('7'),     M(4, 271),  L('3'),
                L('7'),     L('9'),     L('9'),     L('6'),     L('2'),     L('7'),     L('4'),     L('9'),
                L('5'),     L('6'),     L('7'),     L('3'),     L('5'),     L('1'),     L('8'),     L('8'),
                L('5'),     L('7'),     L('5'),     L('2'),     L('7'),     L('2'),     L('4'),     L('8'),
                L('9'),     L('1'),     L('2'),     L('2'),     L('7'),     L('9'),     L('3'),     L('8'),
                L('1'),     L('8'),     L('3'),     L('0'),     L('1'),     L('1'),     L('9'),     L('4'),
                L('9'),     L('1'),     L('2'),     L('9'),     L('8'),     L('3'),     L('3'),     L('6'),
                L('7'),     L('3'),     L('3'),     L('6'),     L('2'),     L('4'),     L('4'),     L('0'),
                L('6'),     L('5'),     L('6'),     L('6'),     L('4'),     L('3'),     L('0'),     L('8'),
                L('6'),     L('0'),     L('2'),     L('1'),     L('3'),     L('9'),     L('4'),     L('9'),
                L('4'),     L('6'),     L('3'),     L('9'),     L('5'),     L('2'),     L('2'),     L('4'),
                L('7'),     L('3'),     L('7'),     L('1'),     L('9'),     L('0'),     L('7'),     L('0'),
                L('2'),     L('1'),     L('7'),     L('9'),     L('8'),     M(5, 154),  L('7'),     L('0'),
                L('2'),     L('7'),     L('7'),     L('0'),     L('5'),     L('3'),     L('9'),     L('2'),
                L('1'),     L('7'),     L('1'),     L('7'),     L('6'),     L('2'),     L('9'),     L('3'),
                L('1'),     L('7'),     L('6'),     L('7'),     L('5'),     M(5, 563),  L('7'),     L('4'),
                L('8'),     L('1'),     M(4, 7),    L('6'),     L('6'),     L('9'),     L('4'),     L('0'),
                M(4, 488),  L('0'),     L('0'),     L('0'),     L('5'),     L('6'),     L('8'),     L('1'),
                L('2'),     L('7'),     L('1'),     L('4'),     L('5'),     L('2'),     L('6'),     L('3'),
                L('5'),     L('6'),     L('0'),     L('8'),     L('2'),     L('7'),     L('7'),     L('8'),
                L('5'),     L('7'),     L('7'),     L('1'),     L('3'),     L('4'),     L('2'),     L('7'),
                L('5'),     L('7'),     L('7'),     L('8'),     L('9'),     L('6'),     M(4, 298),  L('3'),
                L('6'),     L('3'),     L('7'),     L('1'),     L('7'),     L('8'),     L('7'),     L('2'),
                L('1'),     L('4'),     L('6'),     L('8'),     L('4'),     L('4'),     L('0'),     L('9'),
                L('0'),     L('1'),     L('2'),     L('2'),     L('4'),     L('9'),     L('5'),     L('3'),
                L('4'),     L('3'),     L('0'),     L('1'),     L('4'),     L('6'),     L('5'),     L('4'),
                L('9'),     L('5'),     L('8'),     L('5'),     L('3'),     L('7'),     L('1'),     L('0'),
                L('5'),     L('0'),     L('7'),     L('9'),     M(4, 203),  L('6'),     M(4, 340),  L('8'),
                L('9'),     L('2'),     L('3'),     L('5'),     L('4'),     M(4, 458),  L('9'),     L('5'),
                L('6'),     L('1'),     L('1'),     L('2'),     L('1'),     L('2'),     L('9'),     L('0'),
                L('2'),     L('1'),     L('9'),     L('6'),     L('0'),     L('8'),     L('6'),     L('4'),
                L('0'),     L('3'),     L('4'),     L('4'),     L('1'),     L('8'),     L('1'),     L('5'),
                L('9'),     L('8'),     L('1'),     L('3'),     L('6'),     L('2'),     L('9'),     L('7'),
                L('7'),     L('4'),     M(4, 117),  L('0'),     L('9'),     L('9'),     L('6'),     L('0'),
                L('5'),     L('1'),     L('8'),     L('7'),     L('0'),     L('7'),     L('2'),     L('1'),
                L('1'),     L('3'),     L('4'),     L('9'),     M(5, 1),    L('8'),     L('3'),     L('7'),
                L('2'),     L('9'),     L('7'),     L('8'),     L('0'),     L('4'),     L('9'),     L('9'),
                M(4, 731),  L('9'),     L('7'),     L('3'),     L('1'),     L('7'),     L('3'),     L('2'),
                L('8'),     M(4, 395),  L('6'),     L('3'),     L('1'),     L('8'),     L('5'),     M(4, 770),
                M(4, 745),  L('4'),     L('5'),     L('5'),     L('3'),     L('4'),     L('6'),     L('9'),
                L('0'),     L('8'),     L('3'),     L('0'),     L('2'),     L('6'),     L('4'),     L('2'),
                L('5'),     L('2'),     L('2'),     L('3'),     L('0'),     M(4, 740),  M(4, 616),  L('8'),
                L('5'),     L('0'),     L('3'),     L('5'),     L('2'),     L('6'),     L('1'),     L('9'),
                L('3'),     L('1'),     L('1'),     M(4, 531),  L('1'),     L('0'),     L('1'),     L('0'),
                L('0'),     L('0'),     L('3'),     L('1'),     L('3'),     L('7'),     L('8'),     L('3'),
                L('8'),     L('7'),     L('5'),     L('2'),     L('8'),     L('8'),     L('6'),     L('5'),
                L('8'),     L('7'),     L('5'),     L('3'),     L('3'),     L('2'),     L('0'),     L('8'),
                L('3'),     L('8'),     L('1'),     L('4'),     L('2'),     L('0'),     L('6'),     M(4, 321),
                M(4, 300),  L('1'),     L('4'),     L('7'),     L('3'),     L('0'),     L('3'),     L('5'),
                L('9'),     M(5, 815),  L('9'),     L('0'),     L('4'),     L('2'),     L('8'),     L('7'),
                L('5'),     L('5'),     L('4'),     L('6'),     L('8'),     L('7'),     L('3'),     L('1'),
                L('1'),     L('5'),     L('9'),     L('5'),     M(4, 854),  L('3'),     L('8'),     L('8'),
                L('2'),     L('3'),     L('5'),     L('3'),     L('7'),     L('8'),     L('7'),     L('5'),
                M(5, 896),  L('9'),     M(4, 315),  L('1'),     M(4, 329),  L('8'),     L('0'),     L('5'),
                L('3'),     M(4, 395),  L('2'),     L('2'),     L('6'),     L('8'),     L('0'),     L('6'),
                L('6'),     L('1'),     L('3'),     L('0'),     L('0'),     L('1'),     L('9'),     L('2'),
                L('7'),     L('8'),     L('7'),     L('6'),     L('6'),     L('1'),     L('1'),     L('1'),
                L('9'),     L('5'),     L('9'),     M(4, 568),  L('6'),     M(5, 293),  L('8'),     L('9'),
                L('3'),     L('8'),     L('0'),     L('9'),     L('5'),     L('2'),     L('5'),     L('7'),
                L('2'),     L('0'),     L('1'),     L('0'),     L('6'),     L('5'),     L('4'),     L('8'),
                L('5'),     L('8'),     L('6'),     L('3'),     L('2'),     L('7'),     M(4, 155),  L('9'),
                L('3'),     L('6'),     L('1'),     L('5'),     L('3'),     M(4, 545),  M(5, 349),  L('2'),
                L('3'),     L('0'),     L('3'),     L('0'),     L('1'),     L('9'),     L('5'),     L('2'),
                L('0'),     L('3'),     L('5'),     L('3'),     L('0'),     L('1'),     L('8'),     L('5'),
                L('2'),     M(4, 370),  M(4, 118),  L('3'),     L('6'),     L('2'),     L('2'),     L('5'),
                L('9'),     L('9'),     L('4'),     L('1'),     L('3'),     M(4, 597),  L('4'),     L('9'),
                L('7'),     L('2'),     L('1'),     L('7'),     M(4, 223),  L('3'),     L('4'),     L('7'),
                L('9'),     L('1'),     L('3'),     L('1'),     L('5'),     L('1'),     L('5'),     L('5'),
                L('7'),     L('4'),     L('8'),     L('5'),     L('7'),     L('2'),     L('4'),     L('2'),
                L('4'),     L('5'),     L('4'),     L('1'),     L('5'),     L('0'),     L('6'),     L('9'),
                M(4, 320),  L('8'),     L('2'),     L('9'),     L('5'),     L('3'),     L('3'),     L('1'),
                L('1'),     L('6'),     L('8'),     L('6'),     L('1'),     L('7'),     L('2'),     L('7'),
                L('8'),     M(4, 824),  L('9'),     L('0'),     L('7'),     L('5'),     L('0'),     L('9'),
                M(4, 270),  L('7'),     L('5'),     L('4'),     L('6'),     L('3'),     L('7'),     L('4'),
                L('6'),     L('4'),     L('9'),     L('3'),     L('9'),     L('3'),     L('1'),     L('9'),
                L('2'),     L('5'),     L('5'),     L('0'),     L('6'),     L('0'),     L('4'),     L('0'),
                L('0'),     L('9'),     M(4, 620),  L('1'),     L('6'),     L('7'),     L('1'),     L('1'),
                L('3'),     L('9'),     L('0'),     L('0'),     L('9'),     L('8'),     M(4, 822),  L('4'),
                L('0'),     L('1'),     L('2'),     L('8'),     L('5'),     L('8'),     L('3'),     L('6'),
                L('1'),     L('6'),     L('0'),     L('3'),     L('5'),     L('6'),     L('3'),     L('7'),
                L('0'),     L('7'),     L('6'),     L('6'),     L('0'),     L('1'),     L('0'),     L('4'),
                M(4, 371),  L('8'),     L('1'),     L('9'),     L('4'),     L('2'),     L('9'),     M(5, 1055),
                M(4, 240),  M(4, 652),  L('7'),     L('8'),     L('3'),     L('7'),     L('4'),     M(4, 1193),
                L('8'),     L('2'),     L('5'),     L('5'),     L('3'),     L('7'),     M(5, 522),  L('2'),
                L('6'),     L('8'),     M(4, 47),   L('4'),     L('0'),     L('4'),     L('7'),     M(4, 466),
                L('4'),     M(4, 1206), M(4, 910),  L('8'),     L('4'),     M(4, 937),  L('6'),     M(6, 800),
                L('3'),     L('3'),     L('1'),     L('3'),     L('6'),     L('7'),     L('7'),     L('0'),
                L('2'),     L('8'),     L('9'),     L('8'),     L('9'),     L('1'),     L('5'),     L('2'),
                M(4, 99),   L('5'),     L('2'),     L('1'),     L('6'),     L('2'),     L('0'),     L('5'),
                L('6'),     L('9'),     L('6'),     M(4, 1042), L('0'),     L('5'),     L('8'),     M(4, 1144),
                L('5'),     M(4, 1177), L('5'),     L('1'),     L('1'),     M(4, 522),  L('8'),     L('2'),
                L('4'),     L('3'),     L('0'),     L('0'),     L('3'),     L('5'),     L('5'),     L('8'),
                L('7'),     L('6'),     L('4'),     L('0'),     L('2'),     L('4'),     L('7'),     L('4'),
                L('9'),     L('6'),     L('4'),     L('7'),     L('3'),     L('2'),     L('6'),     L('3'),
                M(4, 1087), L('9'),     L('9'),     L('2'),     M(4, 1100), L('4'),     L('2'),     L('6'),
                L('9'),     M(6, 710),  L('7'),     M(4, 471),  L('4'),     M(4, 1342), M(4, 1054), L('9'),
                L('3'),     L('4'),     L('1'),     L('7'),     M(4, 430),  L('1'),     L('2'),     M(4, 43),
                L('4'),     M(4, 415),  L('1'),     L('5'),     L('0'),     L('3'),     L('0'),     L('2'),
                L('8'),     L('6'),     L('1'),     L('8'),     L('2'),     L('9'),     L('7'),     L('4'),
                L('5'),     L('5'),     L('5'),     L('7'),     L('0'),     L('6'),     L('7'),     L('4'),
                M(4, 310),  L('5'),     L('0'),     L('5'),     L('4'),     L('9'),     L('4'),     L('5'),
                L('8'),     M(4, 454),  L('9'),     M(4, 82),   L('5'),     L('6'),     M(4, 493),  L('7'),
                L('2'),     L('1'),     L('0'),     L('7'),     L('9'),     M(4, 346),  L('3'),     L('0'),
                M(4, 267),  L('3'),     L('2'),     L('1'),     L('1'),     L('6'),     L('5'),     L('3'),
                L('4'),     L('4'),     L('9'),     L('8'),     L('7'),     L('2'),     L('0'),     L('2'),
                L('7'),     M(4, 284),  L('0'),     L('2'),     L('3'),     L('6'),     L('4'),     M(4, 559),
                L('5'),     L('4'),     L('9'),     L('9'),     L('1'),     L('1'),     L('9'),     L('8'),
                M(4, 1049), L('4'),     M(4, 284),  L('5'),     L('3'),     L('5'),     L('6'),     L('6'),
                L('3'),     L('6'),     L('9'),     M(4, 1105), L('2'),     L('6'),     L('5'),     M(4, 741),
                L('7'),     L('8'),     L('6'),     L('2'),     L('5'),     L('5'),     L('1'),     M(4, 987),
                L('1'),     L('7'),     L('5'),     L('7'),     L('4'),     L('6'),     L('7'),     L('2'),
                L('8'),     L('9'),     L('0'),     L('9'),     L('7'),     L('7'),     L('7'),     L('7'),
                M(5, 1108), L('0'),     L('0'),     L('0'),     M(4, 1534), L('7'),     L('0'),     M(4, 1248),
                L('6'),     M(4, 1002), L('4'),     L('9'),     L('1'),     M(4, 1055), M(4, 664),  L('2'),
                L('1'),     L('4'),     L('7'),     L('7'),     L('2'),     L('3'),     L('5'),     L('0'),
                L('1'),     L('4'),     L('1'),     L('4'),     M(4, 1604), L('3'),     L('5'),     L('6'),
                M(4, 1200), L('1'),     L('6'),     L('1'),     L('3'),     L('6'),     L('1'),     L('1'),
                L('5'),     L('7'),     L('3'),     L('5'),     L('2'),     L('5'),     M(4, 1285), L('3'),
                L('4'),     M(4, 92),   L('1'),     L('8'),     M(4, 1148), L('8'),     L('4'),     M(4, 1512),
                L('3'),     L('3'),     L('2'),     L('3'),     L('9'),     L('0'),     L('7'),     L('3'),
                L('9'),     L('4'),     L('1'),     L('4'),     L('3'),     L('3'),     L('3'),     L('4'),
                L('5'),     L('4'),     L('7'),     L('7'),     L('6'),     L('2'),     L('4'),     M(4, 579),
                L('2'),     L('5'),     L('1'),     L('8'),     L('9'),     L('8'),     L('3'),     L('5'),
                L('6'),     L('9'),     L('4'),     L('8'),     L('5'),     L('5'),     L('6'),     L('2'),
                L('0'),     L('9'),     L('9'),     L('2'),     L('1'),     L('9'),     L('2'),     L('2'),
                L('2'),     L('1'),     L('8'),     L('4'),     L('2'),     L('7'),     M(4, 575),  L('2'),
                M(4, 187),  L('6'),     L('8'),     L('8'),     L('7'),     L('6'),     L('7'),     L('1'),
                L('7'),     L('9'),     L('0'),     M(4, 86),   L('0'),     M(5, 263),  L('6'),     L('6'),
                M(4, 1000), L('8'),     L('8'),     L('6'),     L('2'),     L('7'),     L('2'),     M(4, 1757),
                L('1'),     L('7'),     L('8'),     L('6'),     L('0'),     L('8'),     L('5'),     L('7'),
                M(4, 116),  L('3'),     M(5, 765),  L('7'),     L('9'),     L('7'),     L('6'),     L('6'),
                L('8'),     L('1'),     M(4, 702),  L('0'),     L('0'),     L('9'),     L('5'),     L('3'),
                L('8'),     L('8'),     M(4, 1593), L('3'),     M(4, 1702), L('0'),     L('6'),     L('8'),
                L('0'),     L('0'),     L('6'),     L('4'),     L('2'),     L('2'),     L('5'),     L('1'),
                L('2'),     L('5'),     L('2'),     M(4, 1404), L('7'),     L('3'),     L('9'),     L('2'),
                M(4, 664),  M(4, 1141), L('4'),     M(5, 1716), L('8'),     L('6'),     L('2'),     L('6'),
                L('9'),     L('4'),     L('5'),     M(4, 486),  L('4'),     L('1'),     L('9'),     L('6'),
                L('5'),     L('2'),     L('8'),     L('5'),     L('0'),     M(4, 154),  M(4, 925),  L('1'),
                L('8'),     L('6'),     L('3'),     M(4, 447),  L('4'),     M(5, 341),  L('2'),     L('0'),
                L('3'),     L('9'),     M(4, 1420), L('4'),     L('5'),     M(4, 701),  L('2'),     L('3'),
                L('7'),     M(4, 1069), L('6'),     M(4, 1297), L('5'),     L('6'),     M(4, 1593), L('7'),
                L('1'),     L('9'),     L('1'),     L('7'),     L('2'),     L('8'),     M(4, 370),  L('7'),
                L('6'),     L('4'),     L('6'),     L('5'),     L('7'),     L('5'),     L('7'),     L('3'),
                L('9'),     M(4, 258),  L('3'),     L('8'),     L('9'),     M(4, 1865), L('8'),     L('3'),
                L('2'),     L('6'),     L('4'),     L('5'),     L('9'),     L('9'),     L('5'),     L('8'),
                M(4, 1704), L('0'),     L('4'),     L('7'),     L('8'),     M(4, 479),  M(4, 809),  L('9'),
                M(4, 46),   L('6'),     L('4'),     L('0'),     L('7'),     L('8'),     L('9'),     L('5'),
                L('1'),     M(4, 143),  L('6'),     L('8'),     L('3'),     M(4, 304),  L('2'),     L('5'),
                L('9'),     L('5'),     L('7'),     L('0'),     M(4, 1129), L('8'),     L('2'),     L('2'),
                M(4, 713),  L('2'),     M(4, 1564), L('4'),     L('0'),     L('7'),     L('7'),     L('2'),
                L('6'),     L('7'),     L('1'),     L('9'),     L('4'),     L('7'),     L('8'),     M(4, 794),
                L('8'),     L('2'),     L('6'),     L('0'),     L('1'),     L('4'),     L('7'),     L('6'),
                L('9'),     L('9'),     L('0'),     L('9'),     M(4, 1257), L('0'),     L('1'),     L('3'),
                L('6'),     L('3'),     L('9'),     L('4'),     L('4'),     L('3'),     M(4, 640),  L('3'),
                L('0'),     M(4, 262),  L('2'),     L('0'),     L('3'),     L('4'),     L('9'),     L('6'),
                L('2'),     L('5'),     L('2'),     L('4'),     L('5'),     L('1'),     L('7'),     M(4, 950),
                L('9'),     L('6'),     L('5'),     L('1'),     L('4'),     L('3'),     L('1'),     L('4'),
                L('2'),     L('9'),     L('8'),     L('0'),     L('9'),     L('1'),     L('9'),     L('0'),
                L('6'),     L('5'),     L('9'),     L('2'),     M(4, 643),  L('7'),     L('2'),     L('2'),
                L('1'),     L('6'),     L('9'),     L('6'),     L('4'),     L('6'),     M(4, 1050), M(4, 123),
                L('5'),     M(4, 1295), L('4'),     M(5, 1382), L('8'),     M(4, 1370), L('9'),     L('7'),
                M(4, 1404), L('5'),     L('4'),     M(4, 1182), M(4, 575),  L('7'),     M(4, 1627), L('8'),
                L('4'),     L('6'),     L('8'),     L('1'),     L('3'),     M(4, 141),  L('6'),     L('8'),
                L('3'),     L('8'),     L('6'),     L('8'),     L('9'),     L('4'),     L('2'),     L('7'),
                L('7'),     L('4'),     L('1'),     L('5'),     L('5'),     L('9'),     L('9'),     L('1'),
                L('8'),     L('5'),     M(4, 91),   L('2'),     L('4'),     L('5'),     L('9'),     L('5'),
                L('3'),     L('9'),     L('5'),     L('9'),     L('4'),     L('3'),     L('1'),     M(4, 1464),
                L('7'),     M(4, 19),   L('6'),     L('8'),     L('0'),     L('8'),     L('4'),     L('5'),
                M(4, 744),  L('7'),     L('3'),     M(4, 2079), L('9'),     L('5'),     L('8'),     L('4'),
                L('8'),     L('6'),     L('5'),     L('3'),     L('8'),     M(4, 1769), L('6'),     L('2'),
                M(4, 243),  L('6'),     L('0'),     L('9'),     M(4, 1207), L('6'),     L('0'),     L('8'),
                L('0'),     L('5'),     L('1'),     L('2'),     L('4'),     L('3'),     L('8'),     L('8'),
                L('4'),     M(4, 315),  M(4, 12),   L('4'),     L('1'),     L('3'),     M(4, 784),  L('7'),
                L('6'),     L('2'),     L('7'),     L('8'),     M(4, 834),  L('7'),     L('1'),     L('5'),
                M(4, 1436), L('3'),     L('5'),     L('9'),     L('9'),     L('7'),     L('7'),     L('0'),
                L('0'),     L('1'),     L('2'),     L('9'),     M(4, 1139), L('8'),     L('9'),     L('4'),
                L('4'),     L('1'),     M(4, 632),  L('6'),     L('8'),     L('5'),     L('5'),     M(4, 96),
                L('4'),     L('0'),     L('6'),     L('3'),     M(4, 2279), L('2'),     L('0'),     L('7'),
                L('2'),     L('2'),     M(4, 345),  M(5, 516),  L('4'),     L('8'),     L('1'),     L('5'),
                L('8'),     M(4, 518),  M(4, 511),  M(4, 635),  M(4, 665),  L('3'),     L('9'),     L('4'),
                L('5'),     L('2'),     L('2'),     L('6'),     L('7'),     M(6, 1175), L('8'),     M(4, 1419),
                L('2'),     L('1'),     M(4, 747),  L('2'),     M(4, 904),  L('5'),     L('4'),     L('6'),
                L('6'),     L('6'),     M(4, 1308), L('2'),     L('3'),     L('9'),     L('8'),     L('6'),
                L('4'),     L('5'),     L('6'),     M(4, 1221), L('1'),     L('6'),     L('3'),     L('5'),
                M(5, 596),  M(4, 2066), L('7'),     M(4, 2222), L('9'),     L('8'),     M(4, 1119), L('9'),
                L('3'),     L('6'),     L('3'),     L('4'),     M(4, 1884), L('7'),     L('4'),     L('3'),
                L('2'),     L('4'),     M(4, 1148), L('1'),     L('5'),     L('0'),     L('7'),     L('6'),
                M(4, 1212), L('7'),     L('9'),     L('4'),     L('5'),     L('1'),     L('0'),     L('9'),
                M(4, 63),   L('0'),     L('9'),     L('4'),     L('0'),     M(4, 1703), L('8'),     L('8'),
                L('7'),     L('9'),     L('7'),     L('1'),     L('0'),     L('8'),     L('9'),     L('3'),
                M(4, 2289), L('6'),     L('9'),     L('1'),     L('3'),     L('6'),     L('8'),     L('6'),
                L('7'),     L('2'),     M(4, 604),  M(4, 511),  L('5'),     M(4, 1344), M(4, 1129), M(4, 2050),
                L('1'),     L('7'),     L('9'),     L('2'),     L('8'),     L('6'),     L('8'),     M(4, 2253),
                L('8'),     L('7'),     L('4'),     L('7'),     M(5, 1951), L('8'),     L('2'),     L('4'),
                M(4, 2427), L('8'),     M(4, 604),  L('7'),     L('1'),     L('4'),     L('9'),     L('0'),
                L('9'),     L('6'),     L('7'),     L('5'),     L('9'),     L('8'),     M(4, 1776), L('3'),
                L('6'),     L('5'),     M(4, 309),  L('8'),     L('1'),     M(4, 93),   M(4, 1862), M(4, 2359),
                L('6'),     L('8'),     L('2'),     L('9'),     M(4, 1407), L('8'),     L('7'),     L('2'),
                L('2'),     L('6'),     L('5'),     L('8'),     L('8'),     L('0'),     M(4, 1554), L('5'),
                M(4, 586),  L('4'),     L('2'),     L('7'),     L('0'),     L('4'),     L('7'),     L('7'),
                L('5'),     L('5'),     M(4, 2079), L('3'),     L('7'),     L('9'),     L('6'),     L('4'),
                L('1'),     L('4'),     L('5'),     L('1'),     L('5'),     L('2'),     M(4, 1534), L('2'),
                L('3'),     L('4'),     L('3'),     L('6'),     L('4'),     L('5'),     L('4'),     M(4, 1503),
                L('4'),     L('4'),     L('4'),     L('7'),     L('9'),     L('5'),     M(4, 61),   M(4, 1316),
                M(5, 2279), L('4'),     L('1'),     M(4, 1323), L('3'),     M(4, 773),  L('5'),     L('2'),
                L('3'),     L('1'),     M(5, 2114), L('1'),     L('6'),     L('6'),     L('1'),     M(4, 2227),
                L('5'),     L('9'),     L('6'),     L('9'),     L('5'),     L('3'),     L('6'),     L('2'),
                L('3'),     L('1'),     L('4'),     M(4, 1536), L('2'),     L('4'),     L('8'),     L('4'),
                L('9'),     L('3'),     L('7'),     L('1'),     L('8'),     L('7'),     L('1'),     L('1'),
                L('0'),     L('1'),     L('4'),     L('5'),     L('7'),     L('6'),     L('5'),     L('4'),
                M(4, 1890), L('0'),     L('2'),     L('7'),     L('9'),     L('9'),     L('3'),     L('4'),
                L('4'),     L('0'),     L('3'),     L('7'),     L('4'),     L('2'),     L('0'),     L('0'),
                L('7'),     M(4, 2368), L('7'),     L('8'),     L('5'),     L('3'),     L('9'),     L('0'),
                L('6'),     L('2'),     L('1'),     L('9'),     M(5, 666),  M(4, 838),  L('8'),     L('4'),
                L('7'),     M(5, 979),  L('8'),     L('3'),     L('3'),     L('2'),     L('1'),     L('4'),
                L('4'),     L('5'),     L('7'),     L('1'),     M(4, 645),  M(4, 1911), L('4'),     L('3'),
                L('5'),     L('0'),     M(4, 2345), M(4, 1129), L('5'),     L('3'),     L('1'),     L('9'),
                L('1'),     L('0'),     L('4'),     L('8'),     L('4'),     L('8'),     L('1'),     L('0'),
                L('0'),     L('5'),     L('3'),     L('7'),     L('0'),     L('6'),     M(4, 2237), M(5, 1438),
                M(5, 1922), L('1'),     M(4, 1370), L('7'),     M(4, 796),  L('5'),     M(4, 2029), M(4, 1037),
                L('6'),     L('3'),     M(5, 2013), L('4'),     M(4, 2418), M(5, 847),  M(5, 1014), L('8'),
                M(5, 1326), M(5, 2184), L('9'),     M(4, 392),  L('9'),     L('1'),     M(4, 2255), L('8'),
                L('1'),     L('4'),     L('6'),     L('7'),     L('5'),     L('1'),     M(4, 1580), L('1'),
                L('2'),     L('3'),     L('9'),     M(6, 426),  L('9'),     L('0'),     L('7'),     L('1'),
                L('8'),     L('6'),     L('4'),     L('9'),     L('4'),     L('2'),     L('3'),     L('1'),
                L('9'),     L('6'),     L('1'),     L('5'),     L('6'),     M(4, 493),  M(4, 1725), L('9'),
                L('5'),     M(4, 2343), M(4, 1130), M(4, 284),  L('6'),     L('0'),     L('3'),     L('8'),
                M(4, 2598), M(4, 368),  M(4, 901),  L('6'),     L('2'),     M(4, 1115), L('5'),     M(4, 2125),
                L('6'),     L('3'),     L('8'),     L('9'),     L('3'),     L('7'),     L('7'),     L('8'),
                L('7'),     M(4, 2246), M(4, 249),  L('9'),     L('7'),     L('9'),     L('2'),     L('0'),
                L('7'),     L('7'),     L('3'),     M(4, 1496), L('2'),     L('1'),     L('8'),     L('2'),
                L('5'),     L('6'),     M(4, 2016), L('6'),     L('6'),     M(4, 1751), L('4'),     L('2'),
                M(5, 1663), L('6'),     M(4, 1767), L('4'),     L('4'),     M(4, 37),   L('5'),     L('4'),
                L('9'),     L('2'),     L('0'),     L('2'),     L('6'),     L('0'),     L('5'),     M(4, 2740),
                M(5, 997),  L('2'),     L('0'),     L('1'),     L('4'),     L('9'),     M(4, 1235), L('8'),
                L('5'),     L('0'),     L('7'),     L('3'),     M(4, 1434), L('6'),     L('6'),     L('6'),
                L('0'),     M(4, 405),  L('2'),     L('4'),     L('3'),     L('4'),     L('0'),     M(4, 136),
                L('0'),     M(4, 1900), L('8'),     L('6'),     L('3'),     M(4, 2391), M(4, 2021), M(4, 1068),
                M(4, 373),  L('5'),     L('7'),     L('9'),     L('6'),     L('2'),     L('6'),     L('8'),
                L('5'),     L('6'),     M(4, 321),  L('5'),     L('0'),     L('8'),     M(4, 1316), L('5'),
                L('8'),     L('7'),     L('9'),     L('6'),     L('9'),     L('9'),     M(4, 1810), L('5'),
                L('7'),     L('4'),     M(4, 2585), L('8'),     L('4'),     L('0'),     M(4, 2228), L('1'),
                L('4'),     L('5'),     L('9'),     L('1'),     M(4, 1933), L('7'),     L('0'),     M(4, 565),
                L('0'),     L('1'),     M(4, 3048), L('1'),     L('2'),     M(4, 3189), L('0'),     M(4, 964),
                L('3'),     L('9'),     M(4, 2859), M(4, 275),  L('7'),     L('1'),     L('5'),     M(4, 945),
                L('4'),     L('2'),     L('0'),     M(5, 3059), L('9'),     M(4, 3011), L('0'),     L('7'),
                M(4, 834),  M(4, 1942), M(4, 2736), M(4, 3171), L('2'),     L('1'),     M(4, 2401), L('2'),
                L('5'),     L('1'),     M(4, 1404), M(4, 2373), L('9'),     L('2'),     M(4, 435),  L('8'),
                L('2'),     L('6'),     M(4, 2919), L('2'),     M(4, 633),  L('3'),     L('2'),     L('1'),
                L('5'),     L('7'),     L('9'),     L('1'),     L('9'),     L('8'),     L('4'),     L('1'),
                L('4'),     M(5, 2172), L('9'),     L('1'),     L('6'),     L('4'),     M(5, 1769), L('9'),
                M(5, 2905), M(4, 2268), L('7'),     L('2'),     L('2'),     M(4, 802),  L('5'),     M(4, 2213),
                M(4, 322),  L('9'),     L('1'),     L('0'),     M(4, 189),  M(4, 3164), L('5'),     L('2'),
                L('8'),     L('0'),     L('1'),     L('7'),     M(4, 562),  L('7'),     L('1'),     L('2'),
                M(4, 2325), L('8'),     L('3'),     L('2'),     M(4, 884),  L('1'),     M(4, 1418), L('0'),
                L('9'),     L('3'),     L('5'),     L('3'),     L('9'),     L('6'),     L('5'),     L('7'),
                M(4, 1612), L('1'),     L('0'),     L('8'),     L('3'),     M(4, 106),  L('5'),     L('1'),
                M(4, 1915), M(4, 3419), L('1'),     L('4'),     L('4'),     L('4'),     L('2'),     L('1'),
                L('0'),     L('0'),     M(4, 515),  L('0'),     L('3'),     M(4, 413),  L('1'),     L('1'),
                L('0'),     L('3'),     M(4, 3202), M(4, 10),   M(4, 39),   M(6, 1539), L('5'),     L('1'),
                L('6'),     M(4, 1498), M(5, 2180), M(4, 2347), L('5'),     M(5, 3139), L('8'),     L('5'),
                L('1'),     L('7'),     L('1'),     L('4'),     L('3'),     L('7'),     M(4, 1542), M(4, 110),
                L('1'),     L('5'),     L('5'),     L('6'),     L('5'),     L('0'),     L('8'),     L('8'),
                M(4, 954),  L('9'),     L('8'),     L('9'),     L('8'),     L('5'),     L('9'),     L('9'),
                L('8'),     L('2'),     L('3'),     L('8'),     M(4, 464),  M(4, 2491), L('3'),     M(4, 365),
                M(4, 1087), M(4, 2500), L('8'),     M(5, 3590), L('3'),     L('2'),     M(4, 264),  L('5'),
                M(4, 774),  L('3'),     M(4, 459),  L('9'),     M(4, 1052), L('9'),     L('8'),     M(4, 2174),
                L('4'),     M(4, 3257), L('7'),     M(4, 1612), L('0'),     L('7'),     M(4, 230),  L('4'),
                L('8'),     L('1'),     L('4'),     L('1'),     M(4, 1338), L('8'),     L('5'),     L('9'),
                L('4'),     L('6'),     L('1'),     M(4, 3018), L('8'),     L('0'),
            },
        },
        HuffTest{
            .input = "huffman-rand-1k.input",
            .want = "huffman-rand-1k.{s}.expect",
            .want_no_input = "huffman-rand-1k.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L(0xf8), L(0x8b), L(0x96), L(0x76), L(0x48), L(0xd),  L(0x85), L(0x94), L(0x25), L(0x80), L(0xaf), L(0xc2), L(0xfe), L(0x8d),
                L(0xe8), L(0x20), L(0xeb), L(0x17), L(0x86), L(0xc9), L(0xb7), L(0xc5), L(0xde), L(0x6),  L(0xea), L(0x7d), L(0x18), L(0x8b),
                L(0xe7), L(0x3e), L(0x7),  L(0xda), L(0xdf), L(0xff), L(0x6c), L(0x73), L(0xde), L(0xcc), L(0xe7), L(0x6d), L(0x8d), L(0x4),
                L(0x19), L(0x49), L(0x7f), L(0x47), L(0x1f), L(0x48), L(0x15), L(0xb0), L(0xe8), L(0x9e), L(0xf2), L(0x31), L(0x59), L(0xde),
                L(0x34), L(0xb4), L(0x5b), L(0xe5), L(0xe0), L(0x9),  L(0x11), L(0x30), L(0xc2), L(0x88), L(0x5b), L(0x7c), L(0x5d), L(0x14),
                L(0x13), L(0x6f), L(0x23), L(0xa9), L(0xd),  L(0xbc), L(0x2d), L(0x23), L(0xbe), L(0xd9), L(0xed), L(0x75), L(0x4),  L(0x6c),
                L(0x99), L(0xdf), L(0xfd), L(0x70), L(0x66), L(0xe6), L(0xee), L(0xd9), L(0xb1), L(0x9e), L(0x6e), L(0x83), L(0x59), L(0xd5),
                L(0xd4), L(0x80), L(0x59), L(0x98), L(0x77), L(0x89), L(0x43), L(0x38), L(0xc9), L(0xaf), L(0x30), L(0x32), L(0x9a), L(0x20),
                L(0x1b), L(0x46), L(0x3d), L(0x67), L(0x6e), L(0xd7), L(0x72), L(0x9e), L(0x4e), L(0x21), L(0x4f), L(0xc6), L(0xe0), L(0xd4),
                L(0x7b), L(0x4),  L(0x8d), L(0xa5), L(0x3),  L(0xf6), L(0x5),  L(0x9b), L(0x6b), L(0xdc), L(0x2a), L(0x93), L(0x77), L(0x28),
                L(0xfd), L(0xb4), L(0x62), L(0xda), L(0x20), L(0xe7), L(0x1f), L(0xab), L(0x6b), L(0x51), L(0x43), L(0x39), L(0x2f), L(0xa0),
                L(0x92), L(0x1),  L(0x6c), L(0x75), L(0x3e), L(0xf4), L(0x35), L(0xfd), L(0x43), L(0x2e), L(0xf7), L(0xa4), L(0x75), L(0xda),
                L(0xea), L(0x9b), L(0xa),  L(0x64), L(0xb),  L(0xe0), L(0x23), L(0x29), L(0xbd), L(0xf7), L(0xe7), L(0x83), L(0x3c), L(0xfb),
                L(0xdf), L(0xb3), L(0xae), L(0x4f), L(0xa4), L(0x47), L(0x55), L(0x99), L(0xde), L(0x2f), L(0x96), L(0x6e), L(0x1c), L(0x43),
                L(0x4c), L(0x87), L(0xe2), L(0x7c), L(0xd9), L(0x5f), L(0x4c), L(0x7c), L(0xe8), L(0x90), L(0x3),  L(0xdb), L(0x30), L(0x95),
                L(0xd6), L(0x22), L(0xc),  L(0x47), L(0xb8), L(0x4d), L(0x6b), L(0xbd), L(0x24), L(0x11), L(0xab), L(0x2c), L(0xd7), L(0xbe),
                L(0x6e), L(0x7a), L(0xd6), L(0x8),  L(0xa3), L(0x98), L(0xd8), L(0xdd), L(0x15), L(0x6a), L(0xfa), L(0x93), L(0x30), L(0x1),
                L(0x25), L(0x1d), L(0xa2), L(0x74), L(0x86), L(0x4b), L(0x6a), L(0x95), L(0xe8), L(0xe1), L(0x4e), L(0xe),  L(0x76), L(0xb9),
                L(0x49), L(0xa9), L(0x5f), L(0xa0), L(0xa6), L(0x63), L(0x3c), L(0x7e), L(0x7e), L(0x20), L(0x13), L(0x4f), L(0xbb), L(0x66),
                L(0x92), L(0xb8), L(0x2e), L(0xa4), L(0xfa), L(0x48), L(0xcb), L(0xae), L(0xb9), L(0x3c), L(0xaf), L(0xd3), L(0x1f), L(0xe1),
                L(0xd5), L(0x8d), L(0x42), L(0x6d), L(0xf0), L(0xfc), L(0x8c), L(0xc),  L(0x0),  L(0xde), L(0x40), L(0xab), L(0x8b), L(0x47),
                L(0x97), L(0x4e), L(0xa8), L(0xcf), L(0x8e), L(0xdb), L(0xa6), L(0x8b), L(0x20), L(0x9),  L(0x84), L(0x7a), L(0x66), L(0xe5),
                L(0x98), L(0x29), L(0x2),  L(0x95), L(0xe6), L(0x38), L(0x32), L(0x60), L(0x3),  L(0xe3), L(0x9a), L(0x1e), L(0x54), L(0xe8),
                L(0x63), L(0x80), L(0x48), L(0x9c), L(0xe7), L(0x63), L(0x33), L(0x6e), L(0xa0), L(0x65), L(0x83), L(0xfa), L(0xc6), L(0xba),
                L(0x7a), L(0x43), L(0x71), L(0x5),  L(0xf5), L(0x68), L(0x69), L(0x85), L(0x9c), L(0xba), L(0x45), L(0xcd), L(0x6b), L(0xb),
                L(0x19), L(0xd1), L(0xbb), L(0x7f), L(0x70), L(0x85), L(0x92), L(0xd1), L(0xb4), L(0x64), L(0x82), L(0xb1), L(0xe4), L(0x62),
                L(0xc5), L(0x3c), L(0x46), L(0x1f), L(0x92), L(0x31), L(0x1c), L(0x4e), L(0x41), L(0x77), L(0xf7), L(0xe7), L(0x87), L(0xa2),
                L(0xf),  L(0x6e), L(0xe8), L(0x92), L(0x3),  L(0x6b), L(0xa),  L(0xe7), L(0xa9), L(0x3b), L(0x11), L(0xda), L(0x66), L(0x8a),
                L(0x29), L(0xda), L(0x79), L(0xe1), L(0x64), L(0x8d), L(0xe3), L(0x54), L(0xd4), L(0xf5), L(0xef), L(0x64), L(0x87), L(0x3b),
                L(0xf4), L(0xc2), L(0xf4), L(0x71), L(0x13), L(0xa9), L(0xe9), L(0xe0), L(0xa2), L(0x6),  L(0x14), L(0xab), L(0x5d), L(0xa7),
                L(0x96), L(0x0),  L(0xd6), L(0xc3), L(0xcc), L(0x57), L(0xed), L(0x39), L(0x6a), L(0x25), L(0xcd), L(0x76), L(0xea), L(0xba),
                L(0x3a), L(0xf2), L(0xa1), L(0x95), L(0x5d), L(0xe5), L(0x71), L(0xcf), L(0x9c), L(0x62), L(0x9e), L(0x6a), L(0xfa), L(0xd5),
                L(0x31), L(0xd1), L(0xa8), L(0x66), L(0x30), L(0x33), L(0xaa), L(0x51), L(0x17), L(0x13), L(0x82), L(0x99), L(0xc8), L(0x14),
                L(0x60), L(0x9f), L(0x4d), L(0x32), L(0x6d), L(0xda), L(0x19), L(0x26), L(0x21), L(0xdc), L(0x7e), L(0x2e), L(0x25), L(0x67),
                L(0x72), L(0xca), L(0xf),  L(0x92), L(0xcd), L(0xf6), L(0xd6), L(0xcb), L(0x97), L(0x8a), L(0x33), L(0x58), L(0x73), L(0x70),
                L(0x91), L(0x1d), L(0xbf), L(0x28), L(0x23), L(0xa3), L(0xc),  L(0xf1), L(0x83), L(0xc3), L(0xc8), L(0x56), L(0x77), L(0x68),
                L(0xe3), L(0x82), L(0xba), L(0xb9), L(0x57), L(0x56), L(0x57), L(0x9c), L(0xc3), L(0xd6), L(0x14), L(0x5),  L(0x3c), L(0xb1),
                L(0xaf), L(0x93), L(0xc8), L(0x8a), L(0x57), L(0x7f), L(0x53), L(0xfa), L(0x2f), L(0xaa), L(0x6e), L(0x66), L(0x83), L(0xfa),
                L(0x33), L(0xd1), L(0x21), L(0xab), L(0x1b), L(0x71), L(0xb4), L(0x7c), L(0xda), L(0xfd), L(0xfb), L(0x7f), L(0x20), L(0xab),
                L(0x5e), L(0xd5), L(0xca), L(0xfd), L(0xdd), L(0xe0), L(0xee), L(0xda), L(0xba), L(0xa8), L(0x27), L(0x99), L(0x97), L(0x69),
                L(0xc1), L(0x3c), L(0x82), L(0x8c), L(0xa),  L(0x5c), L(0x2d), L(0x5b), L(0x88), L(0x3e), L(0x34), L(0x35), L(0x86), L(0x37),
                L(0x46), L(0x79), L(0xe1), L(0xaa), L(0x19), L(0xfb), L(0xaa), L(0xde), L(0x15), L(0x9),  L(0xd),  L(0x1a), L(0x57), L(0xff),
                L(0xb5), L(0xf),  L(0xf3), L(0x2b), L(0x5a), L(0x6a), L(0x4d), L(0x19), L(0x77), L(0x71), L(0x45), L(0xdf), L(0x4f), L(0xb3),
                L(0xec), L(0xf1), L(0xeb), L(0x18), L(0x53), L(0x3e), L(0x3b), L(0x47), L(0x8),  L(0x9a), L(0x73), L(0xa0), L(0x5c), L(0x8c),
                L(0x5f), L(0xeb), L(0xf),  L(0x3a), L(0xc2), L(0x43), L(0x67), L(0xb4), L(0x66), L(0x67), L(0x80), L(0x58), L(0xe),  L(0xc1),
                L(0xec), L(0x40), L(0xd4), L(0x22), L(0x94), L(0xca), L(0xf9), L(0xe8), L(0x92), L(0xe4), L(0x69), L(0x38), L(0xbe), L(0x67),
                L(0x64), L(0xca), L(0x50), L(0xc7), L(0x6),  L(0x67), L(0x42), L(0x6e), L(0xa3), L(0xf0), L(0xb7), L(0x6c), L(0xf2), L(0xe8),
                L(0x5f), L(0xb1), L(0xaf), L(0xe7), L(0xdb), L(0xbb), L(0x77), L(0xb5), L(0xf8), L(0xcb), L(0x8),  L(0xc4), L(0x75), L(0x7e),
                L(0xc0), L(0xf9), L(0x1c), L(0x7f), L(0x3c), L(0x89), L(0x2f), L(0xd2), L(0x58), L(0x3a), L(0xe2), L(0xf8), L(0x91), L(0xb6),
                L(0x7b), L(0x24), L(0x27), L(0xe9), L(0xae), L(0x84), L(0x8b), L(0xde), L(0x74), L(0xac), L(0xfd), L(0xd9), L(0xb7), L(0x69),
                L(0x2a), L(0xec), L(0x32), L(0x6f), L(0xf0), L(0x92), L(0x84), L(0xf1), L(0x40), L(0xc),  L(0x8a), L(0xbc), L(0x39), L(0x6e),
                L(0x2e), L(0x73), L(0xd4), L(0x6e), L(0x8a), L(0x74), L(0x2a), L(0xdc), L(0x60), L(0x1f), L(0xa3), L(0x7),  L(0xde), L(0x75),
                L(0x8b), L(0x74), L(0xc8), L(0xfe), L(0x63), L(0x75), L(0xf6), L(0x3d), L(0x63), L(0xac), L(0x33), L(0x89), L(0xc3), L(0xf0),
                L(0xf8), L(0x2d), L(0x6b), L(0xb4), L(0x9e), L(0x74), L(0x8b), L(0x5c), L(0x33), L(0xb4), L(0xca), L(0xa8), L(0xe4), L(0x99),
                L(0xb6), L(0x90), L(0xa1), L(0xef), L(0xf),  L(0xd3), L(0x61), L(0xb2), L(0xc6), L(0x1a), L(0x94), L(0x7c), L(0x44), L(0x55),
                L(0xf4), L(0x45), L(0xff), L(0x9e), L(0xa5), L(0x5a), L(0xc6), L(0xa0), L(0xe8), L(0x2a), L(0xc1), L(0x8d), L(0x6f), L(0x34),
                L(0x11), L(0xb9), L(0xbe), L(0x4e), L(0xd9), L(0x87), L(0x97), L(0x73), L(0xcf), L(0x3d), L(0x23), L(0xae), L(0xd5), L(0x1a),
                L(0x5e), L(0xae), L(0x5d), L(0x6a), L(0x3),  L(0xf9), L(0x22), L(0xd),  L(0x10), L(0xd9), L(0x47), L(0x69), L(0x15), L(0x3f),
                L(0xee), L(0x52), L(0xa3), L(0x8),  L(0xd2), L(0x3c), L(0x51), L(0xf4), L(0xf8), L(0x9d), L(0xe4), L(0x98), L(0x89), L(0xc8),
                L(0x67), L(0x39), L(0xd5), L(0x5e), L(0x35), L(0x78), L(0x27), L(0xe8), L(0x3c), L(0x80), L(0xae), L(0x79), L(0x71), L(0xd2),
                L(0x93), L(0xf4), L(0xaa), L(0x51), L(0x12), L(0x1c), L(0x4b), L(0x1b), L(0xe5), L(0x6e), L(0x15), L(0x6f), L(0xe4), L(0xbb),
                L(0x51), L(0x9b), L(0x45), L(0x9f), L(0xf9), L(0xc4), L(0x8c), L(0x2a), L(0xfb), L(0x1a), L(0xdf), L(0x55), L(0xd3), L(0x48),
                L(0x93), L(0x27), L(0x1),  L(0x26), L(0xc2), L(0x6b), L(0x55), L(0x6d), L(0xa2), L(0xfb), L(0x84), L(0x8b), L(0xc9), L(0x9e),
                L(0x28), L(0xc2), L(0xef), L(0x1a), L(0x24), L(0xec), L(0x9b), L(0xae), L(0xbd), L(0x60), L(0xe9), L(0x15), L(0x35), L(0xee),
                L(0x42), L(0xa4), L(0x33), L(0x5b), L(0xfa), L(0xf),  L(0xb6), L(0xf7), L(0x1),  L(0xa6), L(0x2),  L(0x4c), L(0xca), L(0x90),
                L(0x58), L(0x3a), L(0x96), L(0x41), L(0xe7), L(0xcb), L(0x9),  L(0x8c), L(0xdb), L(0x85), L(0x4d), L(0xa8), L(0x89), L(0xf3),
                L(0xb5), L(0x8e), L(0xfd), L(0x75), L(0x5b), L(0x4f), L(0xed), L(0xde), L(0x3f), L(0xeb), L(0x38), L(0xa3), L(0xbe), L(0xb0),
                L(0x73), L(0xfc), L(0xb8), L(0x54), L(0xf7), L(0x4c), L(0x30), L(0x67), L(0x2e), L(0x38), L(0xa2), L(0x54), L(0x18), L(0xba),
                L(0x8),  L(0xbf), L(0xf2), L(0x39), L(0xd5), L(0xfe), L(0xa5), L(0x41), L(0xc6), L(0x66), L(0x66), L(0xba), L(0x81), L(0xef),
                L(0x67), L(0xe4), L(0xe6), L(0x3c), L(0xc),  L(0xca), L(0xa4), L(0xa),  L(0x79), L(0xb3), L(0x57), L(0x8b), L(0x8a), L(0x75),
                L(0x98), L(0x18), L(0x42), L(0x2f), L(0x29), L(0xa3), L(0x82), L(0xef), L(0x9f), L(0x86), L(0x6),  L(0x23), L(0xe1), L(0x75),
                L(0xfa), L(0x8),  L(0xb1), L(0xde), L(0x17), L(0x4a),
            },
        },
        HuffTest{
            .input = "huffman-rand-limit.input",
            .want = "huffman-rand-limit.{s}.expect",
            .want_no_input = "huffman-rand-limit.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L(0x61), M(74, 1), L(0xa),  L(0xf8), L(0x8b), L(0x96), L(0x76), L(0x48), L(0xa),  L(0x85), L(0x94), L(0x25), L(0x80),
                L(0xaf), L(0xc2),  L(0xfe), L(0x8d), L(0xe8), L(0x20), L(0xeb), L(0x17), L(0x86), L(0xc9), L(0xb7), L(0xc5), L(0xde),
                L(0x6),  L(0xea),  L(0x7d), L(0x18), L(0x8b), L(0xe7), L(0x3e), L(0x7),  L(0xda), L(0xdf), L(0xff), L(0x6c), L(0x73),
                L(0xde), L(0xcc),  L(0xe7), L(0x6d), L(0x8d), L(0x4),  L(0x19), L(0x49), L(0x7f), L(0x47), L(0x1f), L(0x48), L(0x15),
                L(0xb0), L(0xe8),  L(0x9e), L(0xf2), L(0x31), L(0x59), L(0xde), L(0x34), L(0xb4), L(0x5b), L(0xe5), L(0xe0), L(0x9),
                L(0x11), L(0x30),  L(0xc2), L(0x88), L(0x5b), L(0x7c), L(0x5d), L(0x14), L(0x13), L(0x6f), L(0x23), L(0xa9), L(0xa),
                L(0xbc), L(0x2d),  L(0x23), L(0xbe), L(0xd9), L(0xed), L(0x75), L(0x4),  L(0x6c), L(0x99), L(0xdf), L(0xfd), L(0x70),
                L(0x66), L(0xe6),  L(0xee), L(0xd9), L(0xb1), L(0x9e), L(0x6e), L(0x83), L(0x59), L(0xd5), L(0xd4), L(0x80), L(0x59),
                L(0x98), L(0x77),  L(0x89), L(0x43), L(0x38), L(0xc9), L(0xaf), L(0x30), L(0x32), L(0x9a), L(0x20), L(0x1b), L(0x46),
                L(0x3d), L(0x67),  L(0x6e), L(0xd7), L(0x72), L(0x9e), L(0x4e), L(0x21), L(0x4f), L(0xc6), L(0xe0), L(0xd4), L(0x7b),
                L(0x4),  L(0x8d),  L(0xa5), L(0x3),  L(0xf6), L(0x5),  L(0x9b), L(0x6b), L(0xdc), L(0x2a), L(0x93), L(0x77), L(0x28),
                L(0xfd), L(0xb4),  L(0x62), L(0xda), L(0x20), L(0xe7), L(0x1f), L(0xab), L(0x6b), L(0x51), L(0x43), L(0x39), L(0x2f),
                L(0xa0), L(0x92),  L(0x1),  L(0x6c), L(0x75), L(0x3e), L(0xf4), L(0x35), L(0xfd), L(0x43), L(0x2e), L(0xf7), L(0xa4),
                L(0x75), L(0xda),  L(0xea), L(0x9b), L(0xa),
            },
        },
        HuffTest{
            .input = "huffman-shifts.input",
            .want = "huffman-shifts.{s}.expect",
            .want_no_input = "huffman-shifts.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L('1'),    L('0'),    M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2),
                M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2),
                M(258, 2), M(76, 2),  L(0xd),    L(0xa),    L('2'),    L('3'),    M(258, 2), M(258, 2),
                M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(258, 2), M(256, 2),
            },
        },
        HuffTest{
            .input = "huffman-text-shift.input",
            .want = "huffman-text-shift.{s}.expect",
            .want_no_input = "huffman-text-shift.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L('/'),   L('/'), L('C'),   L('o'), L('p'),   L('y'),   L('r'),   L('i'),
                L('g'),   L('h'), L('t'),   L('2'), L('0'),   L('0'),   L('9'),   L('T'),
                L('h'),   L('G'), L('o'),   L('A'), L('u'),   L('t'),   L('h'),   L('o'),
                L('r'),   L('.'), L('A'),   L('l'), L('l'),   M(5, 23), L('r'),   L('r'),
                L('v'),   L('d'), L('.'),   L(0xd), L(0xa),   L('/'),   L('/'),   L('U'),
                L('o'),   L('f'), L('t'),   L('h'), L('i'),   L('o'),   L('u'),   L('r'),
                L('c'),   L('c'), L('o'),   L('d'), L('i'),   L('g'),   L('o'),   L('v'),
                L('r'),   L('n'), L('d'),   L('b'), L('y'),   L('B'),   L('S'),   L('D'),
                L('-'),   L('t'), L('y'),   L('l'), M(4, 33), L('l'),   L('i'),   L('c'),
                L('n'),   L('t'), L('h'),   L('t'), L('c'),   L('n'),   L('b'),   L('f'),
                L('o'),   L('u'), L('n'),   L('d'), L('i'),   L('n'),   L('t'),   L('h'),
                L('L'),   L('I'), L('C'),   L('E'), L('N'),   L('S'),   L('E'),   L('f'),
                L('i'),   L('l'), L('.'),   L(0xd), L(0xa),   L(0xd),   L(0xa),   L('p'),
                L('c'),   L('k'), L('g'),   L('m'), L('i'),   L('n'),   M(4, 11), L('i'),
                L('m'),   L('p'), L('o'),   L('r'), L('t'),   L('"'),   L('o'),   L('"'),
                M(4, 13), L('f'), L('u'),   L('n'), L('c'),   L('m'),   L('i'),   L('n'),
                L('('),   L(')'), L('{'),   L(0xd), L(0xa),   L(0x9),   L('v'),   L('r'),
                L('b'),   L('='), L('m'),   L('k'), L('('),   L('['),   L(']'),   L('b'),
                L('y'),   L('t'), L(','),   L('6'), L('5'),   L('5'),   L('3'),   L('5'),
                L(')'),   L(0xd), L(0xa),   L(0x9), L('f'),   L(','),   L('_'),   L(':'),
                L('='),   L('o'), L('.'),   L('C'), L('r'),   L('t'),   L('('),   L('"'),
                L('h'),   L('u'), L('f'),   L('f'), L('m'),   L('n'),   L('-'),   L('n'),
                L('u'),   L('l'), L('l'),   L('-'), L('m'),   L('x'),   L('.'),   L('i'),
                L('n'),   L('"'), M(5, 34), L('.'), L('W'),   L('r'),   L('i'),   L('t'),
                L('('),   L('b'), L(')'),   L(0xd), L(0xa),   L('}'),   L(0xd),   L(0xa),
                L('A'),   L('B'), L('C'),   L('D'), L('E'),   L('F'),   L('G'),   L('H'),
                L('I'),   L('J'), L('K'),   L('L'), L('M'),   L('N'),   L('O'),   L('P'),
                L('Q'),   L('R'), L('S'),   L('T'), L('U'),   L('V'),   L('X'),   L('x'),
                L('y'),   L('z'), L('!'),   L('"'), L('#'),   L(0xc2),  L(0xa4),  L('%'),
                L('&'),   L('/'), L('?'),   L('"'),
            },
        },
        HuffTest{
            .input = "huffman-text.input",
            .want = "huffman-text.{s}.expect",
            .want_no_input = "huffman-text.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L('/'),    L('/'),    L(' '),   L('z'),    L('i'), L('g'), L(' '), L('v'),
                L('0'),    L('.'),    L('1'),   L('0'),    L('.'), L('0'), L(0xa), L('/'),
                L('/'),    L(' '),    L('c'),   L('r'),    L('e'), L('a'), L('t'), L('e'),
                L(' '),    L('a'),    L(' '),   L('f'),    L('i'), L('l'), L('e'), M(4, 5),
                L('l'),    L('e'),    L('d'),   L(' '),    L('w'), L('i'), L('t'), L('h'),
                L(' '),    L('0'),    L('x'),   L('0'),    L('0'), L(0xa), L('c'), L('o'),
                L('n'),    L('s'),    L('t'),   L(' '),    L('s'), L('t'), L('d'), L(' '),
                L('='),    L(' '),    L('@'),   L('i'),    L('m'), L('p'), L('o'), L('r'),
                L('t'),    L('('),    L('"'),   L('s'),    L('t'), L('d'), L('"'), L(')'),
                L(';'),    L(0xa),    L(0xa),   L('p'),    L('u'), L('b'), L(' '), L('f'),
                L('n'),    L(' '),    L('m'),   L('a'),    L('i'), L('n'), L('('), L(')'),
                L(' '),    L('!'),    L('v'),   L('o'),    L('i'), L('d'), L(' '), L('{'),
                L(0xa),    L(' '),    L(' '),   L(' '),    L(' '), L('v'), L('a'), L('r'),
                L(' '),    L('b'),    L(' '),   L('='),    L(' '), L('['), L('1'), L(']'),
                L('u'),    L('8'),    L('{'),   L('0'),    L('}'), L(' '), L('*'), L('*'),
                L(' '),    L('6'),    L('5'),   L('5'),    L('3'), L('5'), L(';'), M(5, 31),
                M(6, 86),  L('f'),    L(' '),   L('='),    L(' '), L('t'), L('r'), L('y'),
                M(4, 94),  L('.'),    L('f'),   L('s'),    L('.'), L('c'), L('w'), L('d'),
                L('('),    L(')'),    L('.'),   M(6, 144), L('F'), L('i'), L('l'), L('e'),
                L('('),    M(5, 43),  M(4, 1),  L('"'),    L('h'), L('u'), L('f'), L('f'),
                L('m'),    L('a'),    L('n'),   L('-'),    L('n'), L('u'), L('l'), L('l'),
                L('-'),    L('m'),    L('a'),   L('x'),    L('.'), L('i'), L('n'), L('"'),
                L(','),    M(9, 31),  L('.'),   L('{'),    L(' '), L('.'), L('r'), L('e'),
                L('a'),    L('d'),    M(5, 79), L('u'),    L('e'), L(' '), L('}'), M(6, 27),
                L(')'),    M(6, 108), L('d'),   L('e'),    L('f'), L('e'), L('r'), L(' '),
                L('f'),    L('.'),    L('c'),   L('l'),    L('o'), L('s'), L('e'), L('('),
                M(4, 183), M(4, 22),  L('_'),   M(7, 124), L('f'), L('.'), L('w'), L('r'),
                L('i'),    L('t'),    L('e'),   L('A'),    L('l'), L('l'), L('('), L('b'),
                L('['),    L('0'),    L('.'),   L('.'),    L(']'), L(')'), L(';'), L(0xa),
                L('}'),    L(0xa),
            },
        },
        HuffTest{
            .input = "huffman-zero.input",
            .want = "huffman-zero.{s}.expect",
            .want_no_input = "huffman-zero.{s}.expect-noinput",
            .tokens = &[_]token.Token{ 0x30, ml, 0x4b800000 },
        },
        HuffTest{
            .input = "",
            .want = "",
            .want_no_input = "null-long-match.{s}.expect-noinput",
            .tokens = &[_]token.Token{
                L(0x0), ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, ml,      ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml, ml,
                ml,     ml, ml, M(8, 1),
            },
        },
    };
};

const TestType = enum {
    write_block,
    write_dyn_block, // write dynamic block
    write_huffman_block,

    fn to_s(self: TestType) []const u8 {
        return switch (self) {
            .write_block => "wb",
            .write_dyn_block => "dyn",
            .write_huffman_block => "huff",
        };
    }
};

test "writeBlock" {
    @setEvalBranchQuota(10000);
    // tests if the writeBlock encoding has changed.

    const ttype: TestType = .write_block;
    try testBlock(writeBlockTests[0], ttype);
    try testBlock(writeBlockTests[1], ttype);
    try testBlock(writeBlockTests[2], ttype);
    try testBlock(writeBlockTests[3], ttype);
    try testBlock(writeBlockTests[4], ttype);
    try testBlock(writeBlockTests[5], ttype);
    try testBlock(writeBlockTests[6], ttype);
    try testBlock(writeBlockTests[7], ttype);
    try testBlock(writeBlockTests[8], ttype);
}

test "writeBlockDynamic" {
    @setEvalBranchQuota(10000);
    // tests if the writeBlockDynamic encoding has changed.

    const ttype: TestType = .write_dyn_block;
    try testBlock(writeBlockTests[0], ttype);
    try testBlock(writeBlockTests[1], ttype);
    try testBlock(writeBlockTests[2], ttype);
    try testBlock(writeBlockTests[3], ttype);
    try testBlock(writeBlockTests[4], ttype);
    try testBlock(writeBlockTests[5], ttype);
    try testBlock(writeBlockTests[6], ttype);
    try testBlock(writeBlockTests[7], ttype);
    try testBlock(writeBlockTests[8], ttype);
}

// testBlock tests a block against its references,
// or regenerate the references, if "-update" flag is set.
fn testBlock(comptime ht: HuffTest, comptime ttype: TestType) !void {
    if (ht.input.len != 0 and ht.want.len != 0) {
        const want_name = comptime fmt.comptimePrint(ht.want, .{ttype.to_s()});
        const input = @embedFile("testdata/" ++ ht.input);
        const want = @embedFile("testdata/" ++ want_name);

        var buf = ArrayList(u8).init(testing.allocator);
        var bw = huffmanBitWriter(buf.writer());
        try writeToType(ttype, &bw, ht.tokens, input);

        var got = buf.items;
        try testing.expectEqualSlices(u8, want, got); // expect writeBlock to yield expected result

        // Test if the writer produces the same output after reset.
        buf.deinit();
        buf = ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        bw.reset(buf.writer());

        try writeToType(ttype, &bw, ht.tokens, input);
        try bw.flush();
        got = buf.items;
        try testing.expectEqualSlices(u8, want, got); // expect writeBlock to yield expected result
        try testWriterEOF(.write_block, ht.tokens, input);
    }

    const want_name_no_input = comptime fmt.comptimePrint(ht.want_no_input, .{ttype.to_s()});
    const want_ni = @embedFile("testdata/" ++ want_name_no_input);

    var buf = ArrayList(u8).init(testing.allocator);
    var bw = huffmanBitWriter(buf.writer());

    try writeToType(ttype, &bw, ht.tokens, null);

    var got = buf.items;
    try testing.expectEqualSlices(u8, want_ni, got); // expect writeBlock to yield expected result
    try expect(got[0] & 1 != 1); // expect no EOF

    // Test if the writer produces the same output after reset.
    buf.deinit();
    buf = ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    bw.reset(buf.writer());

    try writeToType(ttype, &bw, ht.tokens, null);
    try bw.flush();
    got = buf.items;

    try testing.expectEqualSlices(u8, want_ni, got); // expect writeBlock to yield expected result
    try testWriterEOF(.write_block, ht.tokens, &[0]u8{});
}

fn writeToType(ttype: TestType, bw: anytype, tok: []const token.Token, input: ?[]const u8) !void {
    switch (ttype) {
        .write_block => try bw.writeBlock(tok, false, input),
        .write_dyn_block => try bw.writeBlockDynamic(tok, false, input),
        else => unreachable,
    }
    try bw.flush();
}

// Tests if the written block contains an EOF marker.
fn testWriterEOF(ttype: TestType, ht_tokens: []const token.Token, input: []const u8) !void {
    var buf = ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    var bw = huffmanBitWriter(buf.writer());

    switch (ttype) {
        .write_block => try bw.writeBlock(ht_tokens, true, input),
        .write_dyn_block => try bw.writeBlockDynamic(ht_tokens, true, input),
        .write_huffman_block => try bw.writeBlockHuff(true, input),
    }

    try bw.flush();

    const b = buf.items;
    try expect(b.len > 0);
    try expect(b[0] & 1 == 1);
}
