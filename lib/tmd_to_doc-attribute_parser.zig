const std = @import("std");

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

// HTML4 spec:
//     ID and NAME tokens must begin with a letter ([A-Za-z]) and
//     may be followed by any number of letters, digits ([0-9]),
//     hyphens ("-"), underscores ("_"), colons (":"), and periods (".").

// Only for ASCII chars in range[0, 127].
const charPropertiesTable = blk: {
    var table = [1]packed struct {
        canBeFirstInID: bool = false,
        canBeInID: bool = false,

        canBeFirstInClassName: bool = false,
        canBeInClassName: bool = false,

        canBeInLanguageName: bool = false,

        canBeInAppName: bool = false,
    }{.{}} ** 128;

    for ('a'..'z' + 1, 'A'..'Z' + 1) |i, j| {
        table[i].canBeFirstInID = true;
        table[j].canBeFirstInID = true;

        table[i].canBeInID = true;
        table[j].canBeInID = true;

        table[i].canBeFirstInClassName = true;
        table[j].canBeFirstInClassName = true;

        table[i].canBeInClassName = true;
        table[j].canBeInClassName = true;
    }

    for ('0'..'9' + 1) |i| {
        table[i].canBeInID = true;
        table[i].canBeInClassName = true;
    }

    // Yes, TapirMD is more stricted here.
    //for ("_") |i| {
    //    table[i].canBeFirstInID = true;
    //    table[i].canBeFirstInClassName = true;
    //}

    // Yes, TapirMD is less stricted here, by extra allowing `:`,
    // to work with TailWind CSS alike frameworks.
    for (".-:") |i| {
        table[i].canBeInID = true;
        table[i].canBeInClassName = true;
    }

    // Any visible chars (not including spaces).
    // Unicode with value >= 128 are also valid.
    for (33..127) |i| {
        table[i].canBeInLanguageName = true;
        table[i].canBeInAppName = true;
    }

    break :blk table;
};

pub fn parse_element_attributes(playload: []const u8) tmd.ElementAttibutes {
    var attrs = tmd.ElementAttibutes{};

    const id = std.meta.fieldIndex(tmd.ElementAttibutes, "id").?;
    const classes = std.meta.fieldIndex(tmd.ElementAttibutes, "classes").?;
    //const kvs = std.meta.fieldIndex(tmd.ElementAttibutes, "kvs").?;

    var lastOrder: isize = -1;
    // var kvList: ?struct {
    //     first: []const u8,
    //     last: []const u8,
    // } = null;

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '#' => {
                    if (lastOrder >= id) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or !charPropertiesTable[item[1]].canBeFirstInID) break;
                    for (item[2..]) |c| {
                        if (c >= 128 or !charPropertiesTable[c].canBeInID) break :parse;
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
                    var firstInName = true;
                    for (item[1..]) |c| {
                        if (c == ';') {
                            firstInName = true;
                            continue; // seperators (TMD specific)
                        }
                        if (c >= 128) break :parse;
                        if (firstInName) {
                            if (!charPropertiesTable[c].canBeFirstInClassName) break :parse;
                        } else {
                            if (!charPropertiesTable[c].canBeInClassName) break :parse;
                        }
                    }

                    attrs.classes = item[1..];
                    lastOrder = classes;
                },
                else => {
                    break; // break the loop (kvs is not supported now)

                    // // key-value pairs are seperated by SPACE or TAB chars.
                    // // Key parsing is the same as ID parsing.
                    // // Values containing SPACE and TAB chars must be quoted in `...` (the Go literal string form).
                    //
                    // if (lastOrder > kvs) break;
                    //
                    // if (item.len < 3) break;
                    //
                    // // ToDo: write a more pricise implementation.
                    //
                    // if (std.mem.indexOfScalar(u8, item, '=')) |i| {
                    //     if (0 < i and i < item.len - 1) {
                    //         if (kvList == null) kvList = .{ .first = item, .last = item } else kvList.?.last = item;
                    //     } else break;
                    // } else break;
                    //
                    // lastOrder = kvs;
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    // if (kvList) |v| {
    //     const start = @intFromPtr(v.first.ptr);
    //     const end = @intFromPtr(v.last.ptr + v.last.len);
    //     attrs.kvs = v.first.ptr[0 .. end - start];
    // }

    return attrs;
}

test "parse_element_attributes" {
    try std.testing.expectEqualDeep(parse_element_attributes(
        \\
    ), tmd.ElementAttibutes{});

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .;bar;baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = ";bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;#baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;baz bla bla bla ...
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#?foo .bar
    ), tmd.ElementAttibutes{});

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\.bar;baz #foo
    ), tmd.ElementAttibutes{
        .id = "",
        .classes = "bar;baz",
    });
}

