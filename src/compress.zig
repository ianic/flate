pub const flate = @import("flate.zig");
pub const gzip = @import("gzip.zig");
pub const zlib = @import("zlib.zig");

pub const v1 = struct {
    pub const deflate = @import("v1/deflate.zig");
    pub const gzip = @import("v1/gzip.zig");
    pub const zlib = @import("v1/zlib.zig");
};

test {
    _ = flate;
    _ = gzip;
    _ = zlib;
}
