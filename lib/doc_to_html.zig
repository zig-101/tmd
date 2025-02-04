const std = @import("std");

const tmd = @import("tmd.zig");

pub fn doc_to_html(writer: anytype, tmdDoc: *const tmd.Doc, completeHTML: bool, supportCustomBlocks: bool, suffixForIdsAndNames: []const u8, allocator: std.mem.Allocator) !void {
    var r = @import("doc_to_html-render.zig").TmdRender{
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
