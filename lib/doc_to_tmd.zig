const std = @import("std");

const tmd = @import("tmd.zig");
const LineScanner = @import("tmd_to_doc-line_scanner.zig");

// ToDo:
// * test 1: data -> parse -> to_tmd(not format): should not change.
// * test 2: to_tmd(format) -> re-parse -> to_tmd(format): should not change.
// * test 3: to_html() and to_html(parse(to_tmd(format))) should be identical.
//
// May be more such tests should be put in an external project.

// doc_to_tmd is the inverse of parsing tmd files.
// Not-format is mainly used in tests.
pub fn doc_to_tmd(writer: anytype, tmdDoc: *const tmd.Doc, comptime format: bool) !void {
    if (format) try doc_to_tmd_with_formatting(writer, tmdDoc) else try doc_to_tmd_without_formatting(writer, tmdDoc);
}

// Mainly for tests.
fn doc_to_tmd_without_formatting(writer: anytype, tmdDoc: *const tmd.Doc) !void {
    var uw = UnchangeWriter{ .tmdDoc = tmdDoc };
    try uw.writeAll(writer);
}

const UnchangeWriter = struct {
    tmdDoc: *const tmd.Doc,

    fn data(uw: *const UnchangeWriter, start: tmd.DocSize, end: tmd.DocSize) []const u8 {
        return uw.tmdDoc.rangeData(.{ .start = start, .end = end });
    }

    fn writeAll(uw: *const UnchangeWriter, writer: anytype, tmdDoc: *const tmd.Doc) !void {
        var line = &(tmdDoc.lines.head orelse return).value;
        var lineStartAt: tmd.DocSize = 0;
        while (true) {
            std.debug.assert(line.start(.none) == lineStartAt);
            std.debug.assert(line.end(.none) == line.endAt);

            const lineEndPos = line.end(.trimLineEnd);

            switch (line.lineType) {
                .code, .data => {
                    std.debug.assert(line.prefixBlankEnd == lineStartAt);
                    std.debug.assert(line.suffixBlankStart == lineEndPos);
                    _ = try writer.write(uw.data(lineStartAt, lineEndPos));
                },
                else => blk: {
                    std.debug.assert(LineScanner.are_all_blanks(uw.data(lineStartAt, line.prefixBlankEnd)));
                    std.debug.assert(LineScanner.are_all_blanks(uw.data(line.suffixBlankStart, lineEndPos)));

                    var token = &(line.tokens.head orelse {
                        _ = try writer.write(uw.data(lineStartAt, lineEndPos));
                        break :blk;
                    }).value;
                    var lastTokenEnd = line.prefixBlankEnd;
                    _ = try writer.write(uw.data(lineStartAt, lastTokenEnd));
                    while (true) {
                        std.debug.assert(token.start() == lastTokenEnd);
                        const tokenEnd = token.end();
                        _ = try writer.write(uw.data(lastTokenEnd, tokenEnd));
                        lastTokenEnd = tokenEnd;
                        token = token.next() orelse break;
                    }
                    // not always true for playload containing lines.
                    // ToDo: playloads should be .plainText tokens?
                    //std.debug.assert(lastTokenEnd == line.suffixBlankStart);
                    _ = try writer.write(uw.data(lastTokenEnd, lineEndPos));
                },
            }

            const endLen: u2 = blk: switch (line.endType) {
                .n => {
                    _ = try writer.write("\n");
                    break :blk 1;
                },
                .rn => {
                    _ = try writer.write("\r\n");
                    break :blk 2;
                },
                .void => {
                    std.debug.assert(line.next() == null);
                    break :blk 0;
                },
            };
            std.debug.assert(endLen == line.endType.len());
            std.debug.assert(lineEndPos + endLen == line.endAt);

            lineStartAt = line.endAt;
            line = line.next() orelse break;
        }
    }
};

//
// Code/data blocks inner lines should be kept as is.
//
// Usual lines in header blocks aligned with the end of ### mark.
//
// Blank lines should be empty.
//
// All lines of other atom blocks should be left aligned.
// And they are right trimmed.
//
// Base blocks don't increase indentation, except for those have only one attribute child.
//
// Container blocks increase 3-space indentation.
//
// Container mark token lengths should be formatted to 3 if not bare.
//
// @@@ ;;; ###, are always followed by one space if not bare.
//

fn doc_to_tmd_with_formatting(writer: anytype, tmdDoc: *const tmd.Doc) !void {
    var fw = FormatWriter{ .tmdDoc = tmdDoc };
    try fw.writeAll(writer);
}

