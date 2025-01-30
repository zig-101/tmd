const std = @import("std");
const tmd = @import("tmd");

test "block types" {
    const BlockTypeChecker = struct {
        fn check(data: []const u8, expectedBlockTypes: []const std.meta.Tag(tmd.BlockType)) !bool {
            var doc = try tmd.parse_tmd(data, std.testing.allocator);
            defer tmd.destroy_doc(&doc, std.testing.allocator);

            var block = doc.rootBlock();
            for (expectedBlockTypes) |expected| {
                block = block.next() orelse return error.TooFewBlocks;
                if (block.blockType != expected) return false;
            }

            if (block.next() != null) return error.TooManyBlocks;

            return true;
        }
    };

    try std.testing.expect(try BlockTypeChecker.check(
        \\
    , &.{}));

    try std.testing.expect(try BlockTypeChecker.check(
        \\
        \\
    , &.{.blank}));

    try std.testing.expect(try BlockTypeChecker.check(
        \\ ### title
        \\     still title
        \\ ;;; subtitle
        \\     still subtitle
        \\ 
        \\
        \\ @@@
        \\ @@@ #id
        \\ '''
        \\ code
        \\ '''
        \\ usual
        \\ """
        \\ data
        \\ """
        \\ ###--- section
        \\        still section
        \\ ---
        \\
    , &.{ .header, .usual, .blank, .attributes, .code, .usual, .custom, .header, .seperator }));

    try std.testing.expect(try BlockTypeChecker.check(
        \\ * aaa
        \\   aaa
        \\ *. 111
        \\    111
        \\ *. 222
        \\    222
        \\
        \\ * 
        \\   bbb
        \\   bbb
        \\ . plain
        \\   plain
        \\ * list 2
        \\
        \\ > quotation
        \\ ? ### why?
        \\   why?
        \\   ;;; because ...
        \\       ...
        \\ ! 
        \\   {
        \\   bla bla 
        \\   bla bla
        \\   }
        \\ # ;;; cell (1,1)
        \\   ;;; cell (1,2)
        \\   ---
        \\   ;;; cell (2,1)
        \\   ;;; cell (2,2)
        \\
    , &.{ .list, .item, .usual, .list, .item, .usual, .item, .usual, .blank, .item, .usual, .plain, .usual, .list, .item, .usual, .blank, .quotation, .usual, .reveal, .header, .usual, .notice, .usual, .base, .usual, .table, .usual, .usual, .seperator, .usual, .usual }));
}
