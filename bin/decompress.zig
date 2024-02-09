const std = @import("std");
const flate = @import("flate");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    // Try to parse the data
    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();
    var inflate = flate.raw.decompressor(reader);

    const inflated = inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch |err| {
        std.debug.print("{}\n", .{err});
        return;
    };
    defer allocator.free(inflated);
    std.debug.print("OK len: {d}\n", .{inflated.len});
}
