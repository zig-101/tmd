const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const utf8 = @import("utf8.zig");

const AttributeParser = @import("tmd_parser-attribute_parser.zig");
const LineScanner = @import("tmd_parser-line_scanner.zig");
const DocParser = @import("tmd_parser-doc_parser.zig");

const ContentParser = @This();

//const ContentParser = struct {
docParser: *DocParser,

codeSpanStatus: *SpanStatus = undefined,
linkSpanStatus: *SpanStatus = undefined,

blockSession: struct {
    atomBlock: *tmd.BlockInfo = undefined,

    spanStatuses: [MarkCount]SpanStatus = .{.{}} ** MarkCount,
    currentTextNumber: u32 = 0,

    lastLinkInfoToken: ?*tmd.TokenInfo = null,
    lastPlainTextToken: ?*tmd.TokenInfo = null,
    spanStatusChangesAfterTheLastPlainTextToken: u32 = 0,

    //endLine: ?*tmd.LineInfo = null,

    // The line must have plainText tokens, and the last
    // plainText token must end with a CJK char.
    //
    // The line is a previous line. It might not be the last line.
    lineWithPendingLineEndRenderManner: ?*tmd.LineInfo = null,
} = .{},

lineSession: struct {
    currentLine: *tmd.LineInfo,
    contentStart: u32, // start of line

    tokens: *list.List(tmd.TokenInfo),

    isMedia: bool = false,

    // If it is the first one in line, it is used to determine
    // the line-end render manner of lineWithPendingLineEndRenderManner.
    // If it is the last one in line, it is used to determine whether or not
    // the current line should be the next lineWithPendingLineEndRenderManner.
    lastPlainTextToken: ?*tmd.TokenInfo = null, // ToDo: changed to ?const []u8
    spanStatusChangesBeforeTheFirstPlainTextToken: u32 = 0,

    activePlainText: ?*tmd.PlainText = null,

    anchor: u32,
    //cursor: u32,
    pendingBlankCount: u32 = 0, // ToDo: now it means blankCount ...
} = undefined,

//----

const MarkCount = tmd.SpanMarkType.MarkCount;
const SpanStatus = struct {
    markLen: u8 = 0, // [1, tmd.MaxSpanMarkLength) // ToDo: dup with .openMark.?.markLen?
    openMark: ?*tmd.SpanMark = null,
    openTextNumber: u32 = 0,
};

pub fn make(docParser: *DocParser) ContentParser {
    std.debug.assert(MarkCount <= 32);

    return .{
        .docParser = docParser,
    };
}

pub fn deinit(_: *ContentParser) void {
    // ToDo: looks nothing needs to do here.

    // Note: here should only release resource (memory).
    //       If there are other jobs to do,
    //       they should be put in another function
    //       and that function should not be called deferredly.
}

pub fn init(self: *ContentParser) void {
    self.codeSpanStatus = self.span_status(.code);
    self.linkSpanStatus = self.span_status(.link);
}

fn isCommentLineParser(self: *const ContentParser) bool {
    return self == self.docParser.commentLineParser;
}

fn span_status(self: *ContentParser, markType: tmd.SpanMarkType) *SpanStatus {
    return &self.blockSession.spanStatuses[markType.asInt()];
}

pub fn on_new_atom_block(self: *ContentParser, atomBlock: *tmd.BlockInfo) void {
    self.close_opening_spans(); // for the last block

    //if (self.blockSession.endLine) |line| {
    //    line.treatEndAsSpace = false;
    //}
    if (self.blockSession.lineWithPendingLineEndRenderManner) |line| {
        line.treatEndAsSpace = false;
    }

    self.blockSession = .{
        .atomBlock = atomBlock,
    };
}

fn set_currnet_line(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32) void {
    if (lineInfo.tokens()) |tokens| {
        self.lineSession = .{
            .currentLine = lineInfo,
            .contentStart = lineStart,
            .tokens = tokens,
            .anchor = lineStart,
            //.cursor = contentStart,
        };
    } else unreachable;
}

