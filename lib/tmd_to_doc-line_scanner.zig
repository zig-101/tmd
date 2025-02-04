const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");

const LineScanner = @This();

//const LineScanner = struct {
data: []const u8,
cursor: u32 = 0,
cursorLineIndex: u32 = 0, // for debug. 1-based. 0 means invalod.

// When lineEnd != null, cursor is the start of lineEnd.
// That means, for a .rn line end, cursor is the index of '\r'.
lineEnd: ?tmd.Line.EndType = null,

pub const bytesKindTable = blk: {
    var table = [1]union(enum) {
        others: void,
        blank: struct {
            isSpace: bool,
        },
        leadingSpanMark: tmd.LineSpanMarkType,
        spanMark: tmd.SpanMarkType,

        const ByteKind = @This();

        // ToDo: Now, for zig design limitaiton: https://ziggit.dev/t/6726,
        //       The best effort is make @sizeOf(ByteKind) == 2.
        //       It can be 1 in fact.
        comptime {
            std.debug.assert(@sizeOf(ByteKind) <= 2);
        }

        pub fn isSpace(k: ByteKind) bool {
            return switch (k) {
                .blank => |b| b.isSpace,
                else => false,
            };
        }

        pub fn isBlank(k: ByteKind) bool {
            return k == .blank;
        }
    }{.others} ** 256;

    for (0..'\n') |i| table[i] = .{ .blank = .{ .isSpace = false } };
    for ('\n' + 1..33) |i| table[i] = .{ .blank = .{ .isSpace = false } };
    table[127] = .{ .blank = .{ .isSpace = false } };
    table[' '] = .{ .blank = .{ .isSpace = true } };
    table['\t'] = .{ .blank = .{ .isSpace = true } };

    table['\\'] = .{ .leadingSpanMark = .lineBreak };
    table['/'] = .{ .leadingSpanMark = .comment };
    table['&'] = .{ .leadingSpanMark = .media };
    table['!'] = .{ .leadingSpanMark = .escape };
    table['?'] = .{ .leadingSpanMark = .spoiler };

    table['*'] = .{ .spanMark = .fontWeight };
    table['%'] = .{ .spanMark = .fontStyle };
    table[':'] = .{ .spanMark = .fontSize };
    table['~'] = .{ .spanMark = .deleted };
    table['|'] = .{ .spanMark = .marked };
    table['_'] = .{ .spanMark = .link };
    table['$'] = .{ .spanMark = .supsub };
    table['`'] = .{ .spanMark = .code };

    break :blk table;
};

test "bytesKindTable" {
    try std.testing.expect(bytesKindTable['\n'] == .others);
    try std.testing.expect(!bytesKindTable['\n'].isSpace());
    try std.testing.expect(!bytesKindTable['\n'].isBlank());
    try std.testing.expect(bytesKindTable['\t'].isSpace());
    try std.testing.expect(bytesKindTable['\t'].isBlank());
    try std.testing.expect(bytesKindTable[' '].isSpace());
    try std.testing.expect(bytesKindTable[' '].isBlank());
}

pub fn debugPrint(ls: *LineScanner, opName: []const u8, customValue: u32) void {
    if (builtin.mode != .Debug) return;

    std.debug.print("------- {s}, {}, {}\n", .{ opName, ls.cursorLineIndex, ls.cursor });
    std.debug.print("custom:  {}\n", .{customValue});
    if (ls.lineEnd) |end|
        std.debug.print("line end:    {s}\n", .{end.typeName()})
    else
        std.debug.print("cursor byte: {}\n", .{ls.peekCursor()});
}

// Call this at the doucment start or a line end.
pub fn proceedToNextLine(ls: *LineScanner) bool {
    defer ls.cursorLineIndex += 1;

    if (ls.cursorLineIndex == 0) {
        std.debug.assert(ls.lineEnd == null);
        return ls.cursor < ls.data.len;
    }

    if (ls.lineEnd) |lineEnd| {
        switch (lineEnd) {
            .void => return false,
            else => {
                ls.cursor += lineEnd.len();
                std.debug.assert(ls.cursor <= ls.data.len);
                if (ls.cursor >= ls.data.len) return false;
            },
        }

        ls.lineEnd = null;
        return true;
    } else unreachable;
}

pub fn advance(ls: *LineScanner, n: u32) void {
    std.debug.assert(ls.lineEnd == null);
    std.debug.assert(ls.cursor + n <= ls.data.len);
    ls.cursor += n;
}

// for retreat (witin the current line).
pub fn setCursor(ls: *LineScanner, cursor: u32) void {
    ls.cursor = cursor;
    ls.lineEnd = null;
}

pub fn peekCursor(ls: *LineScanner) u8 {
    std.debug.assert(ls.lineEnd == null);
    std.debug.assert(ls.cursor < ls.data.len);
    const c = ls.data[ls.cursor];
    std.debug.assert(c != '\n');
    return c;
}

