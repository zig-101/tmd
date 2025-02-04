const std = @import("std");
const tmd = @import("tmd");

test "span marks" {
    const SpanMarksChecker = struct {
        fn check(data: []const u8, expectedSpanMarkTypes: []const tmd.SpanMarkType) !bool {
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
            var token = inlineTokenIterator.first() orelse {
                if (expectedSpanMarkTypes.len == 0) return true;
                return error.TooFewTokens;
            };

            var i: usize = 0;
            while (true) {
                switch (token.*) {
                    .spanMark => |m| {
                        if (i == expectedSpanMarkTypes.len) return error.TooManyToekns;
                        if (m.markType != expectedSpanMarkTypes[i]) return false;
                        i += 1;
                    },
                    else => {},
                }

                token = inlineTokenIterator.next() orelse {
                    if (i != expectedSpanMarkTypes.len) return error.TooFewTokens;
                    return true;
                };
            }
        }
    };

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa bbb
    , &.{}));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa **bbb
    , &.{.fontWeight}));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa **bbb%% cc **dd%%
    , &.{ .fontWeight, .fontStyle, .fontWeight, .fontStyle }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa *******bbb%% cc **dd%%%%%%%
    , &.{ .fontWeight, .fontStyle }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa ********bbb%% cc **dd%%%%%%%%
    , &.{ .fontStyle, .fontWeight }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa **bbb
        \\// %% cc **
        \\dd%%
    , &.{ .fontWeight, .fontStyle }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa **bbb
        \\!! %% cc **
        \\dd%%
    , &.{ .fontWeight, .fontStyle }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\aaa **bbb
        \\?? %% cc **
        \\dd%%
    , &.{ .fontWeight, .fontStyle }));

    try std.testing.expect(try SpanMarksChecker.check(
        \\^~~aaa ***bbb**
        \\%%ccc ::dddd ^|| eee
        \\:: fff || __ggg $$2$$ hhh
        \\`code`__
    , &.{ .deleted, .fontWeight, .fontStyle, .fontSize, .marked, .fontSize, .marked, .link, .supsub, .supsub, .code, .code, .link }));
}
