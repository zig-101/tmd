const std = @import("std");
const tmd = @import("tmd");

test "line end spacing" {
    const LineEndSpacingChecker = struct {
        fn check(data: []const u8) !bool {
            var doc = try tmd.Doc.parse(data, std.testing.allocator);
            defer doc.destroy();

            if (doc.lines.head) |le| {
                if (doc.lines.tail.?.value.treatEndAsSpace) {
                    return error.TreatDocTailLineEndAsSpace;
                }
                return le.value.treatEndAsSpace;
            }
            return error.DocHasNoLines;
        }
    };

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello`
        \\`world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello``
        \\world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\``world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello````
        \\world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\````world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\^``
        \\^``
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\**world**
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\**hello**
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\**%%world**
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\**hello%%**
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\%%hello
        \\%%**world**
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello%%
        \\world%%
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\** %%** %%
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\** %%**
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\**%%
        \\world%%
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!!
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!! 
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!!
        \\??
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!! 
        \\?? 
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!! **
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!! **world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!!
        \\**
        \\world
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\**hello
        \\!!
        \\**
        \\world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\!!
        \\**
        \\世界
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\你好
        \\世界
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello
        \\世界
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\你好
        \\world
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\hello ``
        \\世界
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\你好
        \\`` 世界
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\foo
        \\//
        \\bar
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\森
        \\//
        \\林
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\foo
        \\// comment
        \\bar
    ));

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\森
        \\// comment
        \\林
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\**foo
        \\// comment
        \\**bar
    ) == false);

    try std.testing.expect(try LineEndSpacingChecker.check(
        \\foo
        \\&& image
        \\bar
    ) == false);
}
