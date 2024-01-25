const std = @import("std");

pub const Kind = enum {
    raw, // no header or footer
    gzip, // gzip header and footer
    zlib, // zlib header and footer
};

pub fn init(comptime kind: Kind, reader: anytype, writer: anytype) Wrapper(kind, @TypeOf(reader), @TypeOf(writer)) {
    return Wrapper(kind, @TypeOf(reader), @TypeOf(writer)){
        .rdr = reader,
        .wrt = writer,
    };
}

fn Wrapper(kind: Kind, comptime ReaderType: type, comptime WriterType: type) type {
    const HasherType = switch (kind) {
        .gzip => std.hash.Crc32,
        .zlib => std.hash.Adler32,
        .raw => unreachable,
    };

    return struct {
        hasher: HasherType = HasherType.init(),
        rdr: ReaderType,
        wrt: WriterType,
        bytes: usize = 0,

        const Self = @This();

        pub const ReadError = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, ReadError, read);
        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
        pub fn read(self: *Self, buf: []u8) ReadError!usize {
            const n = try self.rdr.read(buf);
            self.hasher.update(buf[0..n]);
            self.bytes += n;
            return n;
        }

        pub const WriteError = WriterType.Error;
        pub const Writer = std.io.Writer(*Self, WriteError, write);
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
        pub fn write(self: *Self, buf: []const u8) WriteError!usize {
            const n = try self.wrt.write(buf);
            self.hasher.update(buf[0..n]);
            self.bytes += n;
            return n;
        }

        pub fn chksum(self: *Self) u32 {
            return self.hasher.final();
        }

        pub fn bytesRead(self: *Self) u32 {
            return @truncate(self.bytes);
        }

        pub fn parseHeader(self: *Self) !void {
            switch (kind) {
                .gzip => try self.parseGzipHeader(),
                .zlib => try self.parseZlibHeader(),
                else => {},
            }
        }

        fn parseGzipHeader(self: *Self) !void {
            const magic1 = try self.rdr.read(u8);
            const magic2 = try self.rdr.read(u8);
            const method = try self.rdr.read(u8);
            const flags = try self.rdr.read(u8);
            try self.rdr.skipBytes(6); // mtime(4), xflags, os
            if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08)
                return error.InvalidGzipHeader;
            // Flags description: https://www.rfc-editor.org/rfc/rfc1952.html#page-5
            if (flags != 0) {
                if (flags & 0b0000_0100 != 0) { // FEXTRA
                    const extra_len = try self.rdr.read(u16);
                    try self.rdr.skipBytes(extra_len);
                }
                if (flags & 0b0000_1000 != 0) { // FNAME
                    try self.rdr.skipStringZ();
                }
                if (flags & 0b0001_0000 != 0) { // FCOMMENT
                    try self.rdr.skipStringZ();
                }
                if (flags & 0b0000_0010 != 0) { // FHCRC
                    try self.rdr.skipBytes(2);
                }
            }
        }

        fn parseZlibHeader(self: *Self) !void {
            const cinfo_cm = try self.rdr.read(u8);
            _ = try self.rdr.read(u8);
            if (cinfo_cm != 0x78) {
                return error.InvalidZlibHeader;
            }
        }

        pub fn parseFooter(self: *Self) !void {
            switch (kind) {
                .gzip => {
                    if (try self.rdr.read(u32) != self.chksum()) return error.GzipFooterChecksum;
                    if (try self.rdr.read(u32) != self.bytesRead()) return error.GzipFooterSize;
                },

                .zlib => {
                    if (try self.rdr.read(u32) != self.chksum()) return error.ZlibFooterChecksum;
                },
                else => {},
            }
        }

        pub fn writeHeader(self: *Self) !void {
            switch (kind) {
                .gzip => {
                    // GZIP 10 byte header (https://datatracker.ietf.org/doc/html/rfc1952#page-5):
                    //  - ID1 (IDentification 1), always 0x1f
                    //  - ID2 (IDentification 2), always 0x8b
                    //  - CM (Compression Method), always 8 = deflate
                    //  - FLG (Flags), all set to 0
                    //  - 4 bytes, MTIME (Modification time), not used, all set to zero
                    //  - XFL (eXtra FLags), all set to zero
                    //  - OS (Operating System), 03 = Unix
                    const gzipHeader = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 };
                    try self.wrt.writeAll(&gzipHeader);
                },
                .zlib => {
                    // ZLIB has a two-byte header (https://datatracker.ietf.org/doc/html/rfc1950#page-4):
                    // 1st byte:
                    //  - First four bits is the CINFO (compression info), which is 7 for the default deflate window size.
                    //  - The next four bits is the CM (compression method), which is 8 for deflate.
                    // 2nd byte:
                    //  - Two bits is the FLEVEL (compression level). Values are: 0=fastest, 1=fast, 2=default, 3=best.
                    //  - The next bit, FDICT, is set if a dictionary is given.
                    //  - The final five FCHECK bits form a mod-31 checksum.
                    //
                    // CINFO = 7, CM = 8, FLEVEL = 0b10, FDICT = 0, FCHECK = 0b11100
                    const zlibHeader = [_]u8{ 0x78, 0b10_0_11100 };
                    try self.wrt.writeAll(&zlibHeader);
                },
                else => {},
            }
        }

        pub fn writeFooter(self: *Self) !void {
            var bits: [4]u8 = undefined;
            switch (kind) {
                .gzip => {
                    // GZIP 8 bytes footer
                    //  - 4 bytes, CRC32 (CRC-32)
                    //  - 4 bytes, ISIZE (Input SIZE) - size of the original (uncompressed) input data modulo 2^32
                    std.mem.writeInt(u32, &bits, self.chksum(), .little);
                    try self.wrt.writeAll(&bits);

                    std.mem.writeInt(u32, &bits, self.bytesRead(), .little);
                    try self.wrt.writeAll(&bits);
                },
                .zlib => {
                    // ZLIB (RFC 1950) is big-endian, unlike GZIP (RFC 1952).
                    // 4 bytes of ADLER32 (Adler-32 checksum)
                    // Checksum value of the uncompressed data (excluding any
                    // dictionary data) computed according to Adler-32
                    // algorithm.
                    std.mem.writeInt(u32, &bits, self.chksum(), .big);
                    try self.wrt.writeAll(&bits);
                },
                else => {},
            }
        }
    };
}

test "zlib FCHECK header 5 bits calculation example" {
    var h = [_]u8{ 0x78, 0b10_0_00000 };
    h[1] += 31 - @as(u8, @intCast(std.mem.readInt(u16, h[0..2], .big) % 31));
    try std.testing.expect(h[1] == 0b10_0_11100);
    // print("{x} {x} {b}\n", .{ h[0], h[1], h[1] });
}
