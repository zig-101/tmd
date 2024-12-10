const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const render = @import("tmd_to_html-render.zig");

pub fn tmd_to_html(tmdDoc: *const tmd.Doc, writer: anytype, completeHTML: bool, supportCustomBlocks: bool, suffixForIdsAndNames: []const u8, allocator: mem.Allocator) !void {
    var r = render.TmdRender{
        .doc = tmdDoc,
        .allocator = allocator,

        .supportCustomBlocks = supportCustomBlocks,
        .suffixForIdsAndNames = suffixForIdsAndNames,
    };

    if (completeHTML) {
        try writeHead1(writer);
        try r.writeTitleInHtmlHeader(writer);
        try writeHead2(writer);
        try r.render(writer, true);
        try writeFoot(writer);
    } else {
        try r.render(writer, false);
    }
}

const css_style = @embedFile("example.css");

fn writeHead1(w: anytype) !void {
    _ = try w.write(
        \\<!DOCTYPE html>
        \\<head>
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<meta charset="utf-8">
        \\<title>
    );
}

fn writeHead2(w: anytype) !void {
    _ = try w.write(
        \\</title>
        \\<style>
    );
    _ = try w.write(css_style);
    _ = try w.write(
        \\</style>
        \\</head>
        \\<body>
        \\
    );
}

fn writeFoot(w: anytype) !void {
    _ = try w.write(
        \\
        \\</body>
        \\</html>
    );
}
