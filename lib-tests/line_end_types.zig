const std = @import("std");
const tmd = @import("tmd");

test "line end type" {
    const LineEndTypeChecker = struct {
        fn check(data: []const u8, expectedLineEnds: []const tmd.Line.EndType) !bool {
            var doc = try tmd.parser.parse_tmd_doc(data, std.testing.allocator);
            defer tmd.parser.destroy_tmd_doc(&doc, std.testing.allocator);

            var line = doc.firstLine() orelse {
                if (expectedLineEnds.len > 0) return error.TooFewLines;
                return true;
            };
            for (expectedLineEnds, 1..) |expected, lineNumber| {
                if (line.endType != expected) return false;
                line = line.next() orelse {
                    if (lineNumber != expectedLineEnds.len) {
                        return error.TooFewLines;
                    }
                    break;
                };
                if (lineNumber == expectedLineEnds.len) {
                    return error.TooManyLines;
                }
            }
            return true;
        }
    };

    try std.testing.expect(try LineEndTypeChecker.check("", &.{}));

    try std.testing.expect(try LineEndTypeChecker.check(" ", &.{.void}));

    try std.testing.expect(try LineEndTypeChecker.check("foo \n" ++
        "bar\r\n" ++
        "end", &.{ .n, .rn, .void }));

    try std.testing.expect(try LineEndTypeChecker.check("foo \n" ++
        "bar\r\n" ++
        "end\n", &.{ .n, .rn, .n }));

    try std.testing.expect(try LineEndTypeChecker.check("foo \n" ++
        "bar\r\n" ++
        "end\n\n", &.{ .n, .rn, .n, .n }));

    try std.testing.expect(try LineEndTypeChecker.check("foo \r \n" ++
        "\r", &.{ .n, .void }));

    try std.testing.expect(try LineEndTypeChecker.check("foo \r \n" ++
        "\r\n" ++
        " ", &.{ .n, .rn, .void }));
}
