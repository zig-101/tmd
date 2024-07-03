const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tmdLibModule = b.addModule("tmd", .{
        .root_source_file = b.path("lib/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tmdCommand = b.addExecutable(.{
        .name = "tmd",
        .root_source_file = b.path("cmd/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    tmdCommand.root_module.addImport("tmd", tmdLibModule);
    b.installArtifact(tmdCommand);

    const runTmdCommand = b.addRunArtifact(tmdCommand);
    if (b.args) |args| runTmdCommand.addArgs(args);

    const runStep = b.step("run", "Run tmd command");
    runStep.dependOn(&runTmdCommand.step);
}