pub fn parse_base_block_open_playload(playload: []const u8) tmd.BaseBlockAttibutes {
    var attrs = tmd.BaseBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "commentedOut").?;
    const horizontalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "horizontalAlign").?;
    const verticalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "verticalAlign").?;
    const cellSpans = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "cellSpans").?;

    var lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
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
                    return attrs;
                },
                '>', '<' => {
                    if (lastOrder >= horizontalAlign) break;
                    defer lastOrder = horizontalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '>' and item[1] != '<') break;
                    if (std.mem.eql(u8, item, "<<"))
                        attrs.horizontalAlign = .left
                    else if (std.mem.eql(u8, item, ">>"))
                        attrs.horizontalAlign = .right
                    else if (std.mem.eql(u8, item, "><"))
                        attrs.horizontalAlign = .center
                    else if (std.mem.eql(u8, item, "<>"))
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

test "parse_base_block_open_playload" {
    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\
    ), tmd.BaseBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\// >> ^^ ..2:3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = true,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\>> ^^ ..2:3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .right,
        .verticalAlign = .top,
        .cellSpans = .{
            .axisSpan = 2,
            .crossSpan = 3,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\>< :3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .center,
        .verticalAlign = .none,
        .cellSpans = .{
            .axisSpan = 1,
            .crossSpan = 3,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\^^ ..2
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .none,
        .verticalAlign = .top,
        .cellSpans = .{
            .axisSpan = 2,
            .crossSpan = 1,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\<>
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .justify,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\<<
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .left,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\^^ <<
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .verticalAlign = .top,
    });
}

pub fn parse_code_block_open_playload(playload: []const u8) tmd.CodeBlockAttibutes {
    var attrs = tmd.CodeBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "commentedOut").?;
    //const language = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "language").?;

    const lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
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
                    for (item[0..]) |c| {
                        //if (c >= 128) break :parse;
                        if (!charPropertiesTable[c].canBeInLanguageName) break :parse;
                    }
                    attrs.language = item;
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

test "parse_code_block_open_playload" {
    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\
    ), tmd.CodeBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\// 
    ), tmd.CodeBlockAttibutes{
        .commentedOut = true,
        .language = "",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\// zig
    ), tmd.CodeBlockAttibutes{
        .commentedOut = true,
        .language = "",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\zig
    ), tmd.CodeBlockAttibutes{
        .commentedOut = false,
        .language = "zig",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\zig bla bla bla ...
    ), tmd.CodeBlockAttibutes{
        .commentedOut = false,
        .language = "zig",
    });
}

pub fn parse_code_block_close_playload(playload: []const u8) tmd.ContentStreamAttributes {
    var attrs = tmd.ContentStreamAttributes{};

    var arrowFound = false;
    var content: []const u8 = "";

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) {
            if (!arrowFound) {
                if (item.len != 2) return attrs;
                for (item) |c| if (c != '<') return attrs;
                arrowFound = true;
            } else if (content.len > 0) {
                // ToDo:
                unreachable;
            } else {
                content = item;
                break; // break the loop
                // ToDo: now only support one stream source.
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    attrs.content = content;
    return attrs;
}

test "parse_code_block_close_playload" {
    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\
    ), tmd.ContentStreamAttributes{});

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<<
    ), tmd.ContentStreamAttributes{});

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<< content
    ), tmd.ContentStreamAttributes{
        .content = "content",
    });

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<< #id bla bla ...
    ), tmd.ContentStreamAttributes{
        .content = "#id",
    });
}

