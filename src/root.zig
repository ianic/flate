const deflate = @import("deflate.zig");
const inflate = @import("inflate.zig");

pub const Level = deflate.Level;
pub const Options = deflate.Options;

pub const decompress = inflate.decompress;

pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
    try deflate.compress(.raw, reader, writer, options);
}

pub fn compressor(writer: anytype, options: Options) !void {
    try deflate.compressor(.raw, writer, options);
}

pub const gzip = struct {
    pub const decompress = inflate.gzip;

    pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
        try deflate.compress(.gzip, reader, writer, options);
    }

    pub fn compressor(writer: anytype, options: Options) !deflate.Compressor(.gzip, @TypeOf(writer)) {
        return try deflate.compressor(.gzip, writer, options);
    }
};

pub const zlib = struct {
    pub const decompress = inflate.zlib;

    pub fn compress(reader: anytype, writer: anytype, options: Options) !void {
        try deflate.compress(.zlib, reader, writer, options);
    }

    pub fn compressor(writer: anytype, options: Options) !deflate.Compressor(.zlib, @TypeOf(writer)) {
        return try deflate.compressor(.zlib, writer, options);
    }
};

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}
