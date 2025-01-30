const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

const maxInFileSize = 1 << 23; // 8M
const bufferSize = maxInFileSize * 8;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpaAllocator = gpa.allocator();

    const buffer = try gpaAllocator.alloc(u8, bufferSize);
    defer gpaAllocator.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);

    const args = try std.process.argsAlloc(gpaAllocator);
    defer std.process.argsFree(gpaAllocator, args);

    std.debug.assert(args.len > 0);

    if (args.len <= 1) try printUsages(0);

    if (std.mem.eql(u8, args[1], "render")) {} else try printUsages(1);

    if (args.len == 2) {
        try stderr.print("No tmd files specified.", .{});
        std.process.exit(1);
    }

    var optionsDone = false;
    var option_full_html = false;
    var option_support_custom_blocks = false;

    for (args[2..]) |arg| {

        // ToDo: improve ...
        if (std.mem.startsWith(u8, arg, "--")) blk: {
            if (optionsDone) break :blk;

            if (std.mem.eql(u8, arg[2..], "full-html")) {
                option_full_html = true;
            } else if (std.mem.eql(u8, arg[2..], "support-custom-blocks")) {
                option_support_custom_blocks = true;
            } else {
                try stderr.print("Unrecognized option: {s}", .{arg[2..]});
                std.process.exit(1);
            }

            continue;
        } else optionsDone = true;

        // load file

        const tmdFile = try std.fs.cwd().openFile(arg, .{});
        defer tmdFile.close();
        const stat = try tmdFile.stat();
        if (stat.kind != .file) {
            try stderr.print("[{s}] is not a file.\n", .{arg});
            continue;
        }
        if (stat.size > maxInFileSize) {
            try stderr.print("[{s}] size is too large ({} > {}).\n", .{ arg, stat.size, maxInFileSize });
            continue;
        }

        const tmdContent = buffer[bufferSize - stat.size ..];
        const remainingBuffer = buffer[0 .. bufferSize - maxInFileSize];

        const readSize = try tmdFile.readAll(tmdContent);
        if (stat.size != readSize) {
            try stderr.print("[{s}] read size not match ({} != {}).\n", .{ arg, stat.size, readSize });
            continue;
        }

        defer fba.reset();
        const fbaAllocator = fba.allocator();

        // parse file

        var tmdDoc = try tmd.parse_tmd(tmdContent, fbaAllocator);
        // defer tmd.destroy_doc(&tmdDoc, fbaAllocator); // if fba, then this is actually not necessary.

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

        const renderBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
        defer fbaAllocator.free(renderBuffer);
        var fbs = std.io.fixedBufferStream(renderBuffer);
        try tmd.doc_to_html(&tmdDoc, fbs.writer(), option_full_html, option_support_custom_blocks, "", gpaAllocator);

        // write file

        const htmlFile = try std.fs.cwd().createFile(outputFilename, .{});
        defer htmlFile.close();

        try htmlFile.writeAll(fbs.getWritten());

        try stdout.print(
            \\{s} ({} bytes)
            \\   -> {s} ({} bytes)
            \\
        , .{ arg, stat.size, outputFilename, fbs.getWritten().len });
    }
}

// "toolset" is better than "toolkit" here?
// https://www.difference.wiki/toolset-vs-toolkit/
fn printUsages(exitCode: u8) !void {
    try stdout.print(
        \\TapirMD toolset v{s}
        \\
        \\Usages:
        \\  tmd render [--full-html] TMD-files...
        \\
    , .{tmd.version});
    std.process.exit(exitCode);
}
