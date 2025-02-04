const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "span contents" {
    var spanChecker: struct {
        buffer: all.Buffer(256) = .{},
        opening: bool = false,

        // spanType == null means all spans.
        fn contentOfFirstSpanOfType(self: *@This(), spanType: ?tmd.SpanMarkType, data: []const u8) ![]const u8 {
            self.* = .{ .opening = spanType == null };

            var doc = try tmd.Doc.parse(data, std.testing.allocator);
            defer doc.destroy();

            var block = doc.rootBlock();
            const contentBlock = while (block.next()) |nextBlock| {
                switch (nextBlock.blockType) {
                    .usual, .header => break nextBlock,
                    else => block = nextBlock,
                }
            } else return error.DocHasNoContentBlocks;

            var inlineTokenIterator = contentBlock.inlineTokens();
            var token = inlineTokenIterator.first() orelse return "";
            while (true) {
                switch (token.*) {
                    .spanMark => |m| if (m.markType == spanType) {
                        if (self.opening) {
                            std.debug.assert(!m.more.open);
                            return self.buffer.used();
                        } else {
                            std.debug.assert(m.more.open);
                            self.opening = true;
                        }
                    },
                    .content => if (self.opening) {
                        try self.buffer.append(doc.rangeData(token.range()));
                    },
                    .evenBackticks => |m| if (self.opening) {
                        if (m.more.secondary) {
                            for (0..m.pairCount) |_| try self.buffer.append("`");
                        } else for (1..m.pairCount) |_| {
                            try self.buffer.append(" ");
                        }
                    },
                    else => {},
                }

                if (inlineTokenIterator.next()) |nextToken| token = nextToken else return self.buffer.used();
            }
        }
    } = undefined;

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\aaa bbb
    ), "aaa bbb");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\-a``b
    ), "-ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\-.a``b
    ), "-.ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\--a``b
    ), "--ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\---a``b
    ), "---ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\#a``b
    ), "#ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\##a``b
    ), "##ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\###a``b
    ), "ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\###-----a``b
    ), "ab");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa ` `` ` bbb
    ), "");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa ` ```` ` bbb
    ), " ");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa ` ^`` ` bbb
    ), "`");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa `^``` bbb
    ), "`");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa `^````` bbb
    ), "``");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa `^``^``` bbb
    ), "``");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.code,
        \\aaa ` ^``^`` ` bbb
    ), "``");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.fontWeight,
        \\aaa *** ** %% ** *** %%% %% bbb
    ), "** **");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.fontStyle,
        \\--- *** ** %% ** *** %%% %% +++
    ), "** %%%");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.fontSize,
        \\aaa ** foo :: bar--
        \\hello ** world
    ), "bar--hello world");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.fontSize,
        \\aaa ** foo :: bar--
        \\// comments
        \\!! %%foo**
        \\ \\ xyz::
        \\hello ** world
    ), "bar--%%foo**xyz");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(.fontSize,
        \\aaa ** foo :: bar--
        \\// comments
        \\!! %%foo**
        \\ \\ xyz %%
        \\hello ** world
    ), "bar--%%foo**xyz hello world");

    try std.testing.expectEqualStrings(try spanChecker.contentOfFirstSpanOfType(null,
        \\^*** bbb ** ccc ^***
    ), "bbb ** ccc ^");
}
