const dfl = @import("deflate.zig");
pub const deflate = dfl.deflate;
pub const gzip = dfl.gzip;
pub const zlib = dfl.zlib;

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}
