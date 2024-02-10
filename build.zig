const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "deflate",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/flate.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/flate.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const flate_module = b.addModule("flate", .{
        .root_source_file = .{ .path = "src/flate.zig" },
    });

    const binaries = [_]Binary{
        .{ .name = "gzip", .src = "bin/gzip.zig" },
        .{ .name = "gunzip", .src = "bin/gunzip.zig" },
        .{ .name = "decompress", .src = "bin/decompress.zig" },
        .{ .name = "roundtrip", .src = "bin/roundtrip.zig" },
    };
    for (binaries) |i| {
        const bin = b.addExecutable(.{
            .name = i.name,
            .root_source_file = .{ .path = i.src },
            .target = target,
            .optimize = optimize,
        });
        bin.root_module.addImport("flate", flate_module);
        b.installArtifact(bin);
    }

    // Benchmarks are embedding bin/bench_data files which has to be present.
    // There is script `get_bench_data.sh` to fill the folder. Some of those
    // files are pretty big so it is not committed to the repo. If you are
    // building many times clear your zig-cache because it can be filled with
    // lots of copies of this files embedded into binaries.
    const bench_step = b.step("bench", "Build benchhmarks");

    const benchmarks = [_]Binary{
        .{ .name = "deflate_bench", .src = "bin/deflate_bench.zig" },
        .{ .name = "inflate_bench", .src = "bin/inflate_bench.zig" },
    };
    for (benchmarks) |i| {
        var bin = b.addExecutable(.{
            .name = i.name,
            .root_source_file = .{ .path = i.src },
            .target = target,
            .optimize = optimize,
        });
        bin.root_module.addImport("flate", flate_module);
        bench_step.dependOn(&b.addInstallArtifact(bin, .{}).step);
    }
}

const Binary = struct {
    name: []const u8,
    src: []const u8,
};
