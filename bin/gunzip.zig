const std = @import("std");
const gzip = @import("flate").gzip;
const print = std.debug.print;

// Comparable to standard gzip with -kf flags:
// $ gzip -kfn <file_name>
//
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    if (args.next()) |input_file_name| {
        var input_file = try std.fs.cwd().openFile(input_file_name, .{});
        defer input_file.close();

        if (!std.mem.eql(u8, input_file_name[input_file_name.len - 3 ..], ".gz")) {
            print("not a .gz file\n", .{});
            std.os.exit(1);
        }

        const output_file_name = input_file_name[0 .. input_file_name.len - 3];
        var output_file = try std.fs.cwd().createFile(output_file_name, .{ .truncate = true });
        defer output_file.close();

        var br = std.io.bufferedReader(input_file.reader());

        try gzip.decompress(br.reader(), output_file.writer());
    }
}
