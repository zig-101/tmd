const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

const tmd = @import("tmd.zig");

// ToDo: remove the following parse functions (use tokens instead)?

// Only check id and class names for epub output.
//
// EPUB 3.3 (from ChatGPT):
//
// IDs
// * They must start with a letter (a-z or A-Z) or underscore (_).
// * They can include letters, digits (0-9), hyphens (-), underscores (_), and periods (.).
// * They cannot contain spaces or special characters.
//
// Class names:
// * They can start with a letter (a-z or A-Z) or an underscore (_).
// * They can include letters, digits (0-9), hyphens (-), underscores (_), and periods (.).
// * They cannot contain spaces or special characters.
//
// Attribute names:
// * Attribute names must begin with a letter (a-z or A-Z) or an underscore (_).
// * They can include letters, digits (0-9), hyphens (-), and underscores (_).
// * They cannot contain spaces or special characters.

// Use HTML4 spec:
//     ID and NAME tokens must begin with a letter ([A-Za-z]) and
//     may be followed by any number of letters, digits ([0-9]),
//     hyphens ("-"), underscores ("_"), colons (":"), and periods (".").
const charIdLevels = blk: {
    var table = [1]u3{0} ** 127;

    for ('a'..'z' + 1, 'A'..'Z' + 1) |i, j| {
        table[i] = 6;
        table[j] = 6;
    }
    for ('0'..'9' + 1) |i| table[i] = 5;
    table['_'] = 4;
    table['-'] = 3;
    table[':'] = 2;
    table['.'] = 1;
    break :blk table;
};

pub fn parse_element_attributes(playload: []const u8) tmd.ElementAttibutes {
    var attrs = tmd.ElementAttibutes{};

    const id = std.meta.fieldIndex(tmd.ElementAttibutes, "id").?;
    const classes = std.meta.fieldIndex(tmd.ElementAttibutes, "classes").?;
    const kvs = std.meta.fieldIndex(tmd.ElementAttibutes, "kvs").?;

    var lastOrder: isize = -1;
    var kvList: ?struct {
        first: []const u8,
        last: []const u8,
    } = null;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '#' => {
                    if (lastOrder >= id) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or charIdLevels[item[1]] != 6) break;
                    for (item[2..]) |c| {
                        if (c >= 128 or charIdLevels[c] < 1) break :parse;
                    }
                    attrs.id = item[1..];
                    lastOrder = id;
                },
                '.' => {
                    // classes can't contain periods, but can contain colons.
                    // (This is TMD specific. HTML4 allows periods in classes).

                    // classes are seperated by semicolons.

                    // ToDo: support .class1 .class2?

                    if (lastOrder >= classes) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or charIdLevels[item[1]] != 6) break;
                    for (item[2..]) |c| {
                        if (c == ';') continue; // seperators (TMD specific)
                        if (c >= 128 or charIdLevels[c] < 2) break :parse;
                    }

                    attrs.classes = item[1..];
                    lastOrder = classes;
                },
                else => {
                    // key-value pairs are seperated by SPACE or TAB chars.
                    // Key parsing is the same as ID parsing.
                    // Values containing SPACE and TAB chars must be quoted in `...` (the Go literal string form).

                    if (lastOrder > kvs) break;

                    if (item.len < 3) break;

                    // ToDo: write a more pricise implementation.

                    if (std.mem.indexOfScalar(u8, item, '=')) |i| {
                        if (0 < i and i < item.len - 1) {
                            if (kvList == null) kvList = .{ .first = item, .last = item } else kvList.?.last = item;
                        } else break;
                    } else break;

                    lastOrder = kvs;
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    if (kvList) |v| {
        const start = @intFromPtr(v.first.ptr);
        const end = @intFromPtr(v.last.ptr + v.last.len);
        attrs.kvs = v.first.ptr[0 .. end - start];
    }

    return attrs;
}