pub fn parse_custom_block_open_playload(playload: []const u8) tmd.CustomBlockAttibutes {
    var attrs = tmd.CustomBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "commentedOut").?;
    //const app = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "app").?;

    const lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
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
                    // ToDo: maybe it is okay to just disallow blank chars in the app name.
                    for (item[0..]) |c| {
                        //if (c >= 128) break :parse;
                        if (!charPropertiesTable[c].canBeInAppName) break :parse;
                    }
                    attrs.app = item;
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

test "parse_custom_block_open_playload" {
    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\
    ), tmd.CustomBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\// 
    ), tmd.CustomBlockAttibutes{
        .commentedOut = true,
        .app = "",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\// html
    ), tmd.CustomBlockAttibutes{
        .commentedOut = true,
        .app = "",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\html
    ), tmd.CustomBlockAttibutes{
        .commentedOut = false,
        .app = "html",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\html bla bla bla ...
    ), tmd.CustomBlockAttibutes{
        .commentedOut = false,
        .app = "html",
    });
}

pub fn isValidLinkURL(text: []const u8) bool {
    // ToDo: more precisely and performant.

    if (std.ascii.startsWithIgnoreCase(text, "#")) return true;
    if (std.ascii.startsWithIgnoreCase(text, "http")) {
        const t = text[4..];
        if (std.ascii.startsWithIgnoreCase(t, "s://")) return true;
        if (std.ascii.startsWithIgnoreCase(t, "://")) return true;
    }

    const t = if (std.mem.indexOfScalar(u8, text, '#')) |k| blk: {
        const t = text[0..k];
        //if (std.ascii.endsWithIgnoreCase(t, ".tmd")) return true;
        break :blk t;
    } else text;

    if (std.ascii.endsWithIgnoreCase(t, ".htm")) return true;
    if (std.ascii.endsWithIgnoreCase(t, ".html")) return true;

    return false;
}

test "isValidLinkURL" {
    try std.testing.expect(isValidLinkURL("http://aaa"));
    try std.testing.expect(isValidLinkURL("https://aaa"));
    try std.testing.expect(false == isValidLinkURL("http:"));
    try std.testing.expect(false == isValidLinkURL("https"));
    try std.testing.expect(isValidLinkURL("foo.htm"));
    try std.testing.expect(isValidLinkURL("foo.html#bar"));
    try std.testing.expect(isValidLinkURL("foo.htm#bar"));
    try std.testing.expect(isValidLinkURL("foo.html"));
    //try std.testing.expect(isValidLinkURL("foo.tmd#")); // ToDo
    try std.testing.expect(isValidLinkURL("#"));
    try std.testing.expect(isValidLinkURL("#bar"));
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
    //    if (std.ascii.startsWithIgnoreCase(text, "http")) {
    //        const t = text[4..];
    //        if (std.ascii.startsWithIgnoreCase(t, "s://")) break :next;
    //        if (std.ascii.startsWithIgnoreCase(t, "://")) break :next;
    //    }
    //}

    for (supportedMediaExts) |ext| {
        if (std.ascii.endsWithIgnoreCase(src, ext)) return src.len > ext.len;
    }

    return false;
}

test "isValidMediaURL" {
    try std.testing.expect(isValidMediaURL("foo.png"));
    try std.testing.expect(isValidMediaURL("bar.PNG"));
    try std.testing.expect(isValidMediaURL("foo.Jpeg"));
    try std.testing.expect(isValidMediaURL("bar.JPG"));
    try std.testing.expect(isValidMediaURL("bar.JPG"));
    try std.testing.expect(isValidMediaURL("f.gif"));
    try std.testing.expect(isValidMediaURL("b.GIF"));

    try std.testing.expect(!isValidMediaURL(".gif"));
    try std.testing.expect(!isValidMediaURL(".GIF"));
    try std.testing.expect(!isValidMediaURL("PNG"));
    try std.testing.expect(!isValidMediaURL(".jpeg"));
    try std.testing.expect(!isValidMediaURL("foo.xyz"));
}