fn try_to_determine_line_end_render_manner(self: *ContentParser) void {
    if (self.lineSession.isMedia) {
        // self.lineSession.currentLine.treatEndAsSpace = false;
        std.debug.assert(self.lineSession.currentLine.treatEndAsSpace == false);
        return;
    }

    if (self.lineSession.lastPlainTextToken) |token| {
        std.debug.assert(token.tokenType == .plainText);
        std.debug.assert(self.blockSession.lineWithPendingLineEndRenderManner == null);
        std.debug.assert(token == self.blockSession.lastPlainTextToken);
        if (self.blockSession.spanStatusChangesAfterTheLastPlainTextToken != 0) {
            std.debug.assert(self.lineSession.currentLine.treatEndAsSpace == false);
            return;
        }

        const text = self.docParser.tmdDoc.data[token.start()..token.end()];
        std.debug.assert(text.len > 0);

        // ToDo: use ends_with_space instead?
        if (utf8.end_with_CJK_rune(text) or LineScanner.ends_with_blank(text)) {
            std.debug.assert(self.lineSession.currentLine.treatEndAsSpace == false);
            return;
        }

        // may be reserted in determine_pending_line_end_render_manner.
        self.lineSession.currentLine.treatEndAsSpace = true;

        self.blockSession.lineWithPendingLineEndRenderManner = self.lineSession.currentLine;

        //self.blockSession.endLine = self.lineSession.currentLine;

    } else {
        // self.blockSession.lineWithPendingLineEndRenderManner might null or not.
        // self.lineSession.currentLine.treatEndAsSpace = false;
        std.debug.assert(self.lineSession.currentLine.treatEndAsSpace == false);
    }
}

fn determine_pending_line_end_render_manner(self: *ContentParser) void {
    if (self.blockSession.lineWithPendingLineEndRenderManner) |line| {
        std.debug.assert(line.treatEndAsSpace);

        defer self.blockSession.lineWithPendingLineEndRenderManner = null;

        if (self.lineSession.tokens.tail()) |element| {
            const token = &element.value;
            switch (token.tokenType) {
                .spanMark => |spanMark| {
                    std.debug.assert(!spanMark.open);
                    line.treatEndAsSpace = false;
                },
                .leadingMark => |leadingMark| {
                    std.debug.assert(leadingMark.markType == .lineBreak or leadingMark.markType == .media);
                    line.treatEndAsSpace = false;
                },
                .plainText => |_| {
                    const text = self.docParser.tmdDoc.data[token.start()..token.end()];
                    std.debug.assert(text.len > 0);

                    line.treatEndAsSpace = !utf8.start_with_CJK_rune(text);

                    // By the rules, the line is actually unnecessary.
                    //if (line.treatEndAsSpace) self.blockSession.currentTextNumber += 1;
                },
                else => unreachable,
            }
        } else unreachable;
    }
}

fn create_token(self: ContentParser) !*tmd.TokenInfo {
    var tokenInfoElement = try list.createListElement(tmd.TokenInfo, self.docParser.allocator);
    self.lineSession.tokens.push(tokenInfoElement);

    return &tokenInfoElement.value;
}

fn create_comment_text_token(self: *ContentParser, start: u32, end: u32, inAttributesLine: bool) !*tmd.TokenInfo {
    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .commentText = .{
            .start = start,
            .end = end,
            .inAttributesLine = inAttributesLine, // self.lineSession.currentLine.isAttributes(),
        },
    };
    return tokenInfo;
}

fn create_plain_text_token(self: *ContentParser, start: u32, end: u32) !*tmd.TokenInfo {
    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .plainText = .{
            .start = start,
            .end = end,
        },
    };

    if (self.blockSession.lastLinkInfoToken) |link| {
        if (link.tokenType.linkInfo.info.firstPlainText == null) {
            link.tokenType.linkInfo.info.firstPlainText = tokenInfo;
        } else if (self.blockSession.lastPlainTextToken) |text| {
            text.tokenType.plainText.nextInLink = tokenInfo;
        } else unreachable;
    }
    self.blockSession.lastPlainTextToken = tokenInfo;
    self.blockSession.spanStatusChangesAfterTheLastPlainTextToken = 0;
    self.blockSession.currentTextNumber += 1;

    self.lineSession.spanStatusChangesBeforeTheFirstPlainTextToken = 0;
    if (self.lineSession.lastPlainTextToken == null) {
        self.determine_pending_line_end_render_manner();
    }
    self.lineSession.lastPlainTextToken = tokenInfo;
    self.lineSession.activePlainText = &tokenInfo.tokenType.plainText;

    return tokenInfo;
}

