const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // lib
    const tmdLib = b.addStaticLibrary(.{
        .name = "tmd",
        .root_source_file = b.path("lib/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(tmdLib);

    // test
    const unitTest = b.addTest(.{
        .name = "unit_test",
        .root_source_file = b.path("lib/tests.zig"),
        .target = b.host,
    });
    b.installArtifact(unitTest);
    const runtTests = b.addRunArtifact(unitTest);
    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&runtTests.step);

    // cmd
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

    // run

    const runTmdCommand = b.addRunArtifact(tmdCommand);
    if (b.args) |args| runTmdCommand.addArgs(args);

    const runStep = b.step("run", "Run tmd command");
    runStep.dependOn(&runTmdCommand.step);

    // doc

    const websitePagesPath = b.path("doc/pages");
    const buildWebsiteCommand = b.addRunArtifact(tmdCommand);
    buildWebsiteCommand.setCwd(websitePagesPath);
    buildWebsiteCommand.addArg("render");
    buildWebsiteCommand.addArg("--full-html");

    var websitePagesDir = try std.fs.openDirAbsolute(websitePagesPath.getPath(b), .{ .no_follow = true, .access_sub_paths = false, .iterate = true });
    var walker = try websitePagesDir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".tmd")) continue;

        buildWebsiteCommand.addArg(entry.basename);
    }

    const buildDoc = b.step("doc", "Build doc");
    buildDoc.dependOn(&buildWebsiteCommand.step);
}
