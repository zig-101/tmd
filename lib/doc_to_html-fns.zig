const std = @import("std");

const tmd = @import("tmd.zig");

pub fn writeOpenTag(w: anytype, tag: []const u8, classesSeperatedBySpace: []const u8, attributes: ?*tmd.ElementAttibutes, idSuffix: []const u8, endAndWriteNewLine: ?bool) !void {
    std.debug.assert(tag.len > 0);

    _ = try w.write("<");
    _ = try w.write(tag);
    try writeBlockAttributes(w, classesSeperatedBySpace, attributes, idSuffix);
    if (endAndWriteNewLine) |write| {
        _ = try w.write(">");
        if (write) _ = try w.write("\n");
    }
}

pub fn writeCloseTag(w: anytype, tag: []const u8, writeNewLine: bool) !void {
    std.debug.assert(tag.len > 0);

    _ = try w.write("</");
    _ = try w.write(tag);
    _ = try w.write(">");
    if (writeNewLine) _ = try w.write("\n");
}

pub fn writeBareTag(w: anytype, tag: []const u8, classesSeperatedBySpace: []const u8, attributes: ?*tmd.ElementAttibutes, idSuffix: []const u8, writeNewLine: bool) !void {
    std.debug.assert(tag.len > 0);

    _ = try w.write("<");
    _ = try w.write(tag);
    _ = try w.write(" ");
    try writeBlockAttributes(w, classesSeperatedBySpace, attributes, idSuffix);
    _ = try w.write("/>");
    if (writeNewLine) _ = try w.write("\n");
}

pub fn writeBlockAttributes(w: anytype, classesSeperatedBySpace: []const u8, attributes: ?*tmd.ElementAttibutes, idSuffix: []const u8) !void {
    if (attributes) |as| {
        if (as.id.len != 0) try writeID(w, as.id, idSuffix);
        try writeClasses(w, classesSeperatedBySpace, as.classes);
    } else {
        try writeClasses(w, classesSeperatedBySpace, "");
    }
}

pub fn writeID(w: anytype, id: []const u8, idSuffix: []const u8) !void {
    _ = try w.write(" id=\"");
    _ = try w.write(id);
    if (idSuffix.len > 0) _ = try w.write(idSuffix);
    _ = try w.write("\"");
}

pub fn writeClasses(w: anytype, classesSeperatedBySpace: []const u8, classesSeperatedBySemicolon: []const u8) !void {
    if (classesSeperatedBySpace.len == 0 and classesSeperatedBySemicolon.len == 0) return;

    _ = try w.write(" class=\"");
    var needSpace = classesSeperatedBySpace.len > 0;
    if (needSpace) _ = try w.write(classesSeperatedBySpace);
    if (classesSeperatedBySemicolon.len > 0) {
        var it = std.mem.splitAny(u8, classesSeperatedBySemicolon, ";");
        var item = it.first();
        while (true) {
            if (item.len != 0) {
                if (needSpace) _ = try w.write(" ") else needSpace = true;
                _ = try w.write(item);
            }

            if (it.next()) |next| {
                item = next;
            } else break;
        }
    }
    _ = try w.write("\"");
}

pub fn writeHtmlAttributeValue(w: anytype, text: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                _ = try w.write(text[last..i]);
                _ = try w.write("&quot;");
                last = i + 1;
            },
            '\'' => {
                _ = try w.write(text[last..i]);
                _ = try w.write("&apos;");
                last = i + 1;
            },
            else => {},
        }
    }
    _ = try w.write(text[last..i]);
}

pub fn writeHtmlContentText(w: anytype, text: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '&' => {
                _ = try w.write(text[last..i]);
                _ = try w.write("&amp;");
                last = i + 1;
            },
            '<' => {
                _ = try w.write(text[last..i]);
                _ = try w.write("&lt;");
                last = i + 1;
            },
            '>' => {
                _ = try w.write(text[last..i]);
                _ = try w.write("&gt;");
                last = i + 1;
            },
            //'"' => {
            //    _ = try w.write(text[last..i]);
            //    _ = try w.write("&quot;");
            //    last = i + 1;
            //},
            //'\'' => {
            //    _ = try w.write(text[last..i]);
            //    _ = try w.write("&apos;");
            //    last = i + 1;
            //},
            else => {},
        }
    }
    _ = try w.write(text[last..i]);
}