fn create_leading_mark(self: *ContentParser, markType: tmd.LineSpanMarkType, markStart: u32, markLen: u32) !*tmd.LeadingMark {
    std.debug.assert(self.lineSession.lastPlainTextToken == null);

    std.debug.assert(markStart == self.lineSession.contentStart);

    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .leadingMark = .{
            .start = markStart,
            .markType = markType,
            .markLen = markLen,
            .blankLen = undefined, // might be modified later
        },
    };

    switch (markType) {
        .lineBreak => {
            self.determine_pending_line_end_render_manner();
        },
        .media => {
            self.determine_pending_line_end_render_manner();
            self.lineSession.isMedia = true;
        },
        else => {},
    }

    return &tokenInfo.tokenType.leadingMark;
}

fn open_span(self: *ContentParser, markType: tmd.SpanMarkType, markStart: u32, markLen: u32, isSecondary: bool) !*tmd.SpanMark {
    std.debug.assert(markStart >= self.lineSession.contentStart);

    if (markType == .link and !isSecondary) {
        // Link needs 2 tokens to store information.
        var tokenInfo = try self.create_token();
        tokenInfo.tokenType = .{
            .linkInfo = .{
                .info = .{
                    .firstPlainText = null,
                },
            },
        };
        self.blockSession.lastLinkInfoToken = tokenInfo;

        var linkElement = try list.createListElement(tmd.Link, self.docParser.allocator);
        self.docParser.tmdDoc.links.push(linkElement);
        const link = &linkElement.value;
        link.* = .{
            .info = &tokenInfo.tokenType.linkInfo,
        };

        //if (self.docParser.nextElementAttributes) |as| {
        //    link.attrs = as;
        //    tokenInfo.tokenType.linkInfo.attrs = &link.attrs;
        //
        //    self.docParser.nextElementAttributes = null;
        //}
    }

    // Create the open mark.
    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .spanMark = .{
            .start = markStart,
            .open = true,
            .secondary = isSecondary,
            .markType = markType,
            .markLen = @intCast(markLen),
            .blankLen = undefined, // will be modified later
            .inComment = self.isCommentLineParser(),
            .blankSpan = false, // will be determined finally later
        },
    };

    self.lineSession.activePlainText = null;

    self.blockSession.spanStatuses[markType.asInt()] = .{
        .markLen = @intCast(markLen),
        .openMark = &tokenInfo.tokenType.spanMark,
        .openTextNumber = self.blockSession.currentTextNumber,
    };
    const bit: u32 = @as(u32, 1) << @truncate(markType.asInt());
    if (self.lineSession.lastPlainTextToken == null) {
        self.lineSession.spanStatusChangesBeforeTheFirstPlainTextToken |= bit;
    }
    self.blockSession.spanStatusChangesAfterTheLastPlainTextToken |= bit;

    return &tokenInfo.tokenType.spanMark;
}

fn close_span(self: *ContentParser, markType: tmd.SpanMarkType, markStart: u32, markLen: u32, openMark: *tmd.SpanMark) !*tmd.SpanMark {
    //self.try_to_attach_pending_spaces_to_open_mark();

    std.debug.assert(markStart >= self.lineSession.contentStart);

    if (markType == .link) {
        self.blockSession.lastLinkInfoToken = null;
    }

    const spanStatus = &self.blockSession.spanStatuses[markType.asInt()];
    std.debug.assert(self.blockSession.currentTextNumber >= spanStatus.openTextNumber);
    std.debug.assert(spanStatus.openMark == openMark);
    spanStatus.openMark = null;
    const isBlankSpan = self.blockSession.currentTextNumber <= spanStatus.openTextNumber;
    openMark.blankSpan = isBlankSpan;

    // Create the close mark.
    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .spanMark = .{
            .start = markStart,
            .open = false,
            .markType = markType,
            .markLen = @intCast(markLen),
            .blankLen = undefined, // will be modified later
            .inComment = self.isCommentLineParser(),
            .blankSpan = isBlankSpan,
        },
    };

    self.lineSession.activePlainText = null;

    const bit: u32 = @as(u32, 1) << @truncate(markType.asInt());
    if (self.lineSession.lastPlainTextToken == null) {
        if (self.lineSession.spanStatusChangesBeforeTheFirstPlainTextToken & bit == 0) {
            self.determine_pending_line_end_render_manner();
        } else {
            self.lineSession.spanStatusChangesBeforeTheFirstPlainTextToken &= ~bit;
        }
    }
    self.blockSession.spanStatusChangesAfterTheLastPlainTextToken &= ~bit;

    return &tokenInfo.tokenType.spanMark;
}

