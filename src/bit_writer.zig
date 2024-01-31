pub fn BitWriter(comptime WriterType: type) type {
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
        inner_writer: WriterType,

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

        pub fn reset(self: *Self, new_writer: WriterType) void {
            self.inner_writer = new_writer;
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
            _ = try self.inner_writer.write(self.bytes[0..n]);
            self.nbytes = 0;
        }

        // TODO size for nb, should it be u6
        pub fn writeBits(self: *Self, b: u32, nb: u32) Error!void {
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
                    _ = try self.inner_writer.write(self.bytes[0..n]);
                    n = 0;
                }
                self.nbytes = n;
            }
        }

        pub fn writeBytes(self: *Self, bytes: []const u8) Error!void {
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
                _ = try self.inner_writer.write(self.bytes[0..n]);
            }
            self.nbytes = 0;
            _ = try self.inner_writer.write(bytes);
        }
    };
}
