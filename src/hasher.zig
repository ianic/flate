const std = @import("std");

pub const Wrapping = enum {
    raw, // no header or footer
    gzip, // gzip header and footer
    zlib, // zlib header and footer
};

pub fn Hasher(comptime wrap: Wrapping) type {
    const HasherType = switch (wrap) {
        .gzip => std.hash.Crc32,
        .zlib => std.hash.Adler32,
        .raw => struct {
            pub fn init() @This() {
                return .{};
            }
        },
    };

    return struct {
        hasher: HasherType = HasherType.init(),
        bytes: usize = 0,

        const Self = @This();

        pub inline fn update(self: *Self, buf: []const u8) void {
            switch (wrap) {
                .raw => {},
                else => {
                    self.hasher.update(buf);
                    self.bytes += buf.len;
                },
            }
        }

        pub fn chksum(self: *Self) u32 {
            switch (wrap) {
                .raw => return 0,
                else => return self.hasher.final(),
            }
        }

        pub fn bytesRead(self: *Self) u32 {
            return @truncate(self.bytes);
        }
    };
}