pub fn peekNext(ls: *LineScanner) ?u8 {
    const k = ls.cursor + 1;
    if (k < ls.data.len) return ls.data[k];
    return null;
}

//pub fn checkFollowing(ls: *LineScanner, prefix: []const u8) bool {
//    const k = ls.cursor + 1;
//    if (k >= ls.data.len) return false;
//    return std.mem.startsWith(u8, ls.data[k..], prefix);
//}

// ToDo: return the blankStart instead?
// Returns count of trailing blanks.
pub fn readUntilLineEnd(ls: *LineScanner) u32 {
    std.debug.assert(ls.lineEnd == null);

    const data = ls.data;
    var index = ls.cursor;
    var blankStart = index;
    while (index < data.len) : (index += 1) {
        const c = data[index];
        if (c == '\n') {
            if (index > 0 and data[index - 1] == '\r') {
                ls.lineEnd = .rn;
                index -= 1;
            } else ls.lineEnd = .n;
            break;
        } else if (!bytesKindTable[c].isBlank()) {
            blankStart = index + 1;
        }
    } else ls.lineEnd = .void;

    ls.cursor = index;
    return index - blankStart;
}

// ToDo: return the blankStart instead?
// Returns count of trailing blanks.
pub fn readUntilSpanMarkChar(ls: *LineScanner, specifiedChar: ?u8) u32 {
    std.debug.assert(ls.lineEnd == null);
    if (specifiedChar) |char| {
        std.debug.assert(char == '`');
    }

    const data = ls.data;
    var index = ls.cursor;
    var blankStart = index;
    while (index < data.len) : (index += 1) {
        const c = data[index];
        switch (bytesKindTable[c]) {
            .spanMark => {
                if (specifiedChar) |char| {
                    if (c == char) break else blankStart = index + 1;
                } else break;
            },
            .blank => continue,
            else => {
                if (c == '\n') {
                    if (index > 0 and data[index - 1] == '\r') {
                        ls.lineEnd = .rn;
                        index = index - 1;
                    } else ls.lineEnd = .n;
                    break;
                } else {
                    blankStart = index + 1;
                }
            },
        }
    } else ls.lineEnd = .void;

    ls.cursor = index;
    return index - blankStart;
}

// ToDo: maybe it is better to change to readUntilNotSpaces,
//       without considering invisible blanks.
//       Just treat invisible blanks as visible non-space chars.
// Returns count of spaces.
pub fn readUntilNotBlank(ls: *LineScanner) u32 {
    std.debug.assert(ls.lineEnd == null);

    const data = ls.data;
    var index = ls.cursor;
    var numSpaces: u32 = 0;
    while (index < data.len) : (index += 1) {
        const c = data[index];
        if (bytesKindTable[c].isBlank()) {
            if (bytesKindTable[c].isSpace()) numSpaces += 1;
            continue;
        }

        if (c == '\n') {
            if (index > 0 and data[index - 1] == '\r') {
                ls.lineEnd = .rn;
                index = index - 1;
            } else ls.lineEnd = .n;
        }

        break;
    } else ls.lineEnd = .void;

    ls.cursor = index;
    return numSpaces;
}

// Return count of skipped bytes.
pub fn readUntilNotChar(ls: *LineScanner, char: u8) u32 {
    std.debug.assert(ls.lineEnd == null);
    std.debug.assert(!bytesKindTable[char].isBlank());
    std.debug.assert(char != '\n');

    const data = ls.data;
    var index = ls.cursor;
    while (index < data.len) : (index += 1) {
        const c = data[index];
        if (c == char) continue;

        if (c == '\n') {
            if (index > 0 and data[index - 1] == '\r') {
                ls.lineEnd = .rn;
                index = index - 1;
            } else ls.lineEnd = .n;
        }

        break;
    } else ls.lineEnd = .void;

    const skipped = index - ls.cursor;
    ls.cursor = index;
    return skipped;
}

// Return count of skipped bytes.
//pub fn readUntilCondition(ls: *LineScanner, comptime condition: fn (u8) bool) u32 {
//    const data = ls.data;
//    var index = ls.cursor;
//    while (index < data.len) : (index += 1) {
//        const c = data[index];
//        if (condition(c)) {
//            if (c == '\n') {
//                if (index > 0 and data[index - 1] == '\r') {
//                    ls.lineEnd = .rn;
//                    index = index - 1;
//                } else ls.lineEnd = .n;
//            }
//
//            break;
//        }
//    } else ls.lineEnd = .void;
//
//    const skipped = index - ls.cursor;
//    ls.cursor = index;
//    return skipped;
//}

