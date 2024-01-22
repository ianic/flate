const dfl = @import("deflate.zig");
pub const deflate = dfl.deflate;
pub const gzip = dfl.gzip;
pub const zlib = dfl.zlib;

pub const inflate = @import("inflate.zig").inflate;

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}
