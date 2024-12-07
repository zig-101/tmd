const std = @import("std");

pub fn build(b: *std.Build) !void {
    const config = collectConfig(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // lib (ToDo: something not right here, the output is only 4.4k?)

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

    // tmd module

    const tmdLibModule = b.addModule("tmd", .{
        .root_source_file = b.path("lib/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libOptions = b.addOptions();
    libOptions.addOption(bool, "dump_ast", config.dumpAST);
    tmdLibModule.addOptions("config", libOptions);

    // cmd

    const tmdCommand = b.addExecutable(.{
        .name = "tmd",
        .root_source_file = b.path("cmd/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    tmdCommand.root_module.addImport("tmd", tmdLibModule);
    b.installArtifact(tmdCommand);

    // run cmd

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

    // wasm

    const wasmTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addExecutable(.{
        .name = "tmd",
        .root_source_file = b.path("wasm/tmd.zig"),
        .target = wasmTarget,
        .optimize = .ReleaseSmall,
    });

    // <https://github.com/ziglang/zig/issues/8633>
    //wasm.global_base = 8192; // What is the meaning? Some runtimes have requirements on this?
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // It looks the program itself need minimum memory between 1M and 1.5M initially.
    // The program will dynamically allocate about 10M at run time.
    // But why is the max_memory required to be set so large?
    wasm.max_memory = (1 << 24) + (1 << 21);

    wasm.root_module.addImport("tmd", tmdLibModule);
    b.installArtifact(wasm);
}

const Config = struct {
    dumpAST: bool = false,
};

fn collectConfig(b: *std.Build) Config {
    var c = Config{};

    if (b.option(bool, "dump_ast", "dump doc AST")) |dump|
        c.dumpAST = dump;
    
    return c;
}