const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "ztunnel",
        .root_module = exe_mod,
    });

    const check_exe = b.addExecutable(.{
        .name = "ztunnel",
        .root_module = exe_mod,
    });
    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&check_exe.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/main.zig", "src/headers.zig", "src/target.zig", "src/response.zig" }) |source| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