fn create_even_backticks_span(self: *ContentParser, markStart: u32, pairCount: u32, isSecondary: bool) !*tmd.DummyCodeSpans {
    std.debug.assert(markStart >= self.lineSession.contentStart);

    // Create the dummy code spans mark.
    var tokenInfo = try self.create_token();
    tokenInfo.tokenType = .{
        .evenBackticks = .{
            .start = markStart,
            .secondary = isSecondary,
            .pairCount = pairCount,
        },
    };

    if (isSecondary or pairCount > 1) {
        self.blockSession.currentTextNumber += 1;
    }

    self.lineSession.activePlainText = null;

    return &tokenInfo.tokenType.evenBackticks;
}

fn close_opening_spans(self: *ContentParser) void {
    for (self.blockSession.spanStatuses[0..]) |spanStatus| {
        if (spanStatus.openMark) |openMark| {
            std.debug.assert(self.blockSession.currentTextNumber >= spanStatus.openTextNumber);
            openMark.blankSpan = self.blockSession.currentTextNumber <= spanStatus.openTextNumber;
        }
    }
}

pub fn parse_attributes_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32) !u32 {
    self.set_currnet_line(lineInfo, lineStart);

    const lineScanner = &self.docParser.lineScanner;

    const textStart = lineScanner.cursor;
    const numBlanks = lineScanner.readUntilLineEnd();
    const textEnd = lineScanner.cursor - numBlanks;
    if (textEnd > textStart) {
        _ = try self.create_comment_text_token(textStart, textEnd, true);
    }

    return textEnd;
}

pub fn parse_usual_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32, handleLineSpanMark: bool) !u32 {
    self.set_currnet_line(lineInfo, lineStart);

    return try self.parse_line_tokens(handleLineSpanMark);
}

pub fn parse_header_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32) !u32 {
    self.set_currnet_line(lineInfo, lineStart);

    //return try self.parse_line_tokens(false);
    return try self.parse_line_tokens(true);
}

