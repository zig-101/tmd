const std = @import("std");

pub fn build(b: *std.Build) !void {
    const config = collectConfig(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // lib (ToDo: something not right here, the output is only 4.4k?
    //     Need to export the pub elements?)
    //
    //const tmdLib = b.addStaticLibrary(.{
    //    .name = "tmd",
    //    .root_source_file = b.path("lib/tmd.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const installLib = b.addInstallArtifact(tmdLib, .{});
    //
    //const libStep = b.step("lib", "Install lib");
    //libStep.dependOn(&installLib.step);

    // test

    const unitTest = b.addTest(.{
        .name = "unit_test",
        .root_source_file = b.path("lib/tests.zig"),
        .target = b.host,
    });
    const installTest = b.addInstallArtifact(unitTest, .{});

    const runtTests = b.addRunArtifact(unitTest);
    runtTests.step.dependOn(&installTest.step);

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

    // cmd (the default target)

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
    wasm.max_memory = (1 << 24) + (1 << 21); // 18M

    wasm.root_module.addImport("tmd", tmdLibModule);
    const installWasm = b.addInstallArtifact(wasm, .{});

    const wasmStep = b.step("wasm", "Install wasm");
    wasmStep.dependOn(&installWasm.step);

    // doc

    const buildWebsiteCommand = b.addRunArtifact(tmdCommand);
    buildWebsiteCommand.step.dependOn(&installWasm.step);

    const websitePagesPath = b.path("doc/pages");

    buildWebsiteCommand.setCwd(websitePagesPath);
    buildWebsiteCommand.addArg("render");
    buildWebsiteCommand.addArg("--full-html");
    buildWebsiteCommand.addArg("--support-custom-blocks");

    var websitePagesDir = try std.fs.openDirAbsolute(websitePagesPath.getPath(b), .{ .no_follow = true, .access_sub_paths = false, .iterate = true });
    var walker = try websitePagesDir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".tmd")) continue;

        buildWebsiteCommand.addArg(entry.basename);
    }

    const CompletePlayPage = struct {
        step: std.Build.Step,
        docPagesPath: std.fs.Dir,
        wasmInstallArtifact: *std.Build.Step.InstallArtifact,

        pub fn create(theBuild: *std.Build, docPath: std.fs.Dir, wasmInstall: *std.Build.Step.InstallArtifact) !*@This() {
            const self = try theBuild.allocator.create(@This());
            self.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "complete play page",
                    .owner = theBuild,
                    .makeFn = make,
                }),
                .docPagesPath = docPath,
                .wasmInstallArtifact = wasmInstall,
            };
            return self;
        }

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const self: *@This() = @fieldParentPtr("step", step);

            const needle = "<wasm-file-as-base64-string>";

            const binPathName = @tagName(self.wasmInstallArtifact.dest_dir.?);
            const wasmFileName = self.wasmInstallArtifact.dest_sub_path;

            const theBuild = step.owner;
            const oldContent = try self.docPagesPath.readFileAlloc(theBuild.allocator, "play.html", 1 << 19);
            if (std.mem.indexOf(u8, oldContent, needle)) |k| {
                const installDir = try std.fs.openDirAbsolute(theBuild.install_path, .{ .no_follow = true, .access_sub_paths = true, .iterate = false });
                const binDir = try installDir.openDir(binPathName, .{ .no_follow = true, .access_sub_paths = true, .iterate = false });
                const wasmContent = try binDir.readFileAlloc(theBuild.allocator, wasmFileName, 1 << 19);
                const file = try self.docPagesPath.createFile("play.html", .{ .truncate = true });
                defer file.close();
                try file.writeAll(oldContent[0..k]);
                try std.base64.standard.Encoder.encodeWriter(file.writer(), wasmContent);
                try file.writeAll(oldContent[k + needle.len ..]);
            } else return error.WasmNeedleNotFound;
        }
    };

    const completePlayPage = try CompletePlayPage.create(b, websitePagesDir, installWasm);
    completePlayPage.step.dependOn(&buildWebsiteCommand.step);

    const buildDoc = b.step("doc", "Build doc");
    buildDoc.dependOn(&completePlayPage.step);
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
