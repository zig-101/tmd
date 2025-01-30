const std = @import("std");
const tmd = @import("tmd");

test "block nesting depths" {
    const BlockNestingDepthChecker = struct {
        fn check(data: []const u8, expectedNestingDepths: []const u32) !bool {
            var doc = try tmd.parse_tmd(data, std.testing.allocator);
            defer tmd.destroy_doc(&doc, std.testing.allocator);

            const lastBlock = doc.blockByID("bar") orelse &doc.blocks.tail.?.value;
            var block = doc.blockByID("foo") orelse doc.rootBlock();
            for (expectedNestingDepths, 1..) |depth, n| {
                if (block.nestingDepth != depth) return false;
                if (block == lastBlock) {
                    if (n != expectedNestingDepths.len) return error.TooManyNestingDepths;
                    return true;
                }
                block = block.next() orelse unreachable;
            }
            return error.TooFewNestingDepths;
        }
    };

    try std.testing.expect(try BlockNestingDepthChecker.check(
        \\
    , &.{0}));

    try std.testing.expect(try BlockNestingDepthChecker.check(
        \\ * aaa
        \\   + @@@ #foo
        \\     111
        \\    
        \\     - xxx
        \\
        \\   + 222
        \\
        \\ * bbb
        \\   + 111
        \\
        \\
    , &.{
        3, 3, // <- 1st blank block
        3, 3, 4, 3, // <- 2nd blank block
        2, 3, 2, // <- 3rd blank block
        1, 2, 2, 2, 3, 1, // <- 4th blank block
    }));

    try std.testing.expect(try BlockNestingDepthChecker.check(
        \\ * {
        \\   * @@@ #foo
        \\     aaa
        \\     + 111
        \\   
        \\   @@@ #bar
        \\   }
    , &.{ 4, 4, 4, 5, 3, 3 }));

    try std.testing.expect(try BlockNestingDepthChecker.check(
        \\ * {
        \\   * @@@ #foo
        \\     aaa
        \\     + 111
        \\   .
        \\     @@@ #bar
        \\   }
    , &.{ 4, 4, 4, 5, 3, 4, 4 }));
}
