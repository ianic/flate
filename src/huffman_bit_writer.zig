const std = @import("std");
const io = std.io;

const hc = @import("huffman_encoder.zig");
const Token = @import("Token.zig");
const consts = @import("consts.zig");
const codegen_order = consts.huffman.codegen_order;
const codegen_code_count = consts.huffman.codegen_code_count;

const bad_code = 255;

fn BitWriter(comptime WriterType: type) type {
    // buffer_flush_size indicates the buffer size
    // after which bytes are flushed to the writer.
    // Should preferably be a multiple of 6, since
    // we accumulate 6 bytes between writes to the buffer.
    const buffer_flush_size = 240;

    // buffer_size is the actual output byte buffer size.
    // It must have additional headroom for a flush
    // which can contain up to 8 bytes.
    const buffer_size = buffer_flush_size + 8;

    return struct {
        // writer is the underlying writer.
        // Do not use it directly; use the write method, which ensures
        // that Write errors are sticky.
        inner_writer: WriterType,
        bytes_written: usize = 0,

        // Data waiting to be written is bytes[0 .. nbytes]
        // and then the low nbits of bits.  Data is always written
        // sequentially into the bytes array.
        bits: u64 = 0,
        nbits: u32 = 0, // number of bits
        bytes: [buffer_size]u8 = undefined,
        nbytes: u32 = 0, // number of bytes

        const Self = @This();

        pub const Error = WriterType.Error || error{UnfinishedBits};

        pub fn init(writer: WriterType) Self {
            return .{ .inner_writer = writer };
        }

        fn reset(self: *Self, new_writer: WriterType) void {
            self.inner_writer = new_writer;
            self.bytes_written = 0;
            self.bits = 0;
            self.nbits = 0;
            self.nbytes = 0;
        }

        pub fn flush(self: *Self) Error!void {
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
            self.bytes_written += try self.inner_writer.write(b);
        }

        fn writeBits(self: *Self, b: u32, nb: u32) Error!void {
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

        fn writeBytes(self: *Self, bytes: []const u8) Error!void {
            var n = self.nbytes;
            if (self.nbits & 7 != 0) {
                return error.UnfinishedBits;
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

        fn writeCode(self: *Self, c: hc.HuffCode) Error!void {
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
    };
}

pub fn HuffmanBitWriter(comptime WriterType: type) type {
    const BitWriterType = BitWriter(WriterType);
    return struct {
        const Self = @This();

        pub const Error = BitWriterType.Error;
        bit_writer: BitWriterType,

        codegen_freq: [codegen_code_count]u16,
        literal_freq: [consts.huffman.max_num_lit]u16,
        offset_freq: [consts.huffman.offset_code_count]u16,
        codegen: [consts.huffman.max_num_lit + consts.huffman.offset_code_count + 1]u8,
        literal_encoding: hc.LiteralEncoder,
        offset_encoding: hc.OffsetEncoder,
        codegen_encoding: hc.CodegenEncoder,
        fixed_literal_encoding: hc.LiteralEncoder,
        fixed_offset_encoding: hc.OffsetEncoder,
        huff_offset: hc.OffsetEncoder,

        pub fn init(writer: WriterType) Self {
            var offset_freq = [1]u16{0} ** consts.huffman.offset_code_count;
            offset_freq[0] = 1;
            // huff_offset is a static offset encoder used for huffman only encoding.
            // It can be reused since we will not be encoding offset values.
            var huff_offset: hc.OffsetEncoder = .{};
            huff_offset.generate(offset_freq[0..], 15);

            return .{
                .bit_writer = BitWriterType.init(writer),
                .codegen_freq = undefined,
                .literal_freq = undefined,
                .offset_freq = undefined,
                .codegen = undefined,
                .literal_encoding = .{},
                .codegen_encoding = .{},
                .offset_encoding = .{},
                .fixed_literal_encoding = hc.fixedLiteralEncoder(),
                .fixed_offset_encoding = hc.fixedOffsetEncoder(),
                .huff_offset = huff_offset,
            };
        }

        fn reset(self: *Self, new_writer: WriterType) void {
            self.bit_writer.reset(new_writer);
        }

        pub fn flush(self: *Self) Error!void {
            try self.bit_writer.flush();
        }

        fn writeBits(self: *Self, b: u32, nb: u32) Error!void {
            try self.bit_writer.writeBits(b, nb);
        }

        fn writeBytes(self: *Self, bytes: []const u8) Error!void {
            try self.bit_writer.writeBytes(bytes);
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
            lit_enc: *hc.LiteralEncoder,
            off_enc: *hc.OffsetEncoder,
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
            lit_enc: *hc.LiteralEncoder, // literal encoder
            off_enc: *hc.OffsetEncoder, // offset encoder
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
            if (in.?.len <= consts.max_store_block_size) {
                return .{ .size = @as(u32, @intCast((in.?.len + 5) * 8)), .storable = true };
            }
            return .{ .size = 0, .storable = false };
        }

        fn writeCode(self: *Self, c: hc.HuffCode) Error!void {
            try self.bit_writer.writeCode(c);
        }

        // Write the header of a dynamic Huffman block to the output stream.
        //
        //  num_literals: The number of literals specified in codegen
        //  num_offsets: The number of offsets specified in codegen
        //  num_codegens: The number of codegens used in codegen
        //  eof: Is it the end-of-file? (end of stream)
        fn writeDynamicHeader(
            self: *Self,
            num_literals: u32,
            num_offsets: u32,
            num_codegens: u32,
            eof: bool,
        ) Error!void {
            const first_bits: u32 = if (eof) 5 else 4;
            try self.writeBits(first_bits, 3);
            try self.writeBits(num_literals - 257, 5);
            try self.writeBits(num_offsets - 1, 5);
            try self.writeBits(num_codegens - 4, 4);

            var i: u32 = 0;
            while (i < num_codegens) : (i += 1) {
                const value = self.codegen_encoding.codes[codegen_order[i]].len;
                try self.writeBits(value, 3);
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
                        try self.writeBits(self.codegen[i], 2);
                        i += 1;
                    },
                    17 => {
                        try self.writeBits(self.codegen[i], 3);
                        i += 1;
                    },
                    18 => {
                        try self.writeBits(self.codegen[i], 7);
                        i += 1;
                    },
                    else => {},
                }
            }
        }

        fn writeStoredHeader(self: *Self, length: usize, eof: bool) Error!void {
            const flag: u32 = if (eof) 1 else 0;
            try self.writeBits(flag, 3);
            try self.flush();
            const l: u16 = @intCast(length);
            try self.writeBits(l, 16);
            try self.writeBits(~l, 16);
        }

        fn writeFixedHeader(self: *Self, eof: bool) Error!void {
            // Indicate that we are a fixed Huffman block
            var value: u32 = 2;
            if (eof) {
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
            tokens: []const Token,
            eof: bool,
            input: ?[]const u8,
        ) Error!void {
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
                var length_code: u16 = Token.length_codes_start + 8;
                while (length_code < num_literals) : (length_code += 1) {
                    // First eight length codes have extra size = 0.
                    extra_bits += @as(u32, @intCast(self.literal_freq[length_code])) *
                        @as(u32, @intCast(Token.lengthExtraBits(length_code)));
                }
                var offset_code: u16 = 4;
                while (offset_code < num_offsets) : (offset_code += 1) {
                    // First four offset codes have extra size = 0.
                    extra_bits += @as(u32, @intCast(self.offset_freq[offset_code])) *
                        @as(u32, @intCast(Token.offsetExtraBits(offset_code)));
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
                try self.writeBlockStored(input.?, eof);
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

        fn writeBlockStored(self: *Self, input: []const u8, eof: bool) Error!void {
            try self.writeStoredHeader(input.len, eof);
            try self.writeBytes(input);
        }

        // writeBlockDynamic encodes a block using a dynamic Huffman table.
        // This should be used if the symbols used have a disproportionate
        // histogram distribution.
        // If input is supplied and the compression savings are below 1/16th of the
        // input size the block is stored.
        fn writeBlockDynamic(
            self: *Self,
            tokens: []const Token,
            eof: bool,
            input: ?[]const u8,
        ) Error!void {
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
                try self.writeBlockStored(input.?, eof);
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
        fn indexTokens(self: *Self, tokens: []const Token) TotalIndexedTokens {
            var num_literals: u32 = 0;
            var num_offsets: u32 = 0;

            for (self.literal_freq, 0..) |_, i| {
                self.literal_freq[i] = 0;
            }
            for (self.offset_freq, 0..) |_, i| {
                self.offset_freq[i] = 0;
            }

            for (tokens) |t| {
                if (t.kind == Token.Kind.literal) {
                    self.literal_freq[t.literal()] += 1;
                    continue;
                }
                self.literal_freq[t.lengthCode()] += 1;
                self.offset_freq[t.offsetCode()] += 1;
            }
            // add end_block_marker token at the end
            self.literal_freq[consts.end_block_marker] += 1;

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
            tokens: []const Token,
            le_codes: []hc.HuffCode,
            oe_codes: []hc.HuffCode,
        ) Error!void {
            for (tokens) |t| {
                if (t.kind == Token.Kind.literal) {
                    try self.writeCode(le_codes[t.literal()]);
                    continue;
                }

                // Write the length
                const le = t.lengthEncoding();
                try self.writeCode(le_codes[le.code]);
                if (le.extra_bits > 0) {
                    try self.writeBits(le.extra_length, le.extra_bits);
                }

                // Write the offset
                const oe = t.offsetEncoding();
                try self.writeCode(oe_codes[oe.code]);
                if (oe.extra_bits > 0) {
                    try self.writeBits(oe.extra_offset, oe.extra_bits);
                }
            }
            // add end_block_marker at the end
            try self.writeCode(le_codes[consts.end_block_marker]);
        }

        // TODO: unused remove this, and huff_offset field
        // TODO: move initializtion to definiton after that
        //
        // Encodes a block of bytes as either Huffman encoded literals or uncompressed bytes
        // if the results only gains very little from compression.
        fn writeBlockHuff(self: *Self, eof: bool, input: []const u8) Error!void {
            // Clear histogram
            for (self.literal_freq, 0..) |_, i| {
                self.literal_freq[i] = 0;
            }

            // Add everything as literals
            histogram(input, &self.literal_freq);

            self.literal_freq[consts.end_block_marker] = 1;

            const num_literals = consts.end_block_marker + 1;
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
                try self.writeBlockStored(input, eof);
                return;
            }

            // Huffman.
            try self.writeDynamicHeader(num_literals, num_offsets, num_codegens, eof);
            const encoding = self.literal_encoding.codes[0..257];

            for (input) |t| {
                const c = encoding[t];
                try self.writeBits(c.code, c.len);
            }
            try self.writeCode(encoding[consts.end_block_marker]);
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
    return HuffmanBitWriter(@TypeOf(writer)).init(writer);
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

    try testWriterEOF(.write_huffman_block, &[0]Token{}, in);
}

const HuffTest = struct {
    tokens: []const Token,
    input: []const u8 = "", // File name of input data matching the tokens.
    want: []const u8 = "", // File name of data with the expected output with input available.
    want_no_input: []const u8 = "", // File name of the expected output when no input is available.
};

const writeBlockTests = blk: {
    @setEvalBranchQuota(4096 * 2);

    const L = Token.initLiteral;
    const M = Token.initMatch;
    const ml = M(1, 258); // Maximum length token. Used to reduce the size of writeBlockTests

    break :blk &[_]HuffTest{
        HuffTest{
            .input = "huffman-null-max.input",
            .want = "huffman-null-max.{s}.expect",
            .want_no_input = "huffman-null-max.{s}.expect-noinput",
            .tokens = &[_]Token{
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
            .tokens = &[_]Token{
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
                L('4'),     L('8'),     L('1'),     L('1'),     L('1'),     L('7'),     L('4'),     M(127, 4),
                L('4'),     L('1'),     L('0'),     L('2'),     L('7'),     L('0'),     L('1'),     L('9'),
                L('3'),     L('8'),     L('5'),     L('2'),     L('1'),     L('1'),     L('0'),     L('5'),
                L('5'),     L('5'),     L('9'),     L('6'),     L('4'),     L('4'),     L('6'),     L('2'),
                L('2'),     L('9'),     L('4'),     L('8'),     L('9'),     L('5'),     L('4'),     L('9'),
                L('3'),     L('0'),     L('3'),     L('8'),     L('1'),     M(19, 4),   L('2'),     L('8'),
                L('8'),     L('1'),     L('0'),     L('9'),     L('7'),     L('5'),     L('6'),     L('6'),
                L('5'),     L('9'),     L('3'),     L('3'),     L('4'),     L('4'),     L('6'),     M(72, 4),
                L('7'),     L('5'),     L('6'),     L('4'),     L('8'),     L('2'),     L('3'),     L('3'),
                L('7'),     L('8'),     L('6'),     L('7'),     L('8'),     L('3'),     L('1'),     L('6'),
                L('5'),     L('2'),     L('7'),     L('1'),     L('2'),     L('0'),     L('1'),     L('9'),
                L('0'),     L('9'),     L('1'),     L('4'),     M(27, 4),   L('5'),     L('6'),     L('6'),
                L('9'),     L('2'),     L('3'),     L('4'),     L('6'),     M(179, 4),  L('6'),     L('1'),
                L('0'),     L('4'),     L('5'),     L('4'),     L('3'),     L('2'),     L('6'),     M(51, 4),
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
                L('8'),     L('6'),     L('1'),     L('1'),     L('7'),     M(234, 4),  L('3'),     L('2'),
                M(10, 4),   L('9'),     L('3'),     L('1'),     L('0'),     L('5'),     L('1'),     L('1'),
                L('8'),     L('5'),     L('4'),     L('8'),     L('0'),     L('7'),     M(271, 4),  L('3'),
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
                L('2'),     L('1'),     L('7'),     L('9'),     L('8'),     M(154, 5),  L('7'),     L('0'),
                L('2'),     L('7'),     L('7'),     L('0'),     L('5'),     L('3'),     L('9'),     L('2'),
                L('1'),     L('7'),     L('1'),     L('7'),     L('6'),     L('2'),     L('9'),     L('3'),
                L('1'),     L('7'),     L('6'),     L('7'),     L('5'),     M(563, 5),  L('7'),     L('4'),
                L('8'),     L('1'),     M(7, 4),    L('6'),     L('6'),     L('9'),     L('4'),     L('0'),
                M(488, 4),  L('0'),     L('0'),     L('0'),     L('5'),     L('6'),     L('8'),     L('1'),
                L('2'),     L('7'),     L('1'),     L('4'),     L('5'),     L('2'),     L('6'),     L('3'),
                L('5'),     L('6'),     L('0'),     L('8'),     L('2'),     L('7'),     L('7'),     L('8'),
                L('5'),     L('7'),     L('7'),     L('1'),     L('3'),     L('4'),     L('2'),     L('7'),
                L('5'),     L('7'),     L('7'),     L('8'),     L('9'),     L('6'),     M(298, 4),  L('3'),
                L('6'),     L('3'),     L('7'),     L('1'),     L('7'),     L('8'),     L('7'),     L('2'),
                L('1'),     L('4'),     L('6'),     L('8'),     L('4'),     L('4'),     L('0'),     L('9'),
                L('0'),     L('1'),     L('2'),     L('2'),     L('4'),     L('9'),     L('5'),     L('3'),
                L('4'),     L('3'),     L('0'),     L('1'),     L('4'),     L('6'),     L('5'),     L('4'),
                L('9'),     L('5'),     L('8'),     L('5'),     L('3'),     L('7'),     L('1'),     L('0'),
                L('5'),     L('0'),     L('7'),     L('9'),     M(203, 4),  L('6'),     M(340, 4),  L('8'),
                L('9'),     L('2'),     L('3'),     L('5'),     L('4'),     M(458, 4),  L('9'),     L('5'),
                L('6'),     L('1'),     L('1'),     L('2'),     L('1'),     L('2'),     L('9'),     L('0'),
                L('2'),     L('1'),     L('9'),     L('6'),     L('0'),     L('8'),     L('6'),     L('4'),
                L('0'),     L('3'),     L('4'),     L('4'),     L('1'),     L('8'),     L('1'),     L('5'),
                L('9'),     L('8'),     L('1'),     L('3'),     L('6'),     L('2'),     L('9'),     L('7'),
                L('7'),     L('4'),     M(117, 4),  L('0'),     L('9'),     L('9'),     L('6'),     L('0'),
                L('5'),     L('1'),     L('8'),     L('7'),     L('0'),     L('7'),     L('2'),     L('1'),
                L('1'),     L('3'),     L('4'),     L('9'),     M(1, 5),    L('8'),     L('3'),     L('7'),
                L('2'),     L('9'),     L('7'),     L('8'),     L('0'),     L('4'),     L('9'),     L('9'),
                M(731, 4),  L('9'),     L('7'),     L('3'),     L('1'),     L('7'),     L('3'),     L('2'),
                L('8'),     M(395, 4),  L('6'),     L('3'),     L('1'),     L('8'),     L('5'),     M(770, 4),
                M(745, 4),  L('4'),     L('5'),     L('5'),     L('3'),     L('4'),     L('6'),     L('9'),
                L('0'),     L('8'),     L('3'),     L('0'),     L('2'),     L('6'),     L('4'),     L('2'),
                L('5'),     L('2'),     L('2'),     L('3'),     L('0'),     M(740, 4),  M(616, 4),  L('8'),
                L('5'),     L('0'),     L('3'),     L('5'),     L('2'),     L('6'),     L('1'),     L('9'),
                L('3'),     L('1'),     L('1'),     M(531, 4),  L('1'),     L('0'),     L('1'),     L('0'),
                L('0'),     L('0'),     L('3'),     L('1'),     L('3'),     L('7'),     L('8'),     L('3'),
                L('8'),     L('7'),     L('5'),     L('2'),     L('8'),     L('8'),     L('6'),     L('5'),
                L('8'),     L('7'),     L('5'),     L('3'),     L('3'),     L('2'),     L('0'),     L('8'),
                L('3'),     L('8'),     L('1'),     L('4'),     L('2'),     L('0'),     L('6'),     M(321, 4),
                M(300, 4),  L('1'),     L('4'),     L('7'),     L('3'),     L('0'),     L('3'),     L('5'),
                L('9'),     M(815, 5),  L('9'),     L('0'),     L('4'),     L('2'),     L('8'),     L('7'),
                L('5'),     L('5'),     L('4'),     L('6'),     L('8'),     L('7'),     L('3'),     L('1'),
                L('1'),     L('5'),     L('9'),     L('5'),     M(854, 4),  L('3'),     L('8'),     L('8'),
                L('2'),     L('3'),     L('5'),     L('3'),     L('7'),     L('8'),     L('7'),     L('5'),
                M(896, 5),  L('9'),     M(315, 4),  L('1'),     M(329, 4),  L('8'),     L('0'),     L('5'),
                L('3'),     M(395, 4),  L('2'),     L('2'),     L('6'),     L('8'),     L('0'),     L('6'),
                L('6'),     L('1'),     L('3'),     L('0'),     L('0'),     L('1'),     L('9'),     L('2'),
                L('7'),     L('8'),     L('7'),     L('6'),     L('6'),     L('1'),     L('1'),     L('1'),
                L('9'),     L('5'),     L('9'),     M(568, 4),  L('6'),     M(293, 5),  L('8'),     L('9'),
                L('3'),     L('8'),     L('0'),     L('9'),     L('5'),     L('2'),     L('5'),     L('7'),
                L('2'),     L('0'),     L('1'),     L('0'),     L('6'),     L('5'),     L('4'),     L('8'),
                L('5'),     L('8'),     L('6'),     L('3'),     L('2'),     L('7'),     M(155, 4),  L('9'),
                L('3'),     L('6'),     L('1'),     L('5'),     L('3'),     M(545, 4),  M(349, 5),  L('2'),
                L('3'),     L('0'),     L('3'),     L('0'),     L('1'),     L('9'),     L('5'),     L('2'),
                L('0'),     L('3'),     L('5'),     L('3'),     L('0'),     L('1'),     L('8'),     L('5'),
                L('2'),     M(370, 4),  M(118, 4),  L('3'),     L('6'),     L('2'),     L('2'),     L('5'),
                L('9'),     L('9'),     L('4'),     L('1'),     L('3'),     M(597, 4),  L('4'),     L('9'),
                L('7'),     L('2'),     L('1'),     L('7'),     M(223, 4),  L('3'),     L('4'),     L('7'),
                L('9'),     L('1'),     L('3'),     L('1'),     L('5'),     L('1'),     L('5'),     L('5'),
                L('7'),     L('4'),     L('8'),     L('5'),     L('7'),     L('2'),     L('4'),     L('2'),
                L('4'),     L('5'),     L('4'),     L('1'),     L('5'),     L('0'),     L('6'),     L('9'),
                M(320, 4),  L('8'),     L('2'),     L('9'),     L('5'),     L('3'),     L('3'),     L('1'),
                L('1'),     L('6'),     L('8'),     L('6'),     L('1'),     L('7'),     L('2'),     L('7'),
                L('8'),     M(824, 4),  L('9'),     L('0'),     L('7'),     L('5'),     L('0'),     L('9'),
                M(270, 4),  L('7'),     L('5'),     L('4'),     L('6'),     L('3'),     L('7'),     L('4'),
                L('6'),     L('4'),     L('9'),     L('3'),     L('9'),     L('3'),     L('1'),     L('9'),
                L('2'),     L('5'),     L('5'),     L('0'),     L('6'),     L('0'),     L('4'),     L('0'),
                L('0'),     L('9'),     M(620, 4),  L('1'),     L('6'),     L('7'),     L('1'),     L('1'),
                L('3'),     L('9'),     L('0'),     L('0'),     L('9'),     L('8'),     M(822, 4),  L('4'),
                L('0'),     L('1'),     L('2'),     L('8'),     L('5'),     L('8'),     L('3'),     L('6'),
                L('1'),     L('6'),     L('0'),     L('3'),     L('5'),     L('6'),     L('3'),     L('7'),
                L('0'),     L('7'),     L('6'),     L('6'),     L('0'),     L('1'),     L('0'),     L('4'),
                M(371, 4),  L('8'),     L('1'),     L('9'),     L('4'),     L('2'),     L('9'),     M(1055, 5),
                M(240, 4),  M(652, 4),  L('7'),     L('8'),     L('3'),     L('7'),     L('4'),     M(1193, 4),
                L('8'),     L('2'),     L('5'),     L('5'),     L('3'),     L('7'),     M(522, 5),  L('2'),
                L('6'),     L('8'),     M(47, 4),   L('4'),     L('0'),     L('4'),     L('7'),     M(466, 4),
                L('4'),     M(1206, 4), M(910, 4),  L('8'),     L('4'),     M(937, 4),  L('6'),     M(800, 6),
                L('3'),     L('3'),     L('1'),     L('3'),     L('6'),     L('7'),     L('7'),     L('0'),
                L('2'),     L('8'),     L('9'),     L('8'),     L('9'),     L('1'),     L('5'),     L('2'),
                M(99, 4),   L('5'),     L('2'),     L('1'),     L('6'),     L('2'),     L('0'),     L('5'),
                L('6'),     L('9'),     L('6'),     M(1042, 4), L('0'),     L('5'),     L('8'),     M(1144, 4),
                L('5'),     M(1177, 4), L('5'),     L('1'),     L('1'),     M(522, 4),  L('8'),     L('2'),
                L('4'),     L('3'),     L('0'),     L('0'),     L('3'),     L('5'),     L('5'),     L('8'),
                L('7'),     L('6'),     L('4'),     L('0'),     L('2'),     L('4'),     L('7'),     L('4'),
                L('9'),     L('6'),     L('4'),     L('7'),     L('3'),     L('2'),     L('6'),     L('3'),
                M(1087, 4), L('9'),     L('9'),     L('2'),     M(1100, 4), L('4'),     L('2'),     L('6'),
                L('9'),     M(710, 6),  L('7'),     M(471, 4),  L('4'),     M(1342, 4), M(1054, 4), L('9'),
                L('3'),     L('4'),     L('1'),     L('7'),     M(430, 4),  L('1'),     L('2'),     M(43, 4),
                L('4'),     M(415, 4),  L('1'),     L('5'),     L('0'),     L('3'),     L('0'),     L('2'),
                L('8'),     L('6'),     L('1'),     L('8'),     L('2'),     L('9'),     L('7'),     L('4'),
                L('5'),     L('5'),     L('5'),     L('7'),     L('0'),     L('6'),     L('7'),     L('4'),
                M(310, 4),  L('5'),     L('0'),     L('5'),     L('4'),     L('9'),     L('4'),     L('5'),
                L('8'),     M(454, 4),  L('9'),     M(82, 4),   L('5'),     L('6'),     M(493, 4),  L('7'),
                L('2'),     L('1'),     L('0'),     L('7'),     L('9'),     M(346, 4),  L('3'),     L('0'),
                M(267, 4),  L('3'),     L('2'),     L('1'),     L('1'),     L('6'),     L('5'),     L('3'),
                L('4'),     L('4'),     L('9'),     L('8'),     L('7'),     L('2'),     L('0'),     L('2'),
                L('7'),     M(284, 4),  L('0'),     L('2'),     L('3'),     L('6'),     L('4'),     M(559, 4),
                L('5'),     L('4'),     L('9'),     L('9'),     L('1'),     L('1'),     L('9'),     L('8'),
                M(1049, 4), L('4'),     M(284, 4),  L('5'),     L('3'),     L('5'),     L('6'),     L('6'),
                L('3'),     L('6'),     L('9'),     M(1105, 4), L('2'),     L('6'),     L('5'),     M(741, 4),
                L('7'),     L('8'),     L('6'),     L('2'),     L('5'),     L('5'),     L('1'),     M(987, 4),
                L('1'),     L('7'),     L('5'),     L('7'),     L('4'),     L('6'),     L('7'),     L('2'),
                L('8'),     L('9'),     L('0'),     L('9'),     L('7'),     L('7'),     L('7'),     L('7'),
                M(1108, 5), L('0'),     L('0'),     L('0'),     M(1534, 4), L('7'),     L('0'),     M(1248, 4),
                L('6'),     M(1002, 4), L('4'),     L('9'),     L('1'),     M(1055, 4), M(664, 4),  L('2'),
                L('1'),     L('4'),     L('7'),     L('7'),     L('2'),     L('3'),     L('5'),     L('0'),
                L('1'),     L('4'),     L('1'),     L('4'),     M(1604, 4), L('3'),     L('5'),     L('6'),
                M(1200, 4), L('1'),     L('6'),     L('1'),     L('3'),     L('6'),     L('1'),     L('1'),
                L('5'),     L('7'),     L('3'),     L('5'),     L('2'),     L('5'),     M(1285, 4), L('3'),
                L('4'),     M(92, 4),   L('1'),     L('8'),     M(1148, 4), L('8'),     L('4'),     M(1512, 4),
                L('3'),     L('3'),     L('2'),     L('3'),     L('9'),     L('0'),     L('7'),     L('3'),
                L('9'),     L('4'),     L('1'),     L('4'),     L('3'),     L('3'),     L('3'),     L('4'),
                L('5'),     L('4'),     L('7'),     L('7'),     L('6'),     L('2'),     L('4'),     M(579, 4),
                L('2'),     L('5'),     L('1'),     L('8'),     L('9'),     L('8'),     L('3'),     L('5'),
                L('6'),     L('9'),     L('4'),     L('8'),     L('5'),     L('5'),     L('6'),     L('2'),
                L('0'),     L('9'),     L('9'),     L('2'),     L('1'),     L('9'),     L('2'),     L('2'),
                L('2'),     L('1'),     L('8'),     L('4'),     L('2'),     L('7'),     M(575, 4),  L('2'),
                M(187, 4),  L('6'),     L('8'),     L('8'),     L('7'),     L('6'),     L('7'),     L('1'),
                L('7'),     L('9'),     L('0'),     M(86, 4),   L('0'),     M(263, 5),  L('6'),     L('6'),
                M(1000, 4), L('8'),     L('8'),     L('6'),     L('2'),     L('7'),     L('2'),     M(1757, 4),
                L('1'),     L('7'),     L('8'),     L('6'),     L('0'),     L('8'),     L('5'),     L('7'),
                M(116, 4),  L('3'),     M(765, 5),  L('7'),     L('9'),     L('7'),     L('6'),     L('6'),
                L('8'),     L('1'),     M(702, 4),  L('0'),     L('0'),     L('9'),     L('5'),     L('3'),
                L('8'),     L('8'),     M(1593, 4), L('3'),     M(1702, 4), L('0'),     L('6'),     L('8'),
                L('0'),     L('0'),     L('6'),     L('4'),     L('2'),     L('2'),     L('5'),     L('1'),
                L('2'),     L('5'),     L('2'),     M(1404, 4), L('7'),     L('3'),     L('9'),     L('2'),
                M(664, 4),  M(1141, 4), L('4'),     M(1716, 5), L('8'),     L('6'),     L('2'),     L('6'),
                L('9'),     L('4'),     L('5'),     M(486, 4),  L('4'),     L('1'),     L('9'),     L('6'),
                L('5'),     L('2'),     L('8'),     L('5'),     L('0'),     M(154, 4),  M(925, 4),  L('1'),
                L('8'),     L('6'),     L('3'),     M(447, 4),  L('4'),     M(341, 5),  L('2'),     L('0'),
                L('3'),     L('9'),     M(1420, 4), L('4'),     L('5'),     M(701, 4),  L('2'),     L('3'),
                L('7'),     M(1069, 4), L('6'),     M(1297, 4), L('5'),     L('6'),     M(1593, 4), L('7'),
                L('1'),     L('9'),     L('1'),     L('7'),     L('2'),     L('8'),     M(370, 4),  L('7'),
                L('6'),     L('4'),     L('6'),     L('5'),     L('7'),     L('5'),     L('7'),     L('3'),
                L('9'),     M(258, 4),  L('3'),     L('8'),     L('9'),     M(1865, 4), L('8'),     L('3'),
                L('2'),     L('6'),     L('4'),     L('5'),     L('9'),     L('9'),     L('5'),     L('8'),
                M(1704, 4), L('0'),     L('4'),     L('7'),     L('8'),     M(479, 4),  M(809, 4),  L('9'),
                M(46, 4),   L('6'),     L('4'),     L('0'),     L('7'),     L('8'),     L('9'),     L('5'),
                L('1'),     M(143, 4),  L('6'),     L('8'),     L('3'),     M(304, 4),  L('2'),     L('5'),
                L('9'),     L('5'),     L('7'),     L('0'),     M(1129, 4), L('8'),     L('2'),     L('2'),
                M(713, 4),  L('2'),     M(1564, 4), L('4'),     L('0'),     L('7'),     L('7'),     L('2'),
                L('6'),     L('7'),     L('1'),     L('9'),     L('4'),     L('7'),     L('8'),     M(794, 4),
                L('8'),     L('2'),     L('6'),     L('0'),     L('1'),     L('4'),     L('7'),     L('6'),
                L('9'),     L('9'),     L('0'),     L('9'),     M(1257, 4), L('0'),     L('1'),     L('3'),
                L('6'),     L('3'),     L('9'),     L('4'),     L('4'),     L('3'),     M(640, 4),  L('3'),
                L('0'),     M(262, 4),  L('2'),     L('0'),     L('3'),     L('4'),     L('9'),     L('6'),
                L('2'),     L('5'),     L('2'),     L('4'),     L('5'),     L('1'),     L('7'),     M(950, 4),
                L('9'),     L('6'),     L('5'),     L('1'),     L('4'),     L('3'),     L('1'),     L('4'),
                L('2'),     L('9'),     L('8'),     L('0'),     L('9'),     L('1'),     L('9'),     L('0'),
                L('6'),     L('5'),     L('9'),     L('2'),     M(643, 4),  L('7'),     L('2'),     L('2'),
                L('1'),     L('6'),     L('9'),     L('6'),     L('4'),     L('6'),     M(1050, 4), M(123, 4),
                L('5'),     M(1295, 4), L('4'),     M(1382, 5), L('8'),     M(1370, 4), L('9'),     L('7'),
                M(1404, 4), L('5'),     L('4'),     M(1182, 4), M(575, 4),  L('7'),     M(1627, 4), L('8'),
                L('4'),     L('6'),     L('8'),     L('1'),     L('3'),     M(141, 4),  L('6'),     L('8'),
                L('3'),     L('8'),     L('6'),     L('8'),     L('9'),     L('4'),     L('2'),     L('7'),
                L('7'),     L('4'),     L('1'),     L('5'),     L('5'),     L('9'),     L('9'),     L('1'),
                L('8'),     L('5'),     M(91, 4),   L('2'),     L('4'),     L('5'),     L('9'),     L('5'),
                L('3'),     L('9'),     L('5'),     L('9'),     L('4'),     L('3'),     L('1'),     M(1464, 4),
                L('7'),     M(19, 4),   L('6'),     L('8'),     L('0'),     L('8'),     L('4'),     L('5'),
                M(744, 4),  L('7'),     L('3'),     M(2079, 4), L('9'),     L('5'),     L('8'),     L('4'),
                L('8'),     L('6'),     L('5'),     L('3'),     L('8'),     M(1769, 4), L('6'),     L('2'),
                M(243, 4),  L('6'),     L('0'),     L('9'),     M(1207, 4), L('6'),     L('0'),     L('8'),
                L('0'),     L('5'),     L('1'),     L('2'),     L('4'),     L('3'),     L('8'),     L('8'),
                L('4'),     M(315, 4),  M(12, 4),   L('4'),     L('1'),     L('3'),     M(784, 4),  L('7'),
                L('6'),     L('2'),     L('7'),     L('8'),     M(834, 4),  L('7'),     L('1'),     L('5'),
                M(1436, 4), L('3'),     L('5'),     L('9'),     L('9'),     L('7'),     L('7'),     L('0'),
                L('0'),     L('1'),     L('2'),     L('9'),     M(1139, 4), L('8'),     L('9'),     L('4'),
                L('4'),     L('1'),     M(632, 4),  L('6'),     L('8'),     L('5'),     L('5'),     M(96, 4),
                L('4'),     L('0'),     L('6'),     L('3'),     M(2279, 4), L('2'),     L('0'),     L('7'),
                L('2'),     L('2'),     M(345, 4),  M(516, 5),  L('4'),     L('8'),     L('1'),     L('5'),
                L('8'),     M(518, 4),  M(511, 4),  M(635, 4),  M(665, 4),  L('3'),     L('9'),     L('4'),
                L('5'),     L('2'),     L('2'),     L('6'),     L('7'),     M(1175, 6), L('8'),     M(1419, 4),
                L('2'),     L('1'),     M(747, 4),  L('2'),     M(904, 4),  L('5'),     L('4'),     L('6'),
                L('6'),     L('6'),     M(1308, 4), L('2'),     L('3'),     L('9'),     L('8'),     L('6'),
                L('4'),     L('5'),     L('6'),     M(1221, 4), L('1'),     L('6'),     L('3'),     L('5'),
                M(596, 5),  M(2066, 4), L('7'),     M(2222, 4), L('9'),     L('8'),     M(1119, 4), L('9'),
                L('3'),     L('6'),     L('3'),     L('4'),     M(1884, 4), L('7'),     L('4'),     L('3'),
                L('2'),     L('4'),     M(1148, 4), L('1'),     L('5'),     L('0'),     L('7'),     L('6'),
                M(1212, 4), L('7'),     L('9'),     L('4'),     L('5'),     L('1'),     L('0'),     L('9'),
                M(63, 4),   L('0'),     L('9'),     L('4'),     L('0'),     M(1703, 4), L('8'),     L('8'),
                L('7'),     L('9'),     L('7'),     L('1'),     L('0'),     L('8'),     L('9'),     L('3'),
                M(2289, 4), L('6'),     L('9'),     L('1'),     L('3'),     L('6'),     L('8'),     L('6'),
                L('7'),     L('2'),     M(604, 4),  M(511, 4),  L('5'),     M(1344, 4), M(1129, 4), M(2050, 4),
                L('1'),     L('7'),     L('9'),     L('2'),     L('8'),     L('6'),     L('8'),     M(2253, 4),
                L('8'),     L('7'),     L('4'),     L('7'),     M(1951, 5), L('8'),     L('2'),     L('4'),
                M(2427, 4), L('8'),     M(604, 4),  L('7'),     L('1'),     L('4'),     L('9'),     L('0'),
                L('9'),     L('6'),     L('7'),     L('5'),     L('9'),     L('8'),     M(1776, 4), L('3'),
                L('6'),     L('5'),     M(309, 4),  L('8'),     L('1'),     M(93, 4),   M(1862, 4), M(2359, 4),
                L('6'),     L('8'),     L('2'),     L('9'),     M(1407, 4), L('8'),     L('7'),     L('2'),
                L('2'),     L('6'),     L('5'),     L('8'),     L('8'),     L('0'),     M(1554, 4), L('5'),
                M(586, 4),  L('4'),     L('2'),     L('7'),     L('0'),     L('4'),     L('7'),     L('7'),
                L('5'),     L('5'),     M(2079, 4), L('3'),     L('7'),     L('9'),     L('6'),     L('4'),
                L('1'),     L('4'),     L('5'),     L('1'),     L('5'),     L('2'),     M(1534, 4), L('2'),
                L('3'),     L('4'),     L('3'),     L('6'),     L('4'),     L('5'),     L('4'),     M(1503, 4),
                L('4'),     L('4'),     L('4'),     L('7'),     L('9'),     L('5'),     M(61, 4),   M(1316, 4),
                M(2279, 5), L('4'),     L('1'),     M(1323, 4), L('3'),     M(773, 4),  L('5'),     L('2'),
                L('3'),     L('1'),     M(2114, 5), L('1'),     L('6'),     L('6'),     L('1'),     M(2227, 4),
                L('5'),     L('9'),     L('6'),     L('9'),     L('5'),     L('3'),     L('6'),     L('2'),
                L('3'),     L('1'),     L('4'),     M(1536, 4), L('2'),     L('4'),     L('8'),     L('4'),
                L('9'),     L('3'),     L('7'),     L('1'),     L('8'),     L('7'),     L('1'),     L('1'),
                L('0'),     L('1'),     L('4'),     L('5'),     L('7'),     L('6'),     L('5'),     L('4'),
                M(1890, 4), L('0'),     L('2'),     L('7'),     L('9'),     L('9'),     L('3'),     L('4'),
                L('4'),     L('0'),     L('3'),     L('7'),     L('4'),     L('2'),     L('0'),     L('0'),
                L('7'),     M(2368, 4), L('7'),     L('8'),     L('5'),     L('3'),     L('9'),     L('0'),
                L('6'),     L('2'),     L('1'),     L('9'),     M(666, 5),  M(838, 4),  L('8'),     L('4'),
                L('7'),     M(979, 5),  L('8'),     L('3'),     L('3'),     L('2'),     L('1'),     L('4'),
                L('4'),     L('5'),     L('7'),     L('1'),     M(645, 4),  M(1911, 4), L('4'),     L('3'),
                L('5'),     L('0'),     M(2345, 4), M(1129, 4), L('5'),     L('3'),     L('1'),     L('9'),
                L('1'),     L('0'),     L('4'),     L('8'),     L('4'),     L('8'),     L('1'),     L('0'),
                L('0'),     L('5'),     L('3'),     L('7'),     L('0'),     L('6'),     M(2237, 4), M(1438, 5),
                M(1922, 5), L('1'),     M(1370, 4), L('7'),     M(796, 4),  L('5'),     M(2029, 4), M(1037, 4),
                L('6'),     L('3'),     M(2013, 5), L('4'),     M(2418, 4), M(847, 5),  M(1014, 5), L('8'),
                M(1326, 5), M(2184, 5), L('9'),     M(392, 4),  L('9'),     L('1'),     M(2255, 4), L('8'),
                L('1'),     L('4'),     L('6'),     L('7'),     L('5'),     L('1'),     M(1580, 4), L('1'),
                L('2'),     L('3'),     L('9'),     M(426, 6),  L('9'),     L('0'),     L('7'),     L('1'),
                L('8'),     L('6'),     L('4'),     L('9'),     L('4'),     L('2'),     L('3'),     L('1'),
                L('9'),     L('6'),     L('1'),     L('5'),     L('6'),     M(493, 4),  M(1725, 4), L('9'),
                L('5'),     M(2343, 4), M(1130, 4), M(284, 4),  L('6'),     L('0'),     L('3'),     L('8'),
                M(2598, 4), M(368, 4),  M(901, 4),  L('6'),     L('2'),     M(1115, 4), L('5'),     M(2125, 4),
                L('6'),     L('3'),     L('8'),     L('9'),     L('3'),     L('7'),     L('7'),     L('8'),
                L('7'),     M(2246, 4), M(249, 4),  L('9'),     L('7'),     L('9'),     L('2'),     L('0'),
                L('7'),     L('7'),     L('3'),     M(1496, 4), L('2'),     L('1'),     L('8'),     L('2'),
                L('5'),     L('6'),     M(2016, 4), L('6'),     L('6'),     M(1751, 4), L('4'),     L('2'),
                M(1663, 5), L('6'),     M(1767, 4), L('4'),     L('4'),     M(37, 4),   L('5'),     L('4'),
                L('9'),     L('2'),     L('0'),     L('2'),     L('6'),     L('0'),     L('5'),     M(2740, 4),
                M(997, 5),  L('2'),     L('0'),     L('1'),     L('4'),     L('9'),     M(1235, 4), L('8'),
                L('5'),     L('0'),     L('7'),     L('3'),     M(1434, 4), L('6'),     L('6'),     L('6'),
                L('0'),     M(405, 4),  L('2'),     L('4'),     L('3'),     L('4'),     L('0'),     M(136, 4),
                L('0'),     M(1900, 4), L('8'),     L('6'),     L('3'),     M(2391, 4), M(2021, 4), M(1068, 4),
                M(373, 4),  L('5'),     L('7'),     L('9'),     L('6'),     L('2'),     L('6'),     L('8'),
                L('5'),     L('6'),     M(321, 4),  L('5'),     L('0'),     L('8'),     M(1316, 4), L('5'),
                L('8'),     L('7'),     L('9'),     L('6'),     L('9'),     L('9'),     M(1810, 4), L('5'),
                L('7'),     L('4'),     M(2585, 4), L('8'),     L('4'),     L('0'),     M(2228, 4), L('1'),
                L('4'),     L('5'),     L('9'),     L('1'),     M(1933, 4), L('7'),     L('0'),     M(565, 4),
                L('0'),     L('1'),     M(3048, 4), L('1'),     L('2'),     M(3189, 4), L('0'),     M(964, 4),
                L('3'),     L('9'),     M(2859, 4), M(275, 4),  L('7'),     L('1'),     L('5'),     M(945, 4),
                L('4'),     L('2'),     L('0'),     M(3059, 5), L('9'),     M(3011, 4), L('0'),     L('7'),
                M(834, 4),  M(1942, 4), M(2736, 4), M(3171, 4), L('2'),     L('1'),     M(2401, 4), L('2'),
                L('5'),     L('1'),     M(1404, 4), M(2373, 4), L('9'),     L('2'),     M(435, 4),  L('8'),
                L('2'),     L('6'),     M(2919, 4), L('2'),     M(633, 4),  L('3'),     L('2'),     L('1'),
                L('5'),     L('7'),     L('9'),     L('1'),     L('9'),     L('8'),     L('4'),     L('1'),
                L('4'),     M(2172, 5), L('9'),     L('1'),     L('6'),     L('4'),     M(1769, 5), L('9'),
                M(2905, 5), M(2268, 4), L('7'),     L('2'),     L('2'),     M(802, 4),  L('5'),     M(2213, 4),
                M(322, 4),  L('9'),     L('1'),     L('0'),     M(189, 4),  M(3164, 4), L('5'),     L('2'),
                L('8'),     L('0'),     L('1'),     L('7'),     M(562, 4),  L('7'),     L('1'),     L('2'),
                M(2325, 4), L('8'),     L('3'),     L('2'),     M(884, 4),  L('1'),     M(1418, 4), L('0'),
                L('9'),     L('3'),     L('5'),     L('3'),     L('9'),     L('6'),     L('5'),     L('7'),
                M(1612, 4), L('1'),     L('0'),     L('8'),     L('3'),     M(106, 4),  L('5'),     L('1'),
                M(1915, 4), M(3419, 4), L('1'),     L('4'),     L('4'),     L('4'),     L('2'),     L('1'),
                L('0'),     L('0'),     M(515, 4),  L('0'),     L('3'),     M(413, 4),  L('1'),     L('1'),
                L('0'),     L('3'),     M(3202, 4), M(10, 4),   M(39, 4),   M(1539, 6), L('5'),     L('1'),
                L('6'),     M(1498, 4), M(2180, 5), M(2347, 4), L('5'),     M(3139, 5), L('8'),     L('5'),
                L('1'),     L('7'),     L('1'),     L('4'),     L('3'),     L('7'),     M(1542, 4), M(110, 4),
                L('1'),     L('5'),     L('5'),     L('6'),     L('5'),     L('0'),     L('8'),     L('8'),
                M(954, 4),  L('9'),     L('8'),     L('9'),     L('8'),     L('5'),     L('9'),     L('9'),
                L('8'),     L('2'),     L('3'),     L('8'),     M(464, 4),  M(2491, 4), L('3'),     M(365, 4),
                M(1087, 4), M(2500, 4), L('8'),     M(3590, 5), L('3'),     L('2'),     M(264, 4),  L('5'),
                M(774, 4),  L('3'),     M(459, 4),  L('9'),     M(1052, 4), L('9'),     L('8'),     M(2174, 4),
                L('4'),     M(3257, 4), L('7'),     M(1612, 4), L('0'),     L('7'),     M(230, 4),  L('4'),
                L('8'),     L('1'),     L('4'),     L('1'),     M(1338, 4), L('8'),     L('5'),     L('9'),
                L('4'),     L('6'),     L('1'),     M(3018, 4), L('8'),     L('0'),
            },
        },
        HuffTest{
            .input = "huffman-rand-1k.input",
            .want = "huffman-rand-1k.{s}.expect",
            .want_no_input = "huffman-rand-1k.{s}.expect-noinput",
            .tokens = &[_]Token{
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
            .tokens = &[_]Token{
                L(0x61), M(1, 74), L(0xa),  L(0xf8), L(0x8b), L(0x96), L(0x76), L(0x48), L(0xa),  L(0x85), L(0x94), L(0x25), L(0x80),
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
            .tokens = &[_]Token{
                L('1'),    L('0'),    M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258),
                M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258),
                M(2, 258), M(2, 76),  L(0xd),    L(0xa),    L('2'),    L('3'),    M(2, 258), M(2, 258),
                M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 258), M(2, 256),
            },
        },
        HuffTest{
            .input = "huffman-text-shift.input",
            .want = "huffman-text-shift.{s}.expect",
            .want_no_input = "huffman-text-shift.{s}.expect-noinput",
            .tokens = &[_]Token{
                L('/'),   L('/'), L('C'),   L('o'), L('p'),   L('y'),   L('r'),   L('i'),
                L('g'),   L('h'), L('t'),   L('2'), L('0'),   L('0'),   L('9'),   L('T'),
                L('h'),   L('G'), L('o'),   L('A'), L('u'),   L('t'),   L('h'),   L('o'),
                L('r'),   L('.'), L('A'),   L('l'), L('l'),   M(23, 5), L('r'),   L('r'),
                L('v'),   L('d'), L('.'),   L(0xd), L(0xa),   L('/'),   L('/'),   L('U'),
                L('o'),   L('f'), L('t'),   L('h'), L('i'),   L('o'),   L('u'),   L('r'),
                L('c'),   L('c'), L('o'),   L('d'), L('i'),   L('g'),   L('o'),   L('v'),
                L('r'),   L('n'), L('d'),   L('b'), L('y'),   L('B'),   L('S'),   L('D'),
                L('-'),   L('t'), L('y'),   L('l'), M(33, 4), L('l'),   L('i'),   L('c'),
                L('n'),   L('t'), L('h'),   L('t'), L('c'),   L('n'),   L('b'),   L('f'),
                L('o'),   L('u'), L('n'),   L('d'), L('i'),   L('n'),   L('t'),   L('h'),
                L('L'),   L('I'), L('C'),   L('E'), L('N'),   L('S'),   L('E'),   L('f'),
                L('i'),   L('l'), L('.'),   L(0xd), L(0xa),   L(0xd),   L(0xa),   L('p'),
                L('c'),   L('k'), L('g'),   L('m'), L('i'),   L('n'),   M(11, 4), L('i'),
                L('m'),   L('p'), L('o'),   L('r'), L('t'),   L('"'),   L('o'),   L('"'),
                M(13, 4), L('f'), L('u'),   L('n'), L('c'),   L('m'),   L('i'),   L('n'),
                L('('),   L(')'), L('{'),   L(0xd), L(0xa),   L(0x9),   L('v'),   L('r'),
                L('b'),   L('='), L('m'),   L('k'), L('('),   L('['),   L(']'),   L('b'),
                L('y'),   L('t'), L(','),   L('6'), L('5'),   L('5'),   L('3'),   L('5'),
                L(')'),   L(0xd), L(0xa),   L(0x9), L('f'),   L(','),   L('_'),   L(':'),
                L('='),   L('o'), L('.'),   L('C'), L('r'),   L('t'),   L('('),   L('"'),
                L('h'),   L('u'), L('f'),   L('f'), L('m'),   L('n'),   L('-'),   L('n'),
                L('u'),   L('l'), L('l'),   L('-'), L('m'),   L('x'),   L('.'),   L('i'),
                L('n'),   L('"'), M(34, 5), L('.'), L('W'),   L('r'),   L('i'),   L('t'),
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
            .tokens = &[_]Token{
                L('/'),    L('/'),    L(' '),   L('z'),    L('i'), L('g'), L(' '), L('v'),
                L('0'),    L('.'),    L('1'),   L('0'),    L('.'), L('0'), L(0xa), L('/'),
                L('/'),    L(' '),    L('c'),   L('r'),    L('e'), L('a'), L('t'), L('e'),
                L(' '),    L('a'),    L(' '),   L('f'),    L('i'), L('l'), L('e'), M(5, 4),
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
                L(' '),    L('6'),    L('5'),   L('5'),    L('3'), L('5'), L(';'), M(31, 5),
                M(86, 6),  L('f'),    L(' '),   L('='),    L(' '), L('t'), L('r'), L('y'),
                M(94, 4),  L('.'),    L('f'),   L('s'),    L('.'), L('c'), L('w'), L('d'),
                L('('),    L(')'),    L('.'),   M(144, 6), L('F'), L('i'), L('l'), L('e'),
                L('('),    M(43, 5),  M(1, 4),  L('"'),    L('h'), L('u'), L('f'), L('f'),
                L('m'),    L('a'),    L('n'),   L('-'),    L('n'), L('u'), L('l'), L('l'),
                L('-'),    L('m'),    L('a'),   L('x'),    L('.'), L('i'), L('n'), L('"'),
                L(','),    M(31, 9),  L('.'),   L('{'),    L(' '), L('.'), L('r'), L('e'),
                L('a'),    L('d'),    M(79, 5), L('u'),    L('e'), L(' '), L('}'), M(27, 6),
                L(')'),    M(108, 6), L('d'),   L('e'),    L('f'), L('e'), L('r'), L(' '),
                L('f'),    L('.'),    L('c'),   L('l'),    L('o'), L('s'), L('e'), L('('),
                M(183, 4), M(22, 4),  L('_'),   M(124, 7), L('f'), L('.'), L('w'), L('r'),
                L('i'),    L('t'),    L('e'),   L('A'),    L('l'), L('l'), L('('), L('b'),
                L('['),    L('0'),    L('.'),   L('.'),    L(']'), L(')'), L(';'), L(0xa),
                L('}'),    L(0xa),
            },
        },
        HuffTest{
            .input = "huffman-zero.input",
            .want = "huffman-zero.{s}.expect",
            .want_no_input = "huffman-zero.{s}.expect-noinput",
            .tokens = &[_]Token{ L(0x30), ml, M(1, 49) },
        },
        HuffTest{
            .input = "",
            .want = "",
            .want_no_input = "null-long-match.{s}.expect-noinput",
            .tokens = &[_]Token{
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
                ml,     ml, ml, M(1, 8),
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

fn writeToType(ttype: TestType, bw: anytype, tok: []const Token, input: ?[]const u8) !void {
    switch (ttype) {
        .write_block => try bw.writeBlock(tok, false, input),
        .write_dyn_block => try bw.writeBlockDynamic(tok, false, input),
        else => unreachable,
    }
    try bw.flush();
}

// Tests if the written block contains an EOF marker.
fn testWriterEOF(ttype: TestType, ht_tokens: []const Token, input: []const u8) !void {
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
