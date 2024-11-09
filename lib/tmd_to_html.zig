const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const render = @import("tmd_to_html-render.zig");

pub fn tmd_to_html(tmdDoc: tmd.Doc, writer: anytype, completeHTML: bool, allocator: mem.Allocator) !void {
    var r = render.TmdRender{
        .doc = tmdDoc,
        .allocator = allocator,
    };
    if (completeHTML) {
        try writeHead(writer);
        try r.render(writer, true);
        try writeFoot(writer);
    } else {
        try r.render(writer, false);
    }
}

const css_style = @embedFile("example.css");

fn writeHead(w: anytype) !void {
    _ = try w.write(
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>Tapir's Markdown Format</title>
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
