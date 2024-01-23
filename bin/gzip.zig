const std = @import("std");
const flate = @import("flate");

// Comparable to standard gzip with -kf flags:
// $ gzip -kfn <file_name>
//
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    if (args.next()) |input_file_name| {
        var input_file = try std.fs.cwd().openFile(input_file_name, .{});
        defer input_file.close();

        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const output_file_name = try std.fmt.bufPrint(&buf, "{s}.gz", .{input_file_name});
        var output_file = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
        defer output_file.close();

        try flate.gzip(input_file.reader(), output_file.writer());
    }
}