fn parse_line_tokens(self: *ContentParser, handleLineSpanMark: bool) !u32 {
    const lineStart = self.lineSession.contentStart;
    const lineScanner = &self.docParser.lineScanner;
    std.debug.assert(lineScanner.lineEnd == null);

    const contentEnd = parse_tokens: {
        var textStart = lineStart;

        if (handleLineSpanMark) handle_leading_mark: {
            std.debug.assert(textStart == lineScanner.cursor);

            const c = lineScanner.peekCursor();
            std.debug.assert(!LineScanner.bytesKindTable[c].isBlank());

            const leadingMarkType = switch (LineScanner.bytesKindTable[c]) {
                .leadingMark => |leadingMarkType| leadingMarkType,
                else => break :handle_leading_mark,
            };

            lineScanner.advance(1);
            const markLen = lineScanner.readUntilNotChar(c) + 1;
            if (markLen != 2) break :handle_leading_mark;

            const markEnd = lineScanner.cursor;
            std.debug.assert(markEnd == textStart + markLen);

            const isBare = check_bare: {
                if (lineScanner.lineEnd != null) break :check_bare true;

                const numSpaces = lineScanner.readUntilNotBlank();
                if (lineScanner.lineEnd != null) break :check_bare true;

                if (numSpaces == 0) break :handle_leading_mark;

                break :check_bare false;
            };

            const leadingMark = try self.create_leading_mark(leadingMarkType, textStart, markLen);
            leadingMark.isBare = isBare;

            if (isBare) {
                leadingMark.blankLen = 0;
                break :parse_tokens markEnd;
            }

            textStart = lineScanner.cursor;
            leadingMark.blankLen = textStart - markEnd;

            switch (leadingMarkType) {
                .lineBreak => break :handle_leading_mark,
                .comment => {
                    const isLineDefinition = lineScanner.peekCursor() == '_' and lineScanner.peekNext() == '_';
                    if (!isLineDefinition) {
                        const numBlanks = lineScanner.readUntilLineEnd();
                        const textEnd = lineScanner.cursor - numBlanks;
                        std.debug.assert(textEnd > textStart);
                        _ = try self.create_comment_text_token(textStart, textEnd, false);
                        break :parse_tokens textEnd;
                    }

                    // jump out of the swith block
                },
                .escape => {
                    const numBlanks = lineScanner.readUntilLineEnd();
                    const textEnd = lineScanner.cursor - numBlanks;
                    std.debug.assert(textEnd > textStart);
                    _ = try self.create_plain_text_token(textStart, textEnd);
                    break :parse_tokens textEnd;
                },
                .media => {
                    const numBlanks = lineScanner.readUntilLineEnd();
                    const textEnd = lineScanner.cursor - numBlanks;
                    std.debug.assert(textEnd > textStart);
                    _ = try self.create_plain_text_token(textStart, textEnd);
                    break :parse_tokens textEnd;
                },
            }

            // To parse link definition tokens.

            std.debug.assert(leadingMarkType == .comment);

            const commentLineParser = self.docParser.commentLineParser;
            commentLineParser.on_new_atom_block(self.blockSession.atomBlock);
            commentLineParser.set_currnet_line(self.lineSession.currentLine, textStart);
            break :parse_tokens try commentLineParser.parse_line_tokens(false);
        }

        if (lineScanner.lineEnd != null) { // the line only contains one leading mark
            std.debug.assert(lineScanner.cursor > textStart);
            _ = try self.create_plain_text_token(textStart, lineScanner.cursor);
            break :parse_tokens lineScanner.cursor;
        }

        const codeSpanStatus = self.codeSpanStatus;

        parse_span_marks: while (true) {
            std.debug.assert(lineScanner.lineEnd == null);

            const inPrimaryCodeSpan = if (codeSpanStatus.openMark) |m| blk: {
                break :blk if (m.secondary) false else true;
            } else false;

            const numBlanks = lineScanner.readUntilSpanMarkChar(if (inPrimaryCodeSpan) '`' else null);

            if (lineScanner.lineEnd != null) {
                const textEnd = lineScanner.cursor - numBlanks;
                if (textEnd > textStart) {
                    _ = try self.create_plain_text_token(textStart, textEnd);
                } else std.debug.assert(textEnd == textStart);

                break :parse_tokens textEnd;
            }

            const c = lineScanner.peekCursor();

            const markStart = lineScanner.cursor;
            lineScanner.advance(1);
            const markLen = lineScanner.readUntilNotChar(c) + 1;
            const markEnd = lineScanner.cursor;
            std.debug.assert(markEnd == markStart + markLen);

            const mark = LineScanner.bytesKindTable[c].spanMark;

            switch (mark) {
                .code => {
                    const codeMarkStart = if (markLen > 1) blk: {
                        const isSecondary = markStart > lineStart and lineScanner.data[markStart - 1] == '^';

                        const textEnd = if (isSecondary) markStart - 1 else markStart;
                        std.debug.assert(textEnd - textStart >= numBlanks);

                        if (textEnd > textStart) {
                            _ = try self.create_plain_text_token(textStart, textEnd);
                        } else std.debug.assert(textEnd == textStart);

                        _ = try self.create_even_backticks_span(textEnd, markLen >> 1, isSecondary);

                        if (markLen & 1 == 0) {
                            if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                            textStart = markEnd;
                            continue :parse_span_marks;
                        }

                        std.debug.assert(markEnd - 1 == markStart + markLen - (markLen & 1));

                        break :blk markEnd - 1;
                    } else blk: {
                        std.debug.assert(markLen == 1);
                        break :blk markStart;
                    };

                    std.debug.assert(markLen & 1 == 1);

                    if (codeSpanStatus.openMark) |openMark| {
                        if (codeMarkStart == markStart) { // no dummmyCodeSpan
                            const textEnd = markStart - numBlanks;
                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            const closeCodeSpanMark = try self.close_span(.code, textEnd, 1, openMark);
                            closeCodeSpanMark.blankLen = numBlanks;
                        } else {
                            const closeCodeSpanMark = try self.close_span(.code, codeMarkStart, 1, openMark);
                            closeCodeSpanMark.blankLen = 0;
                        }

                        if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                        std.debug.assert(markEnd == lineScanner.cursor);
                        textStart = markEnd;
                        continue :parse_span_marks;
                    } else {
                        const openCodeSpanMark = if (codeMarkStart == markStart) blk: { // no dummmyCodeSpan
                            const isSecondary = markStart > lineStart and lineScanner.data[markStart - 1] == '^';

                            const textEnd = if (isSecondary) markStart - 1 else markStart;
                            std.debug.assert(textEnd - textStart >= numBlanks);

                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            break :blk try self.open_span(.code, textEnd, 1, isSecondary);
                        } else try self.open_span(.code, codeMarkStart, 1, false);

                        openCodeSpanMark.blankLen = 0; // might be modified below

                        if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                        openCodeSpanMark.blankLen = lineScanner.cursor - markEnd;

                        textStart = lineScanner.cursor;
                        continue :parse_span_marks;
                    }
                },
                else => |spanMarkType| {
                    create_mark_token: {
                        // if (codeSpanStatus.openMark) |_| break :create_mark_token;
                        if (inPrimaryCodeSpan) break :create_mark_token;
                        if (markLen < 2 or markLen >= tmd.MaxSpanMarkLength) break :create_mark_token;

                        const markStatus = self.span_status(spanMarkType);

                        if (markStatus.openMark) |openMark| {
                            if (markLen != markStatus.markLen) break :create_mark_token;

                            const textEnd = markStart - numBlanks;
                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            const closeMark = try self.close_span(spanMarkType, textEnd, markLen, openMark);
                            closeMark.blankLen = numBlanks;

                            if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                            textStart = markEnd;
                            continue :parse_span_marks;
                        } else {
                            const isSecondary = markStart > lineStart and lineScanner.data[markStart - 1] == '^';

                            const textEnd = if (isSecondary) markStart - 1 else markStart;
                            std.debug.assert(textEnd - textStart >= numBlanks);

                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            const openMark = try self.open_span(spanMarkType, textEnd, markLen, isSecondary);

                            std.debug.assert(markEnd == lineScanner.cursor);

                            if (lineScanner.lineEnd != null) {
                                openMark.blankLen = 0;
                                break :parse_tokens markEnd;
                            }

                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd != null) {
                                openMark.blankLen = 0;
                                break :parse_tokens markEnd;
                            }

                            openMark.blankLen = lineScanner.cursor - markEnd;

                            textStart = lineScanner.cursor;
                            continue :parse_span_marks;
                        }
                    }

                    if (lineScanner.lineEnd != null) {
                        std.debug.assert(markEnd > textStart);
                        _ = try self.create_plain_text_token(textStart, markEnd);
                        break :parse_tokens markEnd;
                    }

                    // keep textStart unchanged.
                    continue :parse_span_marks;
                },
            }
        } // parse_span_marks
    }; // parse_tokens

    if (self.lineSession.tokens.head()) |head| blk: {
        switch (head.value.tokenType) {
            .leadingMark => |m| if (m.markType == .media) break :blk,
            else => {},
        }
        self.blockSession.atomBlock.hasNonMediaTokens = true;
    }

    std.debug.assert(lineScanner.lineEnd != null);

    if (self.isCommentLineParser()) {} else if (lineScanner.lineEnd != .void) {
        self.try_to_determine_line_end_render_manner();
    } else if (self.blockSession.lineWithPendingLineEndRenderManner) |line| {
        line.treatEndAsSpace = false;
    }

    if (self.lineSession.tokens.tail()) |element| {
        const lastToken = &element.value;
        std.debug.assert(contentEnd == lastToken.end());
    } else unreachable;

    return contentEnd;
}

//};