const dfl = @import("deflate.zig");
// pub const deflate = dfl.deflate;
//pub const gzip = dfl.gzip;
//pub const zlib = dfl.zlib;

pub const Level = dfl.Level;
pub const Options = dfl.Options;

const ifl = @import("inflate.zig");
// pub const inflate = ifl.inflate;

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}

pub const gzip = struct {
    pub fn decompress(input_reader: anytype, output_writer: anytype) !void {
        try ifl.decompressWrapped(.gzip, input_reader, output_writer);
    }
    pub const compress = dfl.gzip;
};

pub const zlib = struct {
    pub fn decompress(input_reader: anytype, output_writer: anytype) !void {
        try ifl.decompressWrapped(.zlib, input_reader, output_writer);
    }
    pub const compress = dfl.zlib;
};

pub const decompress = ifl.decompress;
pub const compress = dfl.deflate;
