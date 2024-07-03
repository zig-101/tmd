const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");
//const tmd_parser = @import("tmd_parser.zig");
//const tmd_to_html = @import("tmd_to_html.zig");

const demo3 = @embedFile("demo3.tmd");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpaAllocator = gpa.allocator();

    const MaxInFileSize = 1 << 20;
    const MaxDocDataSize = 1 << 20;
    const MaxOutFileSize = 8 << 20;
    const FixedBufferSize = MaxInFileSize + MaxDocDataSize + MaxOutFileSize;
    const fixedBuffer = try gpaAllocator.alloc(u8, FixedBufferSize);
    defer gpaAllocator.free(fixedBuffer);
    var fba = std.heap.FixedBufferAllocator.init(fixedBuffer);
    const fbaAllocator = fba.allocator();

    const args = try std.process.argsAlloc(gpaAllocator);
    defer std.process.argsFree(gpaAllocator, args);

    std.debug.assert(args.len > 0);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len <= 1 or !std.mem.eql(u8, args[1], "render")) {
        try stdout.print(
            \\Usage:
            \\  tmd render [--full-html] TMD-FILES...
            \\
        , .{});
        std.process.exit(1);
    }

    if (args.len == 2) {
        try stderr.print("No tmd files specified.", .{});
        std.process.exit(1);
    }

    var optionsDone = false;
    var option_full_html = false;

    for (args[2..]) |arg| {

        // ToDo: improve ...
        if (std.mem.startsWith(u8, arg, "--")) blk: {
            if (optionsDone) break :blk;

            if (std.mem.eql(u8, arg[2..], "full-html")) {
                option_full_html = true;
            }

            continue;
        } else optionsDone = true;

        // load file

        defer fba.reset();

        const tmdFile = try std.fs.cwd().openFile(arg, .{});
        defer tmdFile.close();
        const stat = try tmdFile.stat();
        if (stat.kind != .file) try stderr.print("[{s}] is not a file.\n", .{arg});

        const tmdContent = try tmdFile.readToEndAlloc(fbaAllocator, MaxInFileSize);
        defer fbaAllocator.free(tmdContent);

        std.debug.assert(tmdContent.len == stat.size);

        // parse file

        var tmdDoc = try tmd.parser.parse_tmd_doc(tmdContent, fbaAllocator);
        defer tmd.parser.destroy_tmd_doc(&tmdDoc, fbaAllocator); // if fba, then this is actually not necessary.

        // render file

        const htmlExt = ".html";
        const tmdExt = ".tmd";
        var outputFilePath: [1024]u8 = undefined;
        var outputFilename: []u8 = undefined;
        if (std.ascii.endsWithIgnoreCase(arg, tmdExt)) {
            if (arg.len - tmdExt.len + htmlExt.len > outputFilePath.len)
                return error.InputFileNameTooLong;
            outputFilename = arg[0 .. arg.len - tmdExt.len];
        } else {
            if (arg.len + htmlExt.len > outputFilePath.len)
                return error.InputFileNameTooLong;
            outputFilename = arg;
        }
        std.mem.copyBackwards(u8, outputFilePath[0..], outputFilename);
        std.mem.copyBackwards(u8, outputFilePath[outputFilename.len..], htmlExt);
        outputFilename = outputFilePath[0 .. outputFilename.len + htmlExt.len];

        const renderBuffer = try fbaAllocator.alloc(u8, MaxOutFileSize);
        defer fbaAllocator.free(renderBuffer);
        var fbs = std.io.fixedBufferStream(renderBuffer);
        try tmd.render.tmd_to_html(tmdDoc, fbs.writer(), option_full_html);

        // write file

        const htmlFile = try std.fs.cwd().createFile(outputFilename, .{});
        defer htmlFile.close();

        try htmlFile.writeAll(fbs.getWritten());

        try stdout.print(
            \\tmd file: {s} ({} bytes)
            \\  -> {s} ({} bytes)
            \\
        , .{ arg, stat.size, outputFilename, fbs.getWritten().len });
    }
}