const FormatWriter = struct {
    tmdDoc: *const tmd.Doc,
    currentIndentLen: u32 = 0,
    writingHeaderLines: bool = false,

    const indentUnit = 3;
    const spaces = " " ** (tmd.MaxBlockNestingDepth * indentUnit);

    fn data(fw: *const FormatWriter, start: tmd.DocSize, end: tmd.DocSize) []const u8 {
        return fw.tmdDoc.rangeData(.{ .start = start, .end = end });
    }

    fn indentSpaces(fw: *const FormatWriter) []const u8 {
        return spaces[0..fw.currentIndentLen];
    }

    fn writeAll(fw: *FormatWriter, w: anytype) !void {
        try fw.writeBlockChildren(w, fw.tmdDoc.rootBlock());
    }

    fn writeBlockChildren(fw: *FormatWriter, w: anytype, parent: *const tmd.Block) !void {
        std.debug.assert(!parent.isAtom());

        var child = parent.firstChild() orelse {
            std.debug.assert(parent.blockType == .base);
            return;
        };

        // Write the leading chars of the first line.
        const indentationWritten = parent.isContainer();
        const changeIndentation = if (indentationWritten) blk: {
            switch (child.blockType) {
                .item => break :blk false,
                .base => |base| {
                    try fw.writeContainerMark(w, base.openLine);
                    break :blk true;
                },
                else => {
                    std.debug.assert(child.isAtom());
                    try fw.writeContainerMark(w, child.startLine());
                    break :blk true;
                },
            }
        } else blk: {
            std.debug.assert(parent.blockType == .root or parent.blockType == .base);

            break :blk parent.blockType == .base and child.blockType == .attributes and child.nextSibling() == null;
        };

        if (changeIndentation) fw.currentIndentLen += indentUnit;
        defer {
            if (changeIndentation) fw.currentIndentLen -= indentUnit;
        }

        try fw.writeBlock(w, child, indentationWritten);
        while (true) {
            child = child.nextSibling() orelse break;
            try fw.writeBlock(w, child, false);
        }
    }

    fn writeBlock(fw: *FormatWriter, w: anytype, block: *const tmd.Block, firstLineIndentationWritten: bool) anyerror!void {
        if (block.isAtom()) {
            defer fw.writingHeaderLines = false;
            fw.writingHeaderLines = block.blockType == .header;

            var line = block.startLine();
            try fw.writeLine(w, line, firstLineIndentationWritten);
            const endLine = block.endLine();
            while (true) {
                if (line == endLine) break;
                line = line.next().?;
                try fw.writeLine(w, line, false);
            }
            return;
        }

        if (block.isContainer()) {
            try fw.writeBlockChildren(w, block);
            return;
        }

        std.debug.assert(block.blockType == .base);
        {
            const base = block.blockType.base;

            try fw.writeLine(w, base.openLine, firstLineIndentationWritten);
            try fw.writeBlockChildren(w, block);
            if (base.closeLine) |closeLine| {
                try fw.writeLine(w, closeLine, false);
            }
        }
    }

    fn writeContainerMark(fw: *FormatWriter, w: anytype, line: *const tmd.Line) !void {
        const token = line.containerMarkToken() orelse unreachable;
        const mark = token.*.containerMark;
        _ = try w.write(fw.indentSpaces());
        _ = try w.write(fw.data(mark.start, mark.start + mark.more.markLen));
        if (mark.blankLen == 0) return;

        switch (mark.more.markLen) {
            1 => _ = try w.write("  "),
            2 => _ = try w.write(" "),
            else => unreachable,
        }
    }

    fn writeLine(fw: *FormatWriter, w: anytype, line: *const tmd.Line, indentationWritten: bool) !void {
        switch (line.lineType) {
            .blank => {},
            .data, .code => {
                _ = try w.write(fw.data(line.start(.none), line.end(.trimLineEnd)));
            },
            else => {
                if (!indentationWritten) {
                    _ = try w.write(fw.indentSpaces());

                    if (fw.writingHeaderLines and line.lineType == .usual) {
                        _ = try w.write("   ");
                    }
                }

                const lineEnd = line.end(.trimTrailingSpaces);
                const remainingStart = if (line.lineTypeMarkToken()) |token| blk: {
                    const mark = token.*.lineTypeMark;
                    _ = try w.write(fw.data(mark.start, mark.start + mark.markLen));
                    const tokenEnd = token.end();
                    if (tokenEnd != lineEnd) _ = try w.write(" ");
                    break :blk tokenEnd;
                } else blk: {
                    break :blk line.start(.trimContainerMark);
                };

                if (remainingStart != lineEnd) {
                    _ = try w.write(fw.data(remainingStart, lineEnd));
                }
            },
        }
        _ = try w.write("\n");
    }
};
