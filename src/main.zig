const std = @import("std");

// zig fmt: off
    const dataBlockType01 = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7,
        0x0c, 0x00, 0x00, 0x00,
    };
    const dataBlockType00 = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff,
        'H', 'e', 'l',  'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a,
        0xd5, 0xe0, 0x39, 0xb7,
        0x0c, 0x00, 0x00, 0x00,
    };
// zig fmt: on

pub fn main() !void {
    // var fbs = std.io.fixedBufferStream(&dataBlockType01);
    // try gzStat(fbs.reader());

    const stdin = std.io.getStdIn();
    try gzStat(stdin.reader());
    //try helloWorldBlockType01();
    //try helloWorldBlockType00();
}

fn helloWorldBlockType01() !void {
    const stdout_file = std.io.getStdOut().writer();
    try stdout_file.writeAll(&dataBlockType01);
}

fn helloWorldBlockType00() !void {
    const stdout_file = std.io.getStdOut().writer();
    try stdout_file.writeAll(&dataBlockType00);
}

fn gzStat(reader: anytype) !void {
    var br = std.io.bitReader(.little, reader);
    var rd = br.reader();
    const magic1 = try rd.readByte();
    const magic2 = try rd.readByte();
    const method = try rd.readByte();
    try rd.skipBytes(7, .{}); // flags, mtime(4), xflags, os

    if (magic1 != 0x1f or magic2 != 0x8b or method != 0x08) return error.InvalidGzipHeader;

    const bfinal = try br.readBitsNoEof(u1, 1);
    const block_type = try br.readBitsNoEof(u2, 2);

    std.debug.print("{x} {x}\n", .{ bfinal, block_type });

    switch (block_type) {
        0 => unreachable,
        1 => {
            while (true) {
                const code7 = @bitReverse(try br.readBitsNoEof(u7, 7));
                std.debug.print("\ncode7: {b:0<7}", .{code7});

                if (code7 < 0b0010111) {
                    if (code7 == 0) break; // end of block
                    // 7 bits 256-279
                } else if (code7 < 0b1011111) {
                    // 8 bits 0-143
                    const code: u8 = (@as(u8, code7) << 1) + try br.readBitsNoEof(u1, 1);
                    const lit = code - 0x30;

                    std.debug.print(" code: {b:0<8}", .{code});
                    std.debug.print(" literal: 0x{x}", .{lit});
                    if (std.ascii.isPrint(lit)) {
                        std.debug.print(" {c}", .{lit});
                    }
                } else if (code7 < 0b1100011) {
                    // 8 bit 280-287
                    unreachable;
                } else { // >= 0b1100100
                    // 9 bit 144-255
                    const code: u9 = (@as(u9, code7) << 2) + @bitReverse(try br.readBitsNoEof(u2, 2));
                    const lit: u8 = @as(u8, @intCast(code - 0b110010000)) + 144;
                    std.debug.print(" code: {b:0<9}", .{code});
                    std.debug.print(" literal: 0x{x}", .{lit});
                    if (std.ascii.isPrint(lit)) {
                        std.debug.print(" {c}", .{lit});
                    }
                    // unreachable;
                }
            }
        },
        else => unreachable,
    }
}
