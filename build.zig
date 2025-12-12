const std = @import("std");

fn getVersion(b: *std.Build) []const u8 {
    // Get the directory where this build.zig lives
    const src_dir = std.fs.path.dirname(@src().file) orelse ".";
    var exit_code: u8 = 0;
    const git_hash = b.runAllowFail(&[_][]const u8{
        "git", "-C", src_dir, "rev-parse", "HEAD",
    }, &exit_code, .Inherit) catch return "unknown";
    return std.mem.trim(u8, git_hash, &std.ascii.whitespace);
}

/// Creates the zeit module with injected dependencies.
/// Use this when incorporating zeit as a dependency to share modules with parent.
pub fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_source_file: std.Build.LazyPath,
) *std.Build.Module {
    const zeit_mod = b.addModule("zeit", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", getVersion(b));
    zeit_mod.addOptions("build_options", options);

    return zeit_mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("zeit", .{
        .root_source_file = b.path("src/zeit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", getVersion(b));
    root_module.addOptions("build_options", options);

    const lib_unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const gen_step = b.step("generate", "Update timezone names");
    const gen = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const fmt = b.addFmt(
        .{ .paths = &.{"src/location.zig"} },
    );
    const gen_run = b.addRunArtifact(gen);
    fmt.step.dependOn(&gen_run.step);
    gen_step.dependOn(&fmt.step);

    // Docs
    {
        const docs_step = b.step("docs", "Build the zeit docs");
        const docs_obj = b.addObject(.{
            .name = "zeit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zeit.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const docs = docs_obj.getEmittedDocs();
        docs_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = docs,
            .install_dir = .prefix,
            .install_subdir = "docs",
        }).step);
    }
}