pub fn parse_base_block_open_playload(playload: []const u8) tmd.BaseBlockAttibutes {
    var attrs = tmd.BaseBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "commentedOut").?;
    const horizontalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "horizontalAlign").?;
    const verticalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "verticalAlign").?;
    const cellSpans = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "cellSpans").?;

    var lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    defer lastOrder = commentedOut;

                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                },
                '>', '<' => {
                    if (lastOrder >= horizontalAlign) break;
                    defer lastOrder = horizontalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '>' and item[1] != '<') break;
                    if (mem.eql(u8, item, "<<"))
                        attrs.horizontalAlign = .left
                    else if (mem.eql(u8, item, ">>"))
                        attrs.horizontalAlign = .right
                    else if (mem.eql(u8, item, "><"))
                        attrs.horizontalAlign = .center
                    else if (mem.eql(u8, item, "<>"))
                        attrs.horizontalAlign = .justify;
                },
                '^' => {
                    if (lastOrder >= verticalAlign) break;
                    defer lastOrder = verticalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '^') break;
                    attrs.verticalAlign = .top;
                },
                '.' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 3) break;
                    if (item[1] != '.') break;
                    const trimDotDot = item[2..];
                    const colonPos = std.mem.indexOfScalar(u8, trimDotDot, ':') orelse trimDotDot.len;
                    if (colonPos == 0 or colonPos == trimDotDot.len - 1) break;
                    const axisSpan = std.fmt.parseInt(u32, trimDotDot[0..colonPos], 10) catch break;
                    const crossSpan = if (colonPos == trimDotDot.len) 1 else std.fmt.parseInt(u32, trimDotDot[colonPos + 1 ..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = axisSpan,
                        .crossSpan = crossSpan,
                    };
                },
                ':' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 2) break;
                    const crossSpan = std.fmt.parseInt(u32, item[1..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = 1,
                        .crossSpan = crossSpan,
                    };
                },
                else => {
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

pub fn parse_code_block_open_playload(playload: []const u8) tmd.CodeBlockAttibutes {
    var attrs = tmd.CodeBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "commentedOut").?;
    //const language = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "language").?;

    const lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    if (item.len > 0) {
                        attrs.language = item;
                    }
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

pub fn parse_code_block_close_playload(playload: []const u8) tmd.ContentStreamAttributes {
    var attrs = tmd.ContentStreamAttributes{};

    var arrowFound = false;
    var content: []const u8 = "";

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) {
            if (!arrowFound) {
                if (item.len != 2) return attrs;
                for (item) |c| if (c != '<') return attrs;
                arrowFound = true;
            } else if (content.len > 0) {
                return attrs;
            } else if (item.len > 0) {
                content = item;
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    attrs.content = content;
    return attrs;
}

pub fn parse_custom_block_open_playload(playload: []const u8) tmd.CustomBlockAttibutes {
    var attrs = tmd.CustomBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "commentedOut").?;
    //const app = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "app").?;

    const lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    if (item.len > 0) {
                        attrs.app = item;
                    }
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

pub fn isValidLinkURL(text: []const u8) bool {
    // ToDo: more precisely and performant.

    if (ascii.startsWithIgnoreCase(text, "#")) return true;
    if (ascii.startsWithIgnoreCase(text, "http")) {
        const t = text[4..];
        if (ascii.startsWithIgnoreCase(t, "s://")) return true;
        if (ascii.startsWithIgnoreCase(t, "://")) return true;
    }

    const t = if (mem.indexOfScalar(u8, text, '#')) |k| blk: {
        const t = text[0..k];
        //if (ascii.endsWithIgnoreCase(t, ".tmd")) return true;
        break :blk t;
    } else text;

    if (ascii.endsWithIgnoreCase(t, ".htm")) return true;
    if (ascii.endsWithIgnoreCase(t, ".html")) return true;

    return false;
}

test "isValidLinkURL" {
    std.debug.assert(isValidLinkURL("http://aaa"));
    std.debug.assert(isValidLinkURL("https://aaa"));
    std.debug.assert(false == isValidLinkURL("http:"));
    std.debug.assert(false == isValidLinkURL("https"));
    std.debug.assert(isValidLinkURL("foo.htm"));
    std.debug.assert(isValidLinkURL("foo.html#bar"));
    std.debug.assert(isValidLinkURL("foo.htm#bar"));
    std.debug.assert(isValidLinkURL("foo.html"));
    //std.debug.assert(isValidLinkURL("foo.tmd#"));
    std.debug.assert(isValidLinkURL("#"));
    std.debug.assert(isValidLinkURL("#bar"));
}

// ToDo: more
const supportedMediaExts = [_][]const u8{
    ".png",
    ".gif",
    ".jpg",
    ".jpeg",
};

pub fn isValidMediaURL(src: []const u8) bool {
    // ToDo: more precisely and performant.

    //next: {
    //    //if (std.mem.startsWith(u8, src, "./") break :next;
    //    //if (std.mem.startsWith(u8, src, "../") break :next;
    //    if (ascii.startsWithIgnoreCase(text, "http")) {
    //        const t = text[4..];
    //        if (ascii.startsWithIgnoreCase(t, "s://")) break :next;
    //        if (ascii.startsWithIgnoreCase(t, "://")) break :next;
    //    }
    //}

    for (supportedMediaExts) |ext| {
        if (ascii.endsWithIgnoreCase(src, ext)) return true;
    }

    return false;
}

test "isValidMediaURL" {
    std.testing.expect(isValidMediaURL("foo.png"));
    std.testing.expect(!isValidMediaURL("foo.xxxxx"));
}
