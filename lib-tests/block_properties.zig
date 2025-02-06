const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "block attributes" {
    const BlockTypeChecker = struct {
        fn check(doc: *const tmd.Doc, id: []const u8, expectedBlockType: std.meta.Tag(tmd.BlockType)) !bool {
            if (doc.blockByID(id)) |block| return block.blockType == expectedBlockType else return error.BlockNotFound;
        }
    };
    const BlockIsFooterChecker = struct {
        fn check(doc: *const tmd.Doc, id: []const u8) !bool {
            if (doc.blockByID(id)) |block| return block.footerAttibutes() != null else return error.BlockNotFound;
        }
    };

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\ hello world!
        \\ @@@ #bar
        \\ ### title
        \\ @@@ #footer
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .usual));
            try std.testing.expect(try BlockTypeChecker.check(doc, "bar", .header));
            try std.testing.expect(try BlockIsFooterChecker.check(doc, "foo") == false);
            try std.testing.expect(try BlockIsFooterChecker.check(doc, "bar"));
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #plain-container
        \\ . a footer block
        \\   @@@ #footer
        \\
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.blockByID("plain-container").?.nextSibling().?.footerAttibutes() == null);
            try std.testing.expect(doc.blockByID("plain-container").?.next().?.footerAttibutes() != null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #list
        \\ + a footer block
        \\   @@@ #footer
        \\
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "footer", .attributes));
            try std.testing.expect(doc.blockByID("list").?.nextSibling().?.footerAttibutes() == null);
            try std.testing.expect(doc.blockByID("list").?.next().?.next().?.footerAttibutes() != null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #list
        \\ + not a footer block
        \\   @@@ #foo
        \\
        \\ + item 2
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .blank));
            try std.testing.expect(doc.blockByID("list").?.next().?.next().?.footerAttibutes() == null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ * item 1
        \\   @@@ #list
        \\   + @@@ #foo
        \\     a footer block
        \\     @@@ #footer
        \\
        \\ * item 2
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "footer", .attributes));
            try std.testing.expect(doc.blockByID("foo").?.footerAttibutes() != null);
            try std.testing.expect(doc.blockByID("list").?.nextSibling().?.blockType == .blank);
            try std.testing.expect(doc.blockByID("list").?.nextSibling().?.footerAttibutes() == null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\ - foo item
        \\   @@@ #bar
        \\ - bar item
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .list));
            try std.testing.expect(try BlockTypeChecker.check(doc, "bar", .attributes));
            try std.testing.expect(doc.blockByID("bar").?.prev().?.footerAttibutes() != null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\ - foo item
        \\
        \\ @@@ #bar
        \\ - bar item
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .list));
            try std.testing.expect(try BlockTypeChecker.check(doc, "bar", .list));
            try std.testing.expect(doc.blockByID("foo").?.nextSibling().?.blockType == .blank);
            try std.testing.expect(doc.blockByID("foo").?.nextSibling().?.nextSibling().?.blockType == .attributes);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .blank));
            try std.testing.expect(doc.blockByID("foo").?.next() == null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\ {
        \\ @@@ #footer
        \\ }
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockIsFooterChecker.check(doc, "foo") == false);
            try std.testing.expect(try BlockTypeChecker.check(doc, "footer", .attributes));
            try std.testing.expect(doc.blockByID("footer").?.nextSibling() == null);
            try std.testing.expect(doc.blockByID("footer").?.prev().?.nextSibling() == null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #foo
        \\ {
        \\ @@@ #footer
        \\ }
        \\ not a footer
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.blockByID("foo").?.nextSibling().?.footerAttibutes() == null);
            try std.testing.expect(try BlockTypeChecker.check(doc, "footer", .attributes));
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ {
        \\ @@@ #foo
        \\ a footer
        \\ @@@ #footer
        \\ }
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .usual));
            try std.testing.expect(doc.blockByID("foo").?.footerAttibutes() != null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ {
        \\ @@@ #foo
        \\
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "foo", .blank));
            try std.testing.expect(doc.blockByID("foo").?.next() == null);
            try std.testing.expect(doc.blockByID("foo").?.prev().?.prev().?.nextSibling() == null);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ @@@ #example .line-numbers
        \\ ''' zig
        \\ pub fn main() void {}
        \\ '''
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(try BlockTypeChecker.check(doc, "example", .code));
            try std.testing.expectEqualStrings(doc.blockByID("example").?.attributes.?.classes, "line-numbers");
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ && example.png
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.rootBlock().next().?.blockType == .usual);
            try std.testing.expect(doc.rootBlock().next().?.more.hasNonMediaTokens == false);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ ;;; && example.png
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.rootBlock().next().?.blockType == .usual);
            try std.testing.expect(doc.rootBlock().next().?.more.hasNonMediaTokens == false);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ ;;;
        \\ && example.png
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.rootBlock().next().?.blockType == .usual);
            try std.testing.expect(doc.rootBlock().next().?.more.hasNonMediaTokens == false);
            return true;
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ ;;; ``
        \\ && example.png
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !bool {
            try std.testing.expect(doc.rootBlock().next().?.blockType == .usual);
            try std.testing.expect(doc.rootBlock().next().?.more.hasNonMediaTokens);
            return true;
        }
    }.check));
}
