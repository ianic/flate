const deflate = @import("deflate.zig");
const inflate = @import("inflate.zig");

pub const Level = deflate.Level;
pub const Options = deflate.Options;

pub const decompress = inflate.decompress;
pub const compress = deflate.compress;

pub const gzip = struct {
    pub const decompress = inflate.gzip;
    pub const compress = deflate.gzip;
};

pub const zlib = struct {
    pub const decompress = inflate.zlib;
    pub const compress = deflate.zlib;
};

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}