test "LineScanner" {
    const data =
        "   \t \t abcdef***rst \x00\x7f %% xyz \r\t\r\r\r\n" ++
        " - foo\t\x00 \n" ++
        "- \t bar";
    var ls = LineScanner{ .data = data };
    {
        try std.testing.expect(ls.proceedToNextLine());
        const start = ls.cursor;
        const numSpaces = ls.readUntilNotBlank();
        try std.testing.expect(numSpaces == ls.cursor);
        try std.testing.expect(ls.peekCursor() == 'a');
        try std.testing.expect(ls.peekNext() == 'b');
        var numBlanks = ls.readUntilSpanMarkChar(null);
        try std.testing.expect(numBlanks == 0);
        try std.testing.expect(ls.peekCursor() == '*');
        const numStars = ls.readUntilNotChar('*');
        try std.testing.expect(numStars == 3);
        numBlanks = ls.readUntilSpanMarkChar(null);
        try std.testing.expect(numBlanks == 4);
        numBlanks = ls.readUntilLineEnd();
        try std.testing.expect(numBlanks == 5);

        ls.setCursor(start);
        numBlanks = ls.readUntilLineEnd();
        try std.testing.expect(numBlanks == 5);
        try std.testing.expect(ls.lineEnd == .rn);
    }
    {
        try std.testing.expect(ls.proceedToNextLine());
        var numSpaces = ls.readUntilNotBlank();
        try std.testing.expect(numSpaces == 1);
        try std.testing.expect(ls.peekCursor() == '-');
        ls.advance(1);
        numSpaces = ls.readUntilNotBlank();
        try std.testing.expect(numSpaces == 1);
        const from = ls.cursor;
        const numBlanks = ls.readUntilLineEnd();
        try std.testing.expect(numBlanks == 3);
        try std.testing.expect(ls.lineEnd == .n);
        const to = ls.cursor - numBlanks;
        try std.testing.expectEqualDeep("foo", data[from..to]);
    }
    {
        try std.testing.expect(ls.proceedToNextLine());
        var numSpaces = ls.readUntilNotBlank();
        try std.testing.expect(numSpaces == 0);
        try std.testing.expect(ls.peekCursor() == '-');
        ls.advance(1);
        numSpaces = ls.readUntilNotBlank();
        try std.testing.expect(numSpaces == 3);
        const from = ls.cursor;
        const numBlanks = ls.readUntilLineEnd();
        try std.testing.expect(numBlanks == 0);
        try std.testing.expect(ls.lineEnd == .void);
        const to = ls.cursor - numBlanks;
        try std.testing.expectEqualDeep("bar", data[from..to]);
    }
}

//===========================

pub fn are_all_blanks(str: []const u8) bool {
    for (str) |c| {
        if (bytesKindTable[c].isBlank()) continue;
        return false;
    }
    return true;
}

pub fn trim_blanks(str: []const u8) []const u8 {
    var i: usize = 0;
    while (i < str.len and bytesKindTable[str[i]].isBlank()) : (i += 1) {}
    const str2 = str[i..];
    i = str2.len;
    while (i > 0 and bytesKindTable[str2[i - 1]].isBlank()) : (i -= 1) {}
    return str2[0..i];
}

test "trim_blanks" {
    try std.testing.expectEqualStrings(trim_blanks(" "), "");
    try std.testing.expectEqualStrings(trim_blanks("\t"), "");
    try std.testing.expectEqualStrings(trim_blanks(" \t \t "), "");
    try std.testing.expectEqualStrings(trim_blanks(" world"), "world");
    try std.testing.expectEqualStrings(trim_blanks("world "), "world");
    try std.testing.expectEqualStrings(trim_blanks(" world "), "world");
    try std.testing.expectEqualStrings(trim_blanks("\x7F world \x00"), "world");
    try std.testing.expectEqualStrings(trim_blanks(" \x00世界 \r"), "世界");
    try std.testing.expectEqualStrings(trim_blanks(" world \n "), "world \n");
}

pub fn begins_with_blank(data: []const u8) bool {
    if (data.len == 0) return false;
    return bytesKindTable[data[0]].isBlank();
}

test "begins_with_blank" {
    try std.testing.expect(begins_with_blank(" "));
    try std.testing.expect(begins_with_blank("\t"));
    try std.testing.expect(begins_with_blank(" world"));
    try std.testing.expect(begins_with_blank("\x7Fworld"));
    try std.testing.expect(begins_with_blank("\x00世界"));

    try std.testing.expect(!begins_with_blank("world"));
    try std.testing.expect(!begins_with_blank("世界 "));
    try std.testing.expect(!begins_with_blank(".\tWorld\t."));
}

pub fn ends_with_blank(data: []const u8) bool {
    if (data.len == 0) return false;
    return bytesKindTable[data[data.len - 1]].isBlank();
}

test "ends_with_blank" {
    try std.testing.expect(ends_with_blank(" "));
    try std.testing.expect(ends_with_blank("\t"));
    try std.testing.expect(ends_with_blank("world "));
    try std.testing.expect(ends_with_blank("world\x7F"));
    try std.testing.expect(ends_with_blank("世界\x00"));

    try std.testing.expect(!ends_with_blank("world"));
    try std.testing.expect(!ends_with_blank(" 世界"));
    try std.testing.expect(!ends_with_blank("\tWorld\t."));
}
