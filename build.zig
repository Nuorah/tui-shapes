const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tui_shape",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const collection_mod = b.addModule("collections", .{
        .root_source_file = b.path("vendor/collections/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("collections", collection_mod);

    const db_mod = b.addModule("db", .{
        .root_source_file = b.path("vendor/event_wal/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("db", db_mod);
    b.installArtifact(exe);

    exe.linkLibC();

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const db_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/db_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    db_tests.root_module.addImport("db", db_mod);
    db_tests.root_module.addImport("collections", collection_mod);

    const run_db_tests = b.addRunArtifact(db_tests);
    test_step.dependOn(&run_db_tests.step);
}
