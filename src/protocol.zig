const std = @import("std");

pub const Kind = enum {
    raw, // no header or footer
    gzip, // gzip header and footer
    zlib, // zlib header and footer
};

pub fn wrapper(comptime kind: Kind, reader_or_writer: anytype) Wrapper(kind, @TypeOf(reader_or_writer)) {
    return Wrapper(kind, @TypeOf(reader_or_writer)){
        .rw = reader_or_writer,
    };
}

const NullHasher = struct {
    pub fn init() NullHasher {
        return .{};
    }
};

pub fn Wrapper(comptime kind: Kind, comptime RwType: type) type {
    const HasherType = switch (kind) {
        .gzip => std.hash.Crc32,
        .zlib => std.hash.Adler32,
        .raw => NullHasher,
    };

    return struct {
        hasher: HasherType = HasherType.init(),
        rw: RwType,
        bytes: usize = 0,

        const Self = @This();

        pub inline fn update(self: *Self, buf: []const u8) void {
            switch (kind) {
                .raw => {},
                else => {
                    self.hasher.update(buf);
                    self.bytes += buf.len;
                },
            }
        }

        pub fn chksum(self: *Self) u32 {
            switch (kind) {
                .raw => return 0,
                else => return self.hasher.final(),
            }
        }

        pub fn bytesRead(self: *Self) u32 {
            return @truncate(self.bytes);
        }

        pub fn parseHeader(self: *Self) !void {
            switch (kind) {
                .gzip => try self.parseGzipHeader(),
                .zlib => try self.parseZlibHeader(),
                .raw => {},
            }
        }

        fn parseGzipHeader(self: *Self) !void {
            const magic1 = try self.rw.read(u8);
            const magic2 = try self.rw.read(u8);
            const method = try self.rw.read(u8);
            const flags = try self.rw.read(u8);
            try self.rw.skipBytes(6); // mtime(4), xflags, os
            if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08)
                return error.InvalidGzipHeader;
            // Flags description: https://www.rfc-editor.org/rfc/rfc1952.html#page-5
            if (flags != 0) {
                if (flags & 0b0000_0100 != 0) { // FEXTRA
                    const extra_len = try self.rw.read(u16);
                    try self.rw.skipBytes(extra_len);
                }
                if (flags & 0b0000_1000 != 0) { // FNAME
                    try self.rw.skipStringZ();
                }
                if (flags & 0b0001_0000 != 0) { // FCOMMENT
                    try self.rw.skipStringZ();
                }
                if (flags & 0b0000_0010 != 0) { // FHCRC
                    try self.rw.skipBytes(2);
                }
            }
        }

        fn parseZlibHeader(self: *Self) !void {
            const cinfo_cm = try self.rw.read(u8);
            _ = try self.rw.read(u8);
            if (cinfo_cm != 0x78) {
                return error.InvalidZlibHeader;
            }
        }

        pub fn parseFooter(self: *Self) !void {
            switch (kind) {
                .gzip => {
                    if (try self.rw.read(u32) != self.chksum()) return error.GzipFooterChecksum;
                    if (try self.rw.read(u32) != self.bytesRead()) return error.GzipFooterSize;
                },
                .zlib => {
                    if (try self.rw.read(u32) != self.chksum()) return error.ZlibFooterChecksum;
                },
                .raw => {},
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
                    try self.rw.writeAll(&gzipHeader);
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
                    try self.rw.writeAll(&zlibHeader);
                },
                .raw => {},
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
                    try self.rw.writeAll(&bits);

                    std.mem.writeInt(u32, &bits, self.bytesRead(), .little);
                    try self.rw.writeAll(&bits);
                },
                .zlib => {
                    // ZLIB (RFC 1950) is big-endian, unlike GZIP (RFC 1952).
                    // 4 bytes of ADLER32 (Adler-32 checksum)
                    // Checksum value of the uncompressed data (excluding any
                    // dictionary data) computed according to Adler-32
                    // algorithm.
                    std.mem.writeInt(u32, &bits, self.chksum(), .big);
                    try self.rw.writeAll(&bits);
                },
                .raw => {},
            }
        }
    };
}
