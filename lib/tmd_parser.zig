const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const utf8 = @import("utf8.zig");
const url = @import("url.zig");

pub fn destroy_tmd_doc(tmdDoc: *tmd.Doc, allocator: mem.Allocator) void {
    destroyListElements(tmd.BlockInfo, tmdDoc.blocks, null, allocator);

    const T = struct {
        fn destroyLineTokens(lineInfo: *tmd.LineInfo, a: mem.Allocator) void {
            if (lineInfo.tokens()) |tokens| {
                destroyListElements(tmd.TokenInfo, tokens.*, null, a);
            }
        }
    };

    destroyListElements(tmd.LineInfo, tmdDoc.lines, T.destroyLineTokens, allocator);
    destroyListElements(tmd.BlockAttibutes, tmdDoc.blockAttributes, null, allocator);

    tmdDoc.* = .{ .data = "" };
}

pub fn parse_tmd_doc(tmdData: []const u8, allocator: mem.Allocator) !tmd.Doc {
    var tmdDoc = tmd.Doc{ .data = tmdData };

    errdefer destroy_tmd_doc(&tmdDoc, allocator);

    var docParser = DocParser{ .tmdDoc = &tmdDoc };
    try docParser.parseAll(tmdData, allocator);

    if (false and builtin.mode == .Debug)
        dumpTmdDoc(&tmdDoc);

    return tmdDoc;
}

//===========================================

fn createListElement(comptime Node: type, allocator: mem.Allocator) !*list.Element(Node) {
    return try allocator.create(list.Element(Node));
}

fn destroyListElements(comptime NodeValue: type, l: list.List(NodeValue), comptime onNodeValue: ?fn (*NodeValue, mem.Allocator) void, allocator: mem.Allocator) void {
    var element = l.head();
    if (onNodeValue) |f| {
        while (element) |e| {
            const next = e.next;
            f(&e.value, allocator);
            allocator.destroy(e);
            element = next;
        }
    } else while (element) |e| {
        const next = e.next;
        allocator.destroy(e);
        element = next;
    }
}

// BlockArranger determines block nesting depths.
const BlockArranger = struct {
    root: *tmd.BlockInfo,

    stackedBlocks: [tmd.MaxBlockNestingDepth]*tmd.BlockInfo = undefined,
    count_1: tmd.BlockNestingDepthType = 0,

    openingBaseBlocks: [tmd.MaxBlockNestingDepth]BaseContext = undefined,
    baseCount_1: tmd.BlockNestingDepthType = 0,

    const BaseContext = struct {
        nestingDepth: tmd.BlockNestingDepthType,

        openingListNestingDepths: [tmd.MaxListNestingDepthPerBase]u6 = [_]u6{0} ** tmd.MaxListNestingDepthPerBase,
        openingListCount: tmd.ListNestingDepthType = 0,
    };

    fn start(root: *tmd.BlockInfo) BlockArranger {
        root.* = .{ .nestingDepth = 0, .blockType = .{
            .root = .{},
        } };

        var s = BlockArranger{
            .root = root,
            .count_1 = 1, // because of the fake first child
            .baseCount_1 = 0,
        };
        s.stackedBlocks[0] = root;
        s.openingBaseBlocks[0] = BaseContext{
            .nestingDepth = 0,
        };
        s.stackedBlocks[s.count_1] = root; // fake first child (for implementation convenience)
        return s;
    }

    fn end(self: *BlockArranger) void {
        while (self.tryToCloseCurrentBaseBlock()) |_| {}
    }

    // ToDo: change method name to foo_bar style?

    fn canOpenBaseBlock(self: *const BlockArranger) bool {
        if (self.count_1 == tmd.MaxBlockNestingDepth - 1) {
            return false;
        }
        return self.baseCount_1 < tmd.MaxBlockNestingDepth - 1;
    }

    fn canCloseBaseBlock(self: *const BlockArranger) bool {
        return self.baseCount_1 > 0;
    }

    fn openBaseBlock(self: *BlockArranger, newBaseBlock: *tmd.BlockInfo, firstInContainer: bool) !void {
        std.debug.assert(newBaseBlock.blockType == .base);

        if (!self.canOpenBaseBlock()) return error.NestingDepthTooLarge;

        if (firstInContainer) {
            try self.stackAsFirstInContainer(newBaseBlock);
        } else {
            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);

            if (last.blockType == .blank) {
                try self.stackAsChildOfBase(newBaseBlock);
            } else {
                newBaseBlock.nestingDepth = self.count_1;
                self.stackedBlocks[self.count_1] = newBaseBlock;
            }
        }

        self.baseCount_1 += 1;
        self.openingBaseBlocks[self.baseCount_1] = BaseContext{
            .nestingDepth = self.count_1,
        };

        self.count_1 += 1;
        self.stackedBlocks[self.count_1] = self.root; // fake first child (for implementation convenience)
    }

    fn closeCurrentBaseBlock(self: *BlockArranger) !*tmd.BlockInfo {
        if (!self.canCloseBaseBlock()) return error.NoBaseBlockToClose;

        return self.tryToCloseCurrentBaseBlock() orelse unreachable;
    }

    fn tryToCloseCurrentBaseBlock(self: *BlockArranger) ?*tmd.BlockInfo {
        self.clearListContextInBase(true);

        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);
        const baseBlock = self.stackedBlocks[baseContext.nestingDepth];
        std.debug.assert(baseBlock.blockType == .base or baseBlock.blockType == .root);

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);

        if (last.blockType == .blank) {
            // Ensure the nestingDepth of the blank block.
            last.nestingDepth = baseContext.nestingDepth + 1;
        }

        self.count_1 = baseContext.nestingDepth;
        if (self.baseCount_1 == 0) {
            return null;
        }
        self.baseCount_1 -= 1;
        return baseBlock;
    }

    fn stackAsChildOfBase(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);
        std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].blockType == .base or self.stackedBlocks[baseContext.nestingDepth].blockType == .root);

        if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
            return error.NestingDepthTooLarge;
        }

        self.clearListContextInBase(false);

        self.count_1 = baseContext.nestingDepth + 1;
        blockInfo.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = blockInfo;
    }

    fn stackContainerBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
        std.debug.assert(blockInfo.isContainer());
        std.debug.assert(blockInfo.blockType != .list_item);

        try self.stackAsChildOfBase(blockInfo);
    }

    fn assertBaseOpeningListCount(self: *BlockArranger) void {
        if (builtin.mode == .Debug) {
            var baseContext = &self.openingBaseBlocks[self.baseCount_1];
            if (baseContext.openingListCount > 0) {
                //std.debug.print("assertBaseOpeningListCount {}, {} - {} - 1\n", .{baseContext.openingListCount, self.count_1, baseContext.nestingDepth});
                std.debug.assert(self.count_1 == baseContext.nestingDepth + baseContext.openingListCount + 1);
            }
            var count: @TypeOf(baseContext.openingListCount) = 0;
            for (&baseContext.openingListNestingDepths) |d| {
                if (d != 0) count += 1;
            }
            std.debug.assert(count == baseContext.openingListCount);
        }
    }

    fn stackListItemBlock(self: *BlockArranger, listItemBlock: *tmd.BlockInfo) !void {
        std.debug.assert(listItemBlock.blockType == .list_item);

        var baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);

        self.assertBaseOpeningListCount();

        const newListItem = &listItemBlock.blockType.list_item;

        const isFirstInList = if (baseContext.openingListCount == 0) blk: {
            self.count_1 = baseContext.nestingDepth + 1;
            break :blk true;
        } else baseContext.openingListNestingDepths[newListItem._markTypeIndex] == 0;

        if (isFirstInList) {
            newListItem.isFirst = true;

            listItemBlock.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = listItemBlock;

            baseContext.openingListNestingDepths[newListItem._markTypeIndex] = self.count_1;
            baseContext.openingListCount += 1;
        } else {
            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
            std.debug.assert(last.blockType != .list_item);

            var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
            var depth = self.count_1 - 1;
            while (depth > baseContext.nestingDepth) : (depth -= 1) {
                std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
                std.debug.assert(self.stackedBlocks[depth].blockType == .list_item);
                var item = &self.stackedBlocks[depth].blockType.list_item;
                if (item._markTypeIndex == newListItem._markTypeIndex) {
                    break;
                }
                item.isLast = true;
                baseContext.openingListNestingDepths[item._markTypeIndex] = 0;
                deltaCount += 1;
            }

            std.debug.assert(depth > baseContext.nestingDepth);
            std.debug.assert(baseContext.openingListCount > deltaCount);

            if (deltaCount > 0) {
                baseContext.openingListCount -= deltaCount;

                if (last.blockType == .blank) {
                    // Ensure the nestingDepth of the blank block.
                    last.nestingDepth = depth + 1;
                }
            } else {
                std.debug.assert(last.nestingDepth == depth + 1);
            }

            self.count_1 = depth;
            listItemBlock.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = listItemBlock;
        }
    }

    // ToDo: remove the forClosingBase parameter?
    fn clearListContextInBase(self: *BlockArranger, forClosingBase: bool) void {
        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);
        std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].blockType == .base or self.stackedBlocks[baseContext.nestingDepth].blockType == .root);

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
        std.debug.assert(last.blockType != .list_item);
        defer { // ToDo: forget why defer it here?
            self.count_1 = baseContext.nestingDepth + 1;
            if (last.blockType == .blank) {
                // Ensure the nestingDepth of the blank block.
                last.nestingDepth = self.count_1;
            }
        }

        if (baseContext.openingListCount == 0) {
            return;
        }

        self.assertBaseOpeningListCount();

        _ = forClosingBase; // ToDo: the logic will be a bit simpler but might be unnecessary.

        {
            var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
            var depth = self.count_1 - 1;
            while (depth > baseContext.nestingDepth) : (depth -= 1) {
                std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
                std.debug.assert(self.stackedBlocks[depth].blockType == .list_item);
                var item = &self.stackedBlocks[depth].blockType.list_item;
                item.isLast = true;
                baseContext.openingListNestingDepths[item._markTypeIndex] = 0;
                deltaCount += 1;
            }

            std.debug.assert(depth == baseContext.nestingDepth);
            std.debug.assert(baseContext.openingListCount == deltaCount);
            baseContext.openingListCount = 0;
        }
    }

    fn stackAsFirstInContainer(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.isContainer());
        std.debug.assert(last.nestingDepth == self.count_1);

        std.debug.assert(blockInfo.blockType != .blank);

        if (self.count_1 >= tmd.MaxBlockNestingDepth - 1) {
            return error.NestingDepthTooLarge;
        }

        self.count_1 += 1;
        blockInfo.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = blockInfo;
    }

    fn stackAtomBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo, firstInContainer: bool) !void {
        std.debug.assert(blockInfo.isAtom());

        if (firstInContainer) {
            try self.stackAsFirstInContainer(blockInfo);
            return;
        }

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.nestingDepth == self.count_1 or last.blockType == .base or last.blockType == .root);
        std.debug.assert(!last.isContainer());

        if (last.blockType == .blank) {
            std.debug.assert(blockInfo.blockType != .blank);
            try self.stackAsChildOfBase(blockInfo);
            return;
        }

        blockInfo.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = blockInfo;
    }
};

const ContentParser = struct {
    allocator: mem.Allocator,
    tmdData: []const u8, // ToDo: remove?
    lineScanner: *LineScanner,

    linkInfos: ?struct {
        first: *tmd.LinkInfo,
        last: *tmd.LinkInfo,
    } = null,

    escapedSpanStatus: *SpanStatus = undefined,
    codeSpanStatus: *SpanStatus = undefined,
    linkSpanStatus: *SpanStatus = undefined,

    blockSession: struct {
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

    fn make(allocator: mem.Allocator, lineScanner: *LineScanner) ContentParser {
        std.debug.assert(MarkCount <= 32);

        return .{
            .allocator = allocator,
            .tmdData = lineScanner.data,
            .lineScanner = lineScanner,
        };
    }

    fn tmdData(self: *ContentParser) []const u8 {
        return self.lineScanner.data;
    }

    fn deinit(_: *ContentParser) void {
        // ToDo: looks nothing needs to do here.
    }

    fn init(self: *ContentParser) void {
        self.escapedSpanStatus = self.span_status(.escaped);
        self.codeSpanStatus = self.span_status(.code);
        self.linkSpanStatus = self.span_status(.link);
    }

    fn span_status(self: *ContentParser, markType: tmd.SpanMarkType) *SpanStatus {
        return &self.blockSession.spanStatuses[markType.asInt()];
    }

    fn on_new_atom_block(self: *ContentParser) void {
        self.close_opening_spans(); // for the last block

        //if (self.blockSession.endLine) |line| {
        //    line.treatEndAsSpace = false;
        //}
        if (self.blockSession.lineWithPendingLineEndRenderManner) |line| {
            line.treatEndAsSpace = false;
        }

        self.blockSession = .{};
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

            const text = self.tmdData[token.start()..token.end()];
            std.debug.assert(text.len > 0);

            // ToDo: use ends_with_space instead?
            if (utf8.end_with_CJK_rune(text) or ends_with_blank(text)) {
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
                        const text = self.tmdData[token.start()..token.end()];
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
        var tokenInfoElement = try self.allocator.create(list.Element(tmd.TokenInfo));
        self.lineSession.tokens.push(tokenInfoElement);

        return &tokenInfoElement.value;
    }

    fn create_comment_text_token(self: *ContentParser, start: u32, end: u32) !*tmd.TokenInfo {
        var tokenInfo = try self.create_token();
        tokenInfo.tokenType = .{
            .commentText = .{
                .start = start,
                .end = end,
                .inDirective = self.lineSession.currentLine.isDirective(),
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

            const linkInfo = &tokenInfo.tokenType.linkInfo;
            if (self.linkInfos) |*infos| {
                infos.last.next = linkInfo;
                infos.last = linkInfo;
            } else {
                self.linkInfos = .{
                    .first = linkInfo,
                    .last = linkInfo,
                };
            }
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
                .inDirective = self.lineSession.currentLine.isDirective(),
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
                .inDirective = self.lineSession.currentLine.isDirective(),
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

    fn create_dummy_code_span(self: *ContentParser, markStart: u32, pairCount: u32, isSecondary: bool) !*tmd.DummyCodeSpans {
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

    // ToDo: need a more specific and restricted implementation.
    //       *. When starts with __, then the content after close __ mark will be ignored.
    //       *. When starts with ##, then the content after close ## mark will be ignored.
    //       *. For other cases, all content will be ignored.
    fn parse_directive_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32, isPureComment: bool) !u32 {
        const lineScanner = self.lineScanner;

        if (isPureComment) { // 3 / chars
            self.set_currnet_line(lineInfo, lineStart);

            const textStart = lineScanner.cursor;
            const numBlanks = lineScanner.readUntilLineEnd();
            const textEnd = lineScanner.cursor - numBlanks;
            if (textEnd > textStart) {
                _ = try self.create_comment_text_token(textStart, textEnd);
            }

            return textEnd;
        }

        return try self.parse_line_tokens(lineInfo, lineStart, true);
    }

    fn parse_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32, handlLineSpanMark: bool) !u32 {
        self.set_currnet_line(lineInfo, lineStart);

        std.debug.assert(self.lineScanner.lineEnd == null);

        const lineScanner = self.lineScanner;

        const contentEnd = parse_tokens: {
            var textStart = lineStart;

            if (handlLineSpanMark) {
                std.debug.assert(textStart == lineScanner.cursor);

                const c = lineScanner.peekCursor();
                std.debug.assert(!LineScanner.blanksTable[c]);

                if (LineScanner.leadingMarksTable[c]) |leadingMarkType| handle_leading_mark: {
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

                    if (leadingMarkType == .lineBreak) break :handle_leading_mark;

                    const numBlanks = lineScanner.readUntilLineEnd();
                    const textEnd = lineScanner.cursor - numBlanks;

                    std.debug.assert(textEnd > textStart);

                    _ = switch (leadingMarkType) {
                        .comment => try self.create_comment_text_token(textStart, textEnd),
                        .media => try self.create_plain_text_token(textStart, textEnd),
                        .anchor => try self.create_comment_text_token(textStart, textEnd),
                        else => unreachable,
                    };

                    break :parse_tokens textEnd;
                }
            }

            const escapedSpanStatus = self.escapedSpanStatus;
            const codeSpanStatus = self.codeSpanStatus;

            search_marks: while (true) {
                std.debug.assert(lineScanner.lineEnd == null);

                if (escapedSpanStatus.openMark) |openMark| escape_context: {
                    std.debug.assert(openMark.markType == .escaped);

                    const mark = LineScanner.spanMarksTable['!'].?;
                    std.debug.assert(mark.markType == .escaped);
                    while (true) {
                        var numBlanks = lineScanner.readUntilSpanMarkChar(mark.precedence);
                        if (lineScanner.lineEnd != null) {
                            const textEnd = lineScanner.cursor - numBlanks;
                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                                break :parse_tokens textEnd;
                            }
                        }

                        std.debug.assert(lineScanner.peekCursor() == '!');

                        const markStart = lineScanner.cursor;
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar('!') + 1;
                        if (markLen == escapedSpanStatus.markLen) {
                            const markEnd = lineScanner.cursor;
                            std.debug.assert(markEnd == markStart + markLen);

                            const textEnd = if (openMark.secondary) blk: {
                                numBlanks = 0;
                                break :blk markStart;
                            } else markStart - numBlanks;

                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            const closeEscapeMark = try self.close_span(.escaped, textEnd, markLen, openMark);
                            closeEscapeMark.blankLen = numBlanks;

                            if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                            textStart = markEnd;
                            break :escape_context;
                        } else if (lineScanner.lineEnd != null) {
                            const markEnd = lineScanner.cursor;
                            std.debug.assert(markEnd == markStart + markLen);

                            const textEnd = if (openMark.secondary) blk: {
                                numBlanks = 0;
                                break :blk markStart;
                            } else markStart - numBlanks;

                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            break :parse_tokens markEnd;
                        }

                        // keep textStart unchanged and continue looking for escape close mark.

                    } // while (true)
                } // escape_context

                // To avoid code complexity, this block is cancelled.
                //if (codeSpanStatus.openMark) |openMark| code_span: {
                //    std.debug.assert(openMark.markType == .code);
                //    const codeMark = LineScanner.spanMarksTable['!'].?;
                //    std.debug.assert(codeMark.markType == .code);
                //}

                non_escape_context: while (true) {
                    std.debug.assert(lineScanner.lineEnd == null);

                    const numBlanks = lineScanner.readUntilSpanMarkChar(0);
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

                    const mark = LineScanner.spanMarksTable[c].?;

                    switch (mark.markType) {
                        .escaped => {
                            if (markLen < 2 or markLen >= tmd.MaxSpanMarkLength) {
                                if (lineScanner.lineEnd == null) continue :non_escape_context;

                                std.debug.assert(markEnd > textStart);
                                _ = try self.create_plain_text_token(textStart, markEnd);

                                break :parse_tokens markEnd;
                            }

                            const isSecondary = markStart > lineStart and lineScanner.data[markStart - 1] == '^';
                            const textEnd = if (isSecondary) markStart - 1 else markStart;
                            std.debug.assert(textEnd - textStart >= numBlanks);

                            if (textEnd > textStart) {
                                _ = try self.create_plain_text_token(textStart, textEnd);
                            } else std.debug.assert(textEnd == textStart);

                            const openEscapeMark = try self.open_span(.escaped, textEnd, markLen, isSecondary);

                            std.debug.assert(markEnd == lineScanner.cursor);

                            if (lineScanner.lineEnd != null) {
                                openEscapeMark.blankLen = 0;
                                break :parse_tokens markEnd;
                            }

                            if (isSecondary) {
                                openEscapeMark.blankLen = 0;
                                textStart = markEnd;
                                continue :search_marks;
                            }

                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd != null) {
                                openEscapeMark.blankLen = 0;
                                break :parse_tokens markEnd;
                            }

                            openEscapeMark.blankLen = lineScanner.cursor - markEnd;

                            textStart = lineScanner.cursor;
                            continue :search_marks;
                        },
                        .code => {
                            const codeMarkStart = if (markLen > 1) blk: {
                                const isSecondary = markStart > lineStart and lineScanner.data[markStart - 1] == '^';

                                const textEnd = if (isSecondary) markStart - 1 else markStart;
                                std.debug.assert(textEnd - textStart >= numBlanks);

                                if (textEnd > textStart) {
                                    _ = try self.create_plain_text_token(textStart, textEnd);
                                } else std.debug.assert(textEnd == textStart);

                                const dummyCodeSpan = try self.create_dummy_code_span(textEnd, markLen >> 1, isSecondary);
                                _ = dummyCodeSpan;

                                if (markLen & 1 == 0) {
                                    if (lineScanner.lineEnd != null) break :parse_tokens markEnd;

                                    textStart = markEnd;
                                    continue :non_escape_context;
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
                                continue :non_escape_context;
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
                                continue :non_escape_context;
                            }
                        },
                        else => |spanMarkType| {
                            create_mark_token: {
                                if (codeSpanStatus.openMark) |_| break :create_mark_token;
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
                                    continue :non_escape_context;
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
                                    continue :non_escape_context;
                                }
                            }

                            if (lineScanner.lineEnd != null) {
                                std.debug.assert(markEnd > textStart);
                                _ = try self.create_plain_text_token(textStart, markEnd);
                                break :parse_tokens markEnd;
                            }

                            // keep textStart unchanged.
                            continue :non_escape_context;
                        },
                    }
                } // non_escape_context
            } // while search_marks
        }; // parse_tokens

        std.debug.assert(lineScanner.lineEnd != null);

        if (lineScanner.lineEnd != .void) {
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

    // Match link definitions.

    fn tokenAsString(self: *const ContentParser, plainTextTokenInfo: *const tmd.TokenInfo) []const u8 {
        return self.tmdData[plainTextTokenInfo.start()..plainTextTokenInfo.end()];
    }

    fn copyLinkText(dst: anytype, from: u32, src: []const u8) u32 {
        var n: u32 = from;
        for (src) |r| {
            std.debug.assert(r != '\n');
            if (!LineScanner.blanksTable[r]) {
                dst.set(n, r);
                n += 1;
            }
        }
        return n;
    }

    const DummyLinkText = struct {
        pub fn set(_: DummyLinkText, _: u32, _: u8) void {}
    };

    const RealLinkText = struct {
        text: [*]u8,

        pub fn set(self: *const RealLinkText, n: u32, r: u8) void {
            self.text[n] = r;
        }
    };

    const RevisedLinkText = struct {
        len: u32 = 0,
        text: [*]const u8 = "".ptr,

        pub fn get(self: *const RevisedLinkText, n: u32) u8 {
            std.debug.assert(n < self.len);
            return self.text[n];
        }

        pub fn suffix(self: *const RevisedLinkText, from: u32) RevisedLinkText {
            std.debug.assert(from < self.len); // deliborately not <=
            return RevisedLinkText{
                .len = self.len - from,
                .text = self.text + from,
            };
        }

        pub fn prefix(self: *const RevisedLinkText, to: u32) RevisedLinkText {
            std.debug.assert(to < self.len); // deliborately not <=
            return RevisedLinkText{
                .len = to,
                .text = self.text,
            };
        }

        pub fn unprefix(self: *const RevisedLinkText, unLen: u32) RevisedLinkText {
            return RevisedLinkText{
                .len = self.len + unLen,
                .text = self.text - unLen,
            };
        }

        pub fn asString(self: *const RevisedLinkText) []const u8 {
            return self.text[0..self.len];
        }

        pub fn invert(t: *const RevisedLinkText) InvertedRevisedLinkText {
            return InvertedRevisedLinkText{
                .len = t.len,
                .text = t.text + t.len - 1, // -1 is to make some conveniences
            };
        }
    };

    // ToDo: this and the above types should not be public.
    //       Merge this file with the parser file?
    const InvertedRevisedLinkText = struct {
        len: u32 = 0,
        text: [*]const u8 = "".ptr,

        pub fn get(self: *const InvertedRevisedLinkText, n: u32) u8 {
            std.debug.assert(n < self.len);
            return (self.text - n)[0];
        }

        pub fn suffix(self: *const InvertedRevisedLinkText, from: u32) InvertedRevisedLinkText {
            std.debug.assert(from < self.len);
            return InvertedRevisedLinkText{
                .len = self.len - from,
                .text = self.text - from,
            };
        }

        pub fn prefix(self: *const InvertedRevisedLinkText, to: u32) InvertedRevisedLinkText {
            std.debug.assert(to < self.len);
            return InvertedRevisedLinkText{
                .len = to,
                .text = self.text,
            };
        }

        pub fn unprefix(self: *const InvertedRevisedLinkText, unLen: u32) InvertedRevisedLinkText {
            return InvertedRevisedLinkText{
                .len = self.len + unLen,
                .text = self.text + unLen,
            };
        }

        pub fn asString(self: *const InvertedRevisedLinkText) []const u8 {
            return (self.text - self.len + 1)[0..self.len];
        }
    };

    fn Patricia(comptime TextType: type) type {
        return struct {
            allocator: mem.Allocator,

            topTree: Tree = .{},
            nilNode: Node = .{
                .color = .black,
                .value = .{},
            },

            freeNodeList: ?*Node = null,
            //freeLinkInfoElement: list.List(*tmd.LinkInfo) = .{},

            const rbtree = tree.RedBlack(NodeValue, u32);
            const Tree = rbtree.Tree;
            const Node = rbtree.Node;

            fn init(self: *@This()) void {
                self.topTree.init(&self.nilNode);
            }

            fn deinit(self: *@This()) void {
                self.clear();

                while (self.tryToGetFreeNode()) |node| {
                    self.allocator.destroy(node);
                }
            }

            fn clear(self: *@This()) void {
                const PatriciaTree = @This();

                const NodeHandler = struct {
                    t: *PatriciaTree,

                    pub fn onNode(h: @This(), node: *Node) void {
                        //node.value = .{};
                        h.t.freeNode(node);
                    }
                };

                const handler = NodeHandler{ .t = self };
                self.topTree.traverseNodes(handler);
                self.topTree.reset();
            }

            fn tryToGetFreeNode(self: *@This()) ?*Node {
                if (self.freeNodeList) |node| {
                    if (node.value.deeperTree.count == 0) {
                        self.freeNodeList = null;
                    } else {
                        std.debug.assert(node.value.deeperTree.count == 1);
                        self.freeNodeList = node.value.deeperTree.root;
                        node.value.deeperTree.count = 0;
                    }
                    return node;
                }
                return null;
            }

            fn getFreeNode(self: *@This()) !*Node {
                const n = if (self.tryToGetFreeNode()) |node| node else try self.allocator.create(Node);

                n.* = .{
                    .value = .{},
                };
                n.value.init(&self.nilNode);

                //n.value.textSegment is undefined (deliborately).
                //std.debug.assert(n.value.textSegment.len == 0);
                std.debug.assert(n.value.deeperTree.count == 0);
                std.debug.assert(n.value.linkInfos.empty());

                return n;
            }

            fn freeNode(self: *@This(), node: *Node) void {
                //std.debug.assert(node.value.linkInfos.empty());

                node.value.textSegment.len = 0;
                if (self.freeNodeList) |old| {
                    node.value.deeperTree.root = old;
                    node.value.deeperTree.count = 1;
                } else {
                    node.value.deeperTree.count = 0;
                }
                self.freeNodeList = node;
            }

            //fn getFreeLinkInfoElement(self: *@This()) !*list.Element(*tmd.LinkInfo) {
            //    if (self.freeLinkInfoElement.pop()) |element| {
            //        return element;
            //    }
            //    return try self.allocator.create(list.Element(*tmd.LinkInfo));
            //}
            //
            //fn freeLinkInfoElement(self: *@This(), element: *list.Element(*tmd.LinkInfo)) void {
            //    self.freeLinkInfoElement.push(element);
            //}

            const NodeValue = struct {
                textSegment: TextType = undefined,
                linkInfos: list.List(*tmd.LinkInfo) = .{},
                deeperTree: Tree = .{},

                fn init(self: *@This(), nilNodePtr: *Node) void {
                    self.deeperTree.init(nilNodePtr);
                }

                // ToDo: For https://github.com/ziglang/zig/issues/18478,
                //       this must be marked as public.
                pub fn compare(x: @This(), y: @This()) isize {
                    if (x.textSegment.len == 0 and y.textSegment.len == 0) return 0;
                    if (x.textSegment.len == 0) return -1;
                    if (y.textSegment.len == 0) return 1;
                    return @as(isize, x.textSegment.get(0)) - @as(isize, y.textSegment.get(0));
                }

                fn commonPrefixLen(x: *const @This(), y: *const @This()) u32 {
                    const lx = x.textSegment.len;
                    const ly = y.textSegment.len;
                    const n = if (lx < ly) lx else ly;
                    for (0..n) |i| {
                        const k: u32 = @intCast(i);
                        if (x.textSegment.get(k) != y.textSegment.get(k)) {
                            return k;
                        }
                    }
                    return n;
                }
            };

            fn putLinkInfo(self: *@This(), text: TextType, linkInfoElement: *list.Element(*tmd.LinkInfo)) !void {
                var node = try self.getFreeNode();
                node.value.textSegment = text;

                var n = try self.putNodeIntoTree(&self.topTree, node);
                if (n != node) self.freeNode(node);

                // ToDo: also free text ... ?

                //var element = try self.getFreeLinkInfoElement();
                //element.value = linkInfo;
                n.value.linkInfos.push(linkInfoElement);
            }

            fn putNodeIntoTree(self: *@This(), theTree: *Tree, node: *Node) !*Node {
                const n = theTree.insert(node);
                //std.debug.print("   111, theTree.root.text={s}\n", .{theTree.root.value.textSegment.asString()});
                //std.debug.print("   111, n.value.textSegment={s}, {}\n", .{ n.value.textSegment.asString(), n.value.textSegment.len });
                //std.debug.print("   111, node.value.textSegment={s}, {}\n", .{ node.value.textSegment.asString(), node.value.textSegment.len });
                if (n == node) { // node is added successfully
                    return n;
                }

                // n is an old already existing node.

                const k = NodeValue.commonPrefixLen(&n.value, &node.value);
                std.debug.assert(k <= n.value.textSegment.len);
                std.debug.assert(k <= node.value.textSegment.len);

                //std.debug.print("   222 k={}\n", .{k});

                if (k == n.value.textSegment.len) {
                    //std.debug.print("   333 k={}\n", .{k});
                    if (k == node.value.textSegment.len) {
                        return n;
                    }

                    //std.debug.print("   444 k={}\n", .{k});
                    // k < node.value.textSegment.len

                    node.value.textSegment = node.value.textSegment.suffix(k);
                    return self.putNodeIntoTree(&n.value.deeperTree, node);
                }

                //std.debug.print("   555 k={}\n", .{k});
                // k < n.value.textSegment.len

                if (k == node.value.textSegment.len) {
                    //std.debug.print("   666 k={}\n", .{k});

                    n.fillNodeWithoutValue(node);

                    if (!theTree.checkNilNode(n.parent)) {
                        if (n == n.parent.left) n.parent.left = node else n.parent.right = node;
                    }
                    if (!theTree.checkNilNode(n.left)) n.left.parent = node;
                    if (!theTree.checkNilNode(n.right)) n.right.parent = node;
                    if (n == theTree.root) theTree.root = node;

                    n.value.textSegment = n.value.textSegment.suffix(k);
                    _ = try self.putNodeIntoTree(&node.value.deeperTree, n);
                    std.debug.assert(node.value.deeperTree.count == 1);

                    return node;
                }
                // k < node.value.textSegment.len

                var newNode = try self.getFreeNode();
                newNode.value.textSegment = node.value.textSegment.prefix(k);
                n.fillNodeWithoutValue(newNode);

                //std.debug.print("   777 k={}, newNode.text={s}\n", .{ k, newNode.value.textSegment.asString() });

                if (!theTree.checkNilNode(n.parent)) {
                    if (n == n.parent.left) n.parent.left = newNode else n.parent.right = newNode;
                }
                if (!theTree.checkNilNode(n.left)) n.left.parent = newNode;
                if (!theTree.checkNilNode(n.right)) n.right.parent = newNode;
                if (n == theTree.root) theTree.root = newNode;

                n.value.textSegment = n.value.textSegment.suffix(k);
                _ = try self.putNodeIntoTree(&newNode.value.deeperTree, n);

                //std.debug.print("   888 count={}\n", .{newNode.value.deeperTree.count});
                std.debug.assert(newNode.value.deeperTree.count == 1);
                defer std.debug.assert(newNode.value.deeperTree.count == 2);
                //defer std.debug.print("   999 count={}\n", .{newNode.value.deeperTree.count});

                node.value.textSegment = node.value.textSegment.suffix(k);
                return self.putNodeIntoTree(&newNode.value.deeperTree, node);
            }

            fn searchLinkInfo(self: *const @This(), text: TextType, prefixMatching: bool) ?*Node {
                var theText = text;
                var theTree = &self.topTree;
                while (true) {
                    //std.debug.print(" aaa, text={s}\n", .{theText.asString()});
                    //std.debug.print(" aaa 111, root={s}\n", .{theTree.root.value.textSegment.asString()});

                    const nodeValue = NodeValue{ .textSegment = theText };
                    if (theTree.search(nodeValue)) |n| {
                        const k = NodeValue.commonPrefixLen(&n.value, &nodeValue);
                        //std.debug.print("  bbb. {}, {}, {s}\n", .{ k, n.value.textSegment.len, n.value.textSegment.asString() });
                        if (n.value.textSegment.len < theText.len) {
                            //std.debug.print("    ccc 111\n", .{});
                            if (k < n.value.textSegment.len) break;
                            std.debug.assert(k == n.value.textSegment.len);
                            theTree = &n.value.deeperTree;
                            theText = theText.suffix(k);
                            //std.debug.print("    ccc 222, {}, k={}, text={s}\n", .{ theTree.count, k, theText.asString() });
                            //std.debug.print("    ccc 222, root={s}\n", .{theTree.root.value.textSegment.asString()});
                            continue;
                        } else {
                            //std.debug.print("    ddd 111\n", .{});
                            if (k < theText.len) break;
                            //std.debug.print("    ddd 222\n", .{});
                            std.debug.assert(k == theText.len);
                            if (prefixMatching) return n;
                            //std.debug.print("    ddd 333\n", .{});
                            if (n.value.textSegment.len == theText.len) return n;
                            //std.debug.print("    ddd 444\n", .{});
                            break;
                        }
                    } else break;
                }
                return null;
            }

            fn setUrlSourceForNode(node: *Node, urlSource: ?*tmd.TokenInfo, confirmed: bool) void {
                var le = node.value.linkInfos.head();
                while (le) |linkInfoElement| {
                    if (linkInfoElement.value.info != .urlSourceText) {
                        //std.debug.print("    333 aaa exact match, found and setSourceOfURL.\n", .{});
                        linkInfoElement.value.setSourceOfURL(urlSource, confirmed);
                    } else {
                        //std.debug.print("    333 aaa exact match, found but sourceURL has set.\n", .{});
                    }
                    le = linkInfoElement.next;
                }

                if (node.value.deeperTree.count == 0) {
                    // ToDo: delete the node (not necessary).
                }
            }

            fn setUrlSourceForTreeNodes(theTree: *Tree, urlSource: ?*tmd.TokenInfo, confirmed: bool) void {
                const NodeHandler = struct {
                    urlSource: ?*tmd.TokenInfo,
                    confirmed: bool,

                    pub fn onNode(h: @This(), node: *Node) void {
                        setUrlSourceForTreeNodes(&node.value.deeperTree, h.urlSource, h.confirmed);
                        setUrlSourceForNode(node, h.urlSource, h.confirmed);
                    }
                };

                const handler = NodeHandler{ .urlSource = urlSource, .confirmed = confirmed };
                theTree.traverseNodes(handler);
            }
        };
    }

    const Link = struct {
        linkInfoElementNormal: list.Element(*tmd.LinkInfo),
        linkInfoElementInverted: list.Element(*tmd.LinkInfo),
        revisedLinkText: RevisedLinkText,

        fn setInfoAndText(self: *@This(), linkInfo: *tmd.LinkInfo, text: RevisedLinkText) void {
            self.linkInfoElementNormal.value = linkInfo;
            self.linkInfoElementInverted.value = linkInfo;
            self.revisedLinkText = text;
        }

        fn info(self: *const @This()) *tmd.LinkInfo {
            std.debug.assert(self.linkInfoElementNormal.value == self.linkInfoElementInverted.value);
            return self.linkInfoElementNormal.value;
        }
    };

    fn destroyRevisedLinkText(link: *Link, a: mem.Allocator) void {
        a.free(link.revisedLinkText.asString());
    }

    const NormalPatricia = Patricia(RevisedLinkText);
    const InvertedPatricia = Patricia(InvertedRevisedLinkText);

    const Matcher = struct {
        normalPatricia: *NormalPatricia,
        invertedPatricia: *InvertedPatricia,

        fn doForLinkDefinition(self: @This(), linkDef: *Link) void {
            const linkInfo = linkDef.info();
            std.debug.assert(linkInfo.inDirective());

            const urlSource = linkInfo.info.urlSourceText.?;
            const confirmed = linkInfo.urlConfirmed();

            const linkText = linkDef.revisedLinkText.asString();

            //std.debug.print("    333 linkText = {s}\n", .{linkText});

            // ToDo: require that the ending "..." must be amtomic?
            const ddd = "...";
            if (mem.endsWith(u8, linkText, ddd)) {
                if (linkText.len == ddd.len) {
                    //std.debug.print("    333 all match.\n", .{});
                    // all match
                    NormalPatricia.setUrlSourceForTreeNodes(&self.normalPatricia.topTree, urlSource, confirmed);
                    //InvertedPatricia.setUrlSourceForTreeNodes(&self.invertedPatricia.topTree, urlSource, confirmed);

                    self.normalPatricia.clear();
                    self.invertedPatricia.clear();
                } else {
                    //std.debug.print("    333 leading match.\n", .{});
                    // leading match

                    const revisedLinkText = linkDef.revisedLinkText.prefix(linkDef.revisedLinkText.len - @as(u32, ddd.len));
                    if (self.normalPatricia.searchLinkInfo(revisedLinkText, true)) |node| {
                        NormalPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed);
                        NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    } else {
                        //std.debug.print("    333 leading match. Not found.\n", .{});
                    }
                }
            } else {
                if (mem.startsWith(u8, linkText, ddd)) {
                    //std.debug.print("    333 trailing match.\n", .{});
                    // trailing match

                    const revisedLinkText = linkDef.revisedLinkText.suffix(@intCast(ddd.len));
                    if (self.invertedPatricia.searchLinkInfo(revisedLinkText.invert(), true)) |node| {
                        InvertedPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed);
                        InvertedPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    } else {
                        //std.debug.print("    333 trailing match. Not found.\n", .{});
                    }
                } else {
                    //std.debug.print("    333 exact match.\n", .{});
                    // exact match

                    if (self.normalPatricia.searchLinkInfo(linkDef.revisedLinkText, false)) |node| {
                        //std.debug.print("    333 exact match, found.\n", .{});
                        NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    } else {
                        //std.debug.print("    333 exact match, not found.\n", .{});
                    }
                }
            }
        }
    };

    fn matchLinks(self: *ContentParser) !void {
        if (self.linkInfos) |infos| {
            var links: list.List(Link) = .{};
            defer destroyListElements(Link, links, destroyRevisedLinkText, self.allocator);
            // destroyRevisedLinkText should be called after destroying the following two trees.

            var normalPatricia = NormalPatricia{ .allocator = self.allocator };
            normalPatricia.init();
            defer normalPatricia.deinit();

            var invertedPatricia = InvertedPatricia{ .allocator = self.allocator };
            invertedPatricia.init();
            defer invertedPatricia.deinit();

            const matcher = Matcher{
                .normalPatricia = &normalPatricia,
                .invertedPatricia = &invertedPatricia,
            };

            // The top-to-bottom pass.
            var linkInfo: *tmd.LinkInfo = infos.first;
            while (true) {
                switch (linkInfo.info) {
                    .urlSourceText => unreachable,
                    .firstPlainText => |plainTextToken| blk: {
                        if (plainTextToken == null) {
                            //std.debug.print("ignored for no plainText tokens\n", .{});
                            linkInfo.setSourceOfURL(null, false);
                            break :blk;
                        }

                        var linkTextLen: u32 = 0;
                        var lastToken = plainTextToken.?;
                        while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                            defer lastToken = nextToken;
                            const str = self.tokenAsString(lastToken);
                            linkTextLen = copyLinkText(DummyLinkText{}, linkTextLen, str);
                        }

                        {
                            const str = self.tokenAsString(lastToken);
                            if (linkInfo.inDirective()) {
                                if (copyLinkText(DummyLinkText{}, 0, str) == 0) {
                                    //std.debug.print("ignored for blank link definition\n", .{});
                                    linkInfo.setSourceOfURL(null, false);
                                    break :blk;
                                }
                            } else if (url.isValidURL(trim_blanks(str))) {
                                // self-defined
                                //std.debug.print("self defined url: {s}\n", .{str});
                                linkInfo.setSourceOfURL(lastToken, true);
                                break :blk;
                            } else {
                                linkTextLen = copyLinkText(DummyLinkText{}, linkTextLen, str);
                            }

                            if (linkTextLen == 0) {
                                //std.debug.print("ignored for blank link text\n", .{});
                                linkInfo.setSourceOfURL(null, false);
                                break :blk;
                            }
                        }

                        const textPtr: [*]u8 = (try self.allocator.alloc(u8, linkTextLen)).ptr;
                        const revisedLinkText = RevisedLinkText{
                            .len = linkTextLen,
                            .text = textPtr,
                        };

                        const linkElement = try self.allocator.create(list.Element(Link));
                        links.push(linkElement);
                        linkElement.value.setInfoAndText(linkInfo, revisedLinkText);
                        const link = &linkElement.value;

                        const confirmed = while (true) {
                            const realLinkText = RealLinkText{
                                .text = textPtr,
                            };

                            var linkTextLen2: u32 = 0;
                            lastToken = plainTextToken.?;
                            while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                                defer lastToken = nextToken;
                                const str = self.tokenAsString(lastToken);
                                linkTextLen2 = copyLinkText(realLinkText, linkTextLen2, str);
                            }

                            const str = trim_blanks(self.tokenAsString(lastToken));
                            if (linkInfo.inDirective()) {
                                std.debug.assert(linkTextLen2 == linkTextLen);

                                //std.debug.print("    222 linkText = {s}\n", .{revisedLinkText.asString()});
                            } else {
                                std.debug.assert(!url.isValidURL(str));
                                linkTextLen2 = copyLinkText(realLinkText, linkTextLen2, str);
                                std.debug.assert(linkTextLen2 == linkTextLen);

                                //std.debug.print("    111 linkText = {s}\n", .{revisedLinkText.asString()});

                                try normalPatricia.putLinkInfo(revisedLinkText, &link.linkInfoElementNormal);
                                try invertedPatricia.putLinkInfo(revisedLinkText.invert(), &link.linkInfoElementInverted);
                                break :blk;
                            }

                            //std.debug.print("==== /{s}/, {}\n", .{ str, url.isValidURL(str) });

                            break url.isValidURL(str);
                        };

                        std.debug.assert(linkInfo.inDirective());
                        linkInfo.setSourceOfURL(lastToken, confirmed);

                        matcher.doForLinkDefinition(link);
                    },
                }

                if (linkInfo.next) |next| {
                    linkInfo = next;
                } else {
                    std.debug.assert(linkInfo == infos.last);
                    break;
                }
            }

            // The bottom-to-top pass.
            if (true) {
                normalPatricia.clear();
                invertedPatricia.clear();

                var element = links.tail();
                while (element) |linkElement| {
                    const link = &linkElement.value;
                    const theLinkInfo = link.info();
                    if (theLinkInfo.inDirective()) {
                        std.debug.assert(theLinkInfo.info == .urlSourceText);
                        matcher.doForLinkDefinition(link);
                    } else if (theLinkInfo.info != .urlSourceText) {
                        try normalPatricia.putLinkInfo(link.revisedLinkText, &link.linkInfoElementNormal);
                        try invertedPatricia.putLinkInfo(link.revisedLinkText.invert(), &link.linkInfoElementInverted);
                    }
                    element = linkElement.prev;
                }
            }

            // The final pass.
            {
                var element = links.head();
                while (element) |linkElement| {
                    const theLinkInfo = linkElement.value.info();
                    if (theLinkInfo.info != .urlSourceText) {
                        theLinkInfo.setSourceOfURL(theLinkInfo.info.firstPlainText, false);
                    }
                    element = linkElement.next;
                }
            }
        }
    }
};

const LineScanner = struct {
    data: []const u8,
    cursor: u32 = 0,
    cursorLineIndex: u32 = 0, // for debug

    // When lineEnd != null, cursor is the start of lineEnd.
    // That means, for a .rn line end, cursor is the index of '\r'.
    lineEnd: ?tmd.LineEndType = null,

    const spacesTable = blk: {
        var table = [1]bool{false} ** 256;
        table[' '] = true;
        table['\t'] = true;
        break :blk table;
    };

    const blanksTable = blk: {
        var table = [1]bool{false} ** 256;
        table[127] = true;
        for (0..33) |i| {
            if (i != '\n') table[i] = true;
        }
        break :blk table;
    };

    const leadingMarksTable = blk: {
        var table = [1]?tmd.LineSpanMarkType{null} ** 256;
        table['\\'] = .lineBreak;
        table['/'] = .comment;
        table['@'] = .media;
        table['='] = .anchor;
        break :blk table;
    };

    const spanMarksTable = struct {
        fn run() [256]?struct { markType: tmd.SpanMarkType, precedence: u3, minLen: u5 } {
            var table: @TypeOf(run()) = .{null} ** 256;
            table['*'] = .{ .markType = .fontWeight, .precedence = 1, .minLen = 2 };
            table['%'] = .{ .markType = .fontStyle, .precedence = 1, .minLen = 2 };
            table[':'] = .{ .markType = .fontSize, .precedence = 1, .minLen = 2 };
            table['?'] = .{ .markType = .spoiler, .precedence = 1, .minLen = 2 };
            table['~'] = .{ .markType = .deleted, .precedence = 1, .minLen = 2 };
            table['|'] = .{ .markType = .marked, .precedence = 1, .minLen = 2 };
            table['_'] = .{ .markType = .link, .precedence = 1, .minLen = 2 };
            table['$'] = .{ .markType = .supsub, .precedence = 1, .minLen = 2 };
            table['`'] = .{ .markType = .code, .precedence = 2, .minLen = 1 };
            table['!'] = .{ .markType = .escaped, .precedence = 3, .minLen = 2 };
            return table;
        }
    }.run();

    //for ("0123456789-abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ") |c| {
    //    table[c] |= char_attr_idchar;
    //}

    fn debugPrint(ls: *LineScanner, opName: []const u8, customValue: u32) void {
        std.debug.print("------- {s}, {}, {}\n", .{ opName, ls.cursorLineIndex, ls.cursor });
        std.debug.print("custom:  {}\n", .{customValue});
        if (ls.lineEnd) |end|
            std.debug.print("line end:    {s}\n", .{end.typeName()})
        else
            std.debug.print("cursor byte: {}\n", .{ls.peekCursor()});
    }

    fn proceedToNextLine(ls: *LineScanner) bool {
        defer ls.cursorLineIndex += 1;

        if (ls.cursorLineIndex == 0) {
            std.debug.assert(ls.lineEnd == null);
            return ls.cursor < ls.data.len;
        }

        if (ls.lineEnd) |lineEnd| {
            switch (lineEnd) {
                .void => return false,
                else => ls.cursor += lineEnd.len(),
            }
        } else unreachable;

        ls.lineEnd = null;
        return true;
    }

    fn advance(ls: *LineScanner, n: u32) void {
        std.debug.assert(ls.lineEnd == null);
        std.debug.assert(ls.cursor + n <= ls.data.len);
        ls.cursor += n;
    }

    // for retreat
    fn setCursor(ls: *LineScanner, cursor: u32) void {
        ls.cursor = cursor;
        ls.lineEnd = null;
    }

    fn peekCursor(ls: *LineScanner) u8 {
        std.debug.assert(ls.lineEnd == null);
        std.debug.assert(ls.cursor < ls.data.len);
        const c = ls.data[ls.cursor];
        std.debug.assert(c != '\n');
        return c;
    }

    fn peekNext(ls: *LineScanner) ?u8 {
        const k = ls.cursor + 1;
        if (k < ls.data.len) return ls.data[k];
        return null;
    }

    // ToDo: return the blankStart instead?
    // Returns count of trailing blanks.
    fn readUntilLineEnd(ls: *LineScanner) u32 {
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
            } else if (!blanksTable[c]) {
                blankStart = index + 1;
            }
        } else ls.lineEnd = .void;

        ls.cursor = index;
        return index - blankStart;
    }

    // ToDo: return the blankStart instead?
    // Returns count of trailing blanks.
    fn readUntilSpanMarkChar(ls: *LineScanner, precedence: u3) u32 {
        std.debug.assert(ls.lineEnd == null);

        const data = ls.data;
        var index = ls.cursor;
        var blankStart = index;
        while (index < data.len) : (index += 1) {
            const c = data[index];
            if (spanMarksTable[c]) |m| {
                if (m.precedence >= precedence) {
                    break;
                }
                blankStart = index + 1;
            } else if (blanksTable[c]) {
                continue;
            } else if (c == '\n') {
                if (index > 0 and data[index - 1] == '\r') {
                    ls.lineEnd = .rn;
                    index = index - 1;
                } else ls.lineEnd = .n;
                break;
            } else {
                blankStart = index + 1;
            }
        } else ls.lineEnd = .void;

        ls.cursor = index;
        return index - blankStart;
    }

    // ToDo: maybe it is better to change to readUntilNotSpaces,
    //       without considering invisible blanks.
    //       Just treat invisible blanks as visible non-space chars.
    // Returns count of spaces.
    fn readUntilNotBlank(ls: *LineScanner) u32 {
        std.debug.assert(ls.lineEnd == null);

        const data = ls.data;
        var index = ls.cursor;
        var numSpaces: u32 = 0;
        while (index < data.len) : (index += 1) {
            const c = data[index];
            if (blanksTable[c]) {
                if (spacesTable[c]) numSpaces += 1;
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
    fn readUntilNotChar(ls: *LineScanner, char: u8) u32 {
        std.debug.assert(ls.lineEnd == null);
        std.debug.assert(!blanksTable[char]);
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
    fn readUntilCondition(ls: *LineScanner, comptime condition: fn (u8) bool) u32 {
        const data = ls.data;
        var index = ls.cursor;
        while (index < data.len) : (index += 1) {
            const c = data[index];
            if (condition(c)) {
                if (c == '\n') {
                    if (index > 0 and data[index - 1] == '\r') {
                        ls.lineEnd = .rn;
                        index = index - 1;
                    } else ls.lineEnd = .n;
                }

                break;
            }
        } else ls.lineEnd = .void;

        const skipped = index - ls.cursor;
        ls.cursor = index;
        return skipped;
    }
};

const DocParser = struct {
    tmdDoc: *tmd.Doc,

    nextBlockAttributes: ?tmd.BlockAttibutes = null,

    fn createAndPushBlockInfoElement(parser: *DocParser, allocator: mem.Allocator) !*tmd.BlockInfo {
        var blockInfoElement = try createListElement(tmd.BlockInfo, allocator);
        parser.tmdDoc.blocks.push(blockInfoElement);

        if (parser.nextBlockAttributes) |as| {
            var blockAttributesElement = try createListElement(tmd.BlockAttibutes, allocator);
            parser.tmdDoc.blockAttributes.push(blockAttributesElement);

            const attrs = &blockAttributesElement.value;
            attrs.* = as;
            blockInfoElement.value.attributes = attrs;

            parser.nextBlockAttributes = null;
        } else {
            blockInfoElement.value.attributes = null; // !important
        }

        return &blockInfoElement.value;
    }

    fn onNewDirectiveLine(parser: *DocParser, lineInfo: *const tmd.LineInfo) !void {
        std.debug.assert(lineInfo.lineType == .directive);
        const tokens = lineInfo.lineType.directive.tokens;
        const headElement = tokens.head() orelse return;
        if (headElement.value.tokenType != .leadingMark) return;
        const leadingMark = &headElement.value.tokenType.leadingMark;
        if (leadingMark.markType != .anchor) return;
        const commentElement = headElement.next orelse return;
        const commentToken = &commentElement.value;

        const anchorInfo = parser.tmdDoc.data[commentToken.start()..commentToken.end()];
        const id = parse_anchor_id(anchorInfo);
        if (id.len > 0) {
            if (parser.nextBlockAttributes) |*as| {
                //if (as.id.len == 0)
                as.id = id;
            } else {
                parser.nextBlockAttributes = .{ .id = id };
            }
        }
    }

    // atomBlockInfo is an atom block, or a base/root block.
    fn setEndLineForAtomBlock(parser: *DocParser, atomBlockInfo: *tmd.BlockInfo) void {
        if (parser.tmdDoc.lines.tail()) |lastLineInfoElement| {
            std.debug.assert(!parser.tmdDoc.blocks.empty());
            std.debug.assert(atomBlockInfo.blockType != .root);
            if (atomBlockInfo.blockType != .base) {
                atomBlockInfo.setEndLine(&lastLineInfoElement.value);
            }
        } else std.debug.assert(atomBlockInfo.blockType == .root);
    }

    fn parseAll(parser: *DocParser, tmdData: []const u8, allocator: mem.Allocator) !void {
        const rootBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
        var blockArranger = BlockArranger.start(rootBlockInfo);
        defer blockArranger.end();

        var lineScanner = LineScanner{ .data = tmdData };
        // ToDo: lineScanner should be a property of ContentParser.

        var contentParser = ContentParser.make(allocator, &lineScanner);
        contentParser.init();
        defer contentParser.deinit(); // ToDo: needed?

        var codeSnippetStartInfo: ?*std.meta.FieldType(tmd.LineType, .codeSnippetStart) = null;

        // An atom block, or a base/root block.
        var currentAtomBlockInfo = rootBlockInfo;
        var atomBlockCount: u32 = 0;

        while (lineScanner.proceedToNextLine()) {
            var lineInfoElement = try createListElement(tmd.LineInfo, allocator);
            var lineInfo = &lineInfoElement.value;
            lineInfo.range.start = lineScanner.cursor;
            // ToDo: remove this line.
            //lineInfo.tokens = .{}; // !! Must be initialized. Otherwise undefined behavior.

            //std.debug.print("--- line#{}\n", .{lineScanner.cursorLineIndex});

            lineInfo.lineType = .{ .blank = .{} }; // will be change below

            parse_line: {
                _ = lineScanner.readUntilNotBlank();
                const leadingBlankEnd = lineScanner.cursor;

                // handle code block context.
                if (codeSnippetStartInfo) |codeSnippetStart| {
                    if (lineScanner.lineEnd) |_| {} else if (lineScanner.peekCursor() != '\'') {
                        _ = lineScanner.readUntilLineEnd();
                    } else handle: {
                        defer if (lineInfo.lineType != .codeSnippetEnd) {
                            if (lineScanner.lineEnd == null)
                                _ = lineScanner.readUntilLineEnd();
                        };

                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar('\'') + 1;
                        if (markLen < 3) break :handle;

                        //const codeSnippetStartLineType: *tmd.LineType = @alignCast(@fieldParentPtr("codeSnippetStart", codeSnippetStart));
                        //const codeSnippetStartLineInfo: *tmd.LineInfo = @alignCast(@fieldParentPtr("lineType", codeSnippetStartLineType));
                        //std.debug.print("=== {}, {}, {s}\n", .{codeSnippetStart.markLen, markLen, tmdData[lineInfo.rangeTrimmed.start..lineInfo.rangeTrimmed.end]});

                        if (markLen != codeSnippetStart.markLen) break :handle;

                        lineInfo.rangeTrimmed.start = leadingBlankEnd;

                        var playloadStart = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = playloadStart;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = playloadStart;
                            } else {
                                playloadStart = lineScanner.cursor;
                                const numTrailingBlanks = lineScanner.readUntilLineEnd();
                                lineInfo.rangeTrimmed.end = lineScanner.cursor - numTrailingBlanks;
                            }
                        }

                        lineInfo.lineType = .{ .codeSnippetEnd = .{
                            .markLen = markLen,
                            .markEndWithSpaces = playloadStart,
                        } };

                        codeSnippetStartInfo = null;
                    }

                    if (lineInfo.lineType == .blank) {
                        std.debug.assert(lineScanner.lineEnd != null);

                        lineInfo.lineType = .{ .code = .{} };
                        lineInfo.rangeTrimmed.start = lineInfo.range.start;
                        lineInfo.rangeTrimmed.end = lineScanner.cursor;
                    } else std.debug.assert(lineInfo.lineType == .codeSnippetEnd);

                    break :parse_line;
                } // code block context

                lineInfo.rangeTrimmed.start = leadingBlankEnd;

                // handle blank line.
                if (lineScanner.lineEnd) |_| {
                    lineInfo.lineType = .{ .blank = .{} };
                    lineInfo.rangeTrimmed.end = leadingBlankEnd;

                    if (currentAtomBlockInfo.blockType != .blank) {
                        const blankBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        blankBlockInfo.blockType = .{
                            .blank = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(blankBlockInfo, false);

                        parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = blankBlockInfo;
                        atomBlockCount += 1;
                    }

                    break :parse_line;
                }

                var isContainerFirstLine: bool = false;
                var contentStart: u32 = lineScanner.cursor;
                var noAtomBlockMarkForSure = false;

                // try to parse leading container mark.
                switch (lineScanner.peekCursor()) {
                    '*', '+', '-', '~' => |mark| handle: {
                        var lastMark = mark;
                        if (lineScanner.peekNext() == '.') {
                            lineScanner.advance(1);
                            lastMark = '.';
                        }
                        lineScanner.advance(1);
                        const markEnd = lineScanner.cursor;
                        const numSpaces = lineScanner.readUntilNotBlank();
                        if (numSpaces == 0 and lineScanner.lineEnd == null) { // not list item
                            // Is "**" (etc) or ".." possible?
                            if (lineScanner.cursor == markEnd and lineScanner.peekCursor() == lastMark) {
                                lineScanner.setCursor(markEnd - 1);
                            }
                            noAtomBlockMarkForSure = true;
                            lineInfo.containerMark = null;
                            break :handle;
                        }

                        isContainerFirstLine = true;
                        contentStart = lineScanner.cursor;

                        const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                            lineInfo.rangeTrimmed.end = markEnd;
                            lineInfo.containerMark = null;
                            break :blk markEnd;
                        } else lineScanner.cursor;

                        lineInfo.containerMark = .{ .list_item = .{
                            .markEnd = markEnd,
                            .markEndWithSpaces = markEndWithSpaces,
                        } };

                        const listItemBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        listItemBlockInfo.blockType = .{
                            .list_item = .{
                                .isFirst = false, // will be modified eventually
                                .isLast = false, // will be modified eventually
                                ._markTypeIndex = tmd.listBulletIndex(tmdData[leadingBlankEnd..markEnd]),
                            },
                        };
                        try blockArranger.stackListItemBlock(listItemBlockInfo);
                    },
                    ':', '>', '!', '?', '.' => |mark| handle: {
                        lineScanner.advance(1);
                        const markEnd = lineScanner.cursor;
                        const numSpaces = lineScanner.readUntilNotBlank();
                        if (numSpaces == 0 and lineScanner.lineEnd == null) { // not container
                            // Is "??" (etc) possible?
                            if (lineScanner.cursor == markEnd and lineScanner.peekCursor() == mark) {
                                lineScanner.setCursor(markEnd - 1);
                            }
                            noAtomBlockMarkForSure = true;
                            lineInfo.containerMark = null;
                            break :handle;
                        }

                        isContainerFirstLine = true;
                        contentStart = lineScanner.cursor;

                        const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                            lineInfo.rangeTrimmed.end = markEnd;
                            lineInfo.containerMark = null;
                            break :blk markEnd;
                        } else lineScanner.cursor;

                        const containerBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        switch (mark) {
                            ':' => {
                                lineInfo.containerMark = .{ .indented = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .indented = .{},
                                };
                            },
                            '>' => {
                                lineInfo.containerMark = .{ .block_quote = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .block_quote = .{},
                                };
                            },
                            '!' => {
                                lineInfo.containerMark = .{ .note_box = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .note_box = .{},
                                };
                            },
                            '?' => {
                                lineInfo.containerMark = .{ .disclosure_box = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .disclosure_box = .{},
                                };
                            },
                            '.' => {
                                lineInfo.containerMark = .{ .unstyled_box = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .unstyled_box = .{},
                                };
                            },
                            else => unreachable,
                        }
                        try blockArranger.stackContainerBlock(containerBlockInfo);
                    },
                    else => {
                        lineInfo.containerMark = null;
                    },
                }

                // try to parse atom block mark.
                if (noAtomBlockMarkForSure or lineScanner.lineEnd != null) {
                    // contentStart keeps unchanged.
                } else switch (lineScanner.peekCursor()) { // try to parse atom block mark
                    '{', '}' => |mark| handle: {
                        const isOpenMark = mark == '{';
                        if (isOpenMark) {
                            if (!blockArranger.canOpenBaseBlock()) break :handle;
                        } else {
                            if (!blockArranger.canCloseBaseBlock()) break :handle;
                        }

                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(mark) + 1;

                        var playloadStart = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = playloadStart;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = playloadStart;
                            } else {
                                playloadStart = lineScanner.cursor;
                                const numTrailingBlanks = lineScanner.readUntilLineEnd();
                                lineInfo.rangeTrimmed.end = lineScanner.cursor - numTrailingBlanks;
                            }
                        }

                        if (isOpenMark) {
                            lineInfo.lineType = .{ .baseBlockOpen = .{
                                .markLen = markLen,
                                .markEndWithSpaces = playloadStart,
                            } };

                            const baseBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                            baseBlockInfo.blockType = .{
                                .base = .{
                                    .openLine = lineInfo,
                                },
                            };
                            try blockArranger.openBaseBlock(baseBlockInfo, isContainerFirstLine);

                            parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = baseBlockInfo;
                            atomBlockCount += 1;
                        } else {
                            lineInfo.lineType = .{ .baseBlockClose = .{
                                .markLen = markLen,
                                .markEndWithSpaces = playloadStart,
                            } };

                            const baseBlockInfo = try blockArranger.closeCurrentBaseBlock();
                            baseBlockInfo.blockType.base.closeLine = lineInfo;

                            parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = baseBlockInfo;
                            atomBlockCount += 1;
                        }
                    },
                    '\'' => |mark| handle: {
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(mark) + 1;
                        if (markLen < 3) {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        var playloadStart = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = playloadStart;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = playloadStart;
                            } else {
                                playloadStart = lineScanner.cursor;
                                const numTrailingBlanks = lineScanner.readUntilLineEnd();
                                lineInfo.rangeTrimmed.end = lineScanner.cursor - numTrailingBlanks;
                            }
                        }

                        lineInfo.lineType = .{ .codeSnippetStart = .{
                            .markLen = markLen,
                            .markEndWithSpaces = playloadStart,
                        } };

                        codeSnippetStartInfo = &lineInfo.lineType.codeSnippetStart;

                        const codeSnippetBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        codeSnippetBlockInfo.* = .{ .blockType = .{
                            .code_snippet = .{
                                .startLine = lineInfo,
                            },
                        } };
                        try blockArranger.stackAtomBlock(codeSnippetBlockInfo, isContainerFirstLine);

                        parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = codeSnippetBlockInfo;
                        atomBlockCount += 1;
                    },
                    '#' => handle: {
                        // Must starts with 2 #.
                        if (lineScanner.peekNext() != '#') {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        lineScanner.advance(1);
                        const markLen = if (lineScanner.peekNext()) |c| blk: {
                            switch (c) {
                                '#', '=', '+', '-' => |mark| {
                                    lineScanner.advance(3);
                                    break :blk 3 + lineScanner.readUntilNotChar(mark);
                                },
                                else => break :blk 2,
                            }
                        } else 2;

                        if (markLen == 2) {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        const markEnd = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = markEnd;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = markEnd;
                            }
                        }

                        lineInfo.lineType = .{ .header = .{
                            .markLen = markLen,
                            .markEndWithSpaces = lineScanner.cursor,
                        } };

                        const headerBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        headerBlockInfo.blockType = .{
                            .header = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(headerBlockInfo, isContainerFirstLine);

                        parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = headerBlockInfo;
                        atomBlockCount += 1;

                        contentParser.on_new_atom_block();

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_line_tokens(lineInfo, lineScanner.cursor, false);
                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);
                    },
                    ';', '&' => |mark| handle: {
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(mark) + 1;
                        if (markLen < 3) {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        const markEnd = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = markEnd;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = markEnd;
                            }
                        }

                        const newAtomBlock = if (mark == ';') blk: {
                            lineInfo.lineType = .{ .usual = .{
                                .markLen = markLen,
                                .markEndWithSpaces = lineScanner.cursor,
                            } };

                            const usualBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                            usualBlockInfo.blockType = .{
                                .usual = .{
                                    .startLine = lineInfo,
                                },
                            };
                            break :blk usualBlockInfo;
                        } else blk: {
                            lineInfo.lineType = .{ .footer = .{
                                .markLen = markLen,
                                .markEndWithSpaces = lineScanner.cursor,
                            } };

                            const footerBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                            footerBlockInfo.blockType = .{
                                .footer = .{
                                    .startLine = lineInfo,
                                },
                            };
                            break :blk footerBlockInfo;
                        };

                        try blockArranger.stackAtomBlock(newAtomBlock, isContainerFirstLine);

                        parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = newAtomBlock;
                        atomBlockCount += 1;

                        contentParser.on_new_atom_block();

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_line_tokens(lineInfo, lineScanner.cursor, true);
                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);
                    },
                    '/' => |mark| handle: {
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(mark) + 1;
                        if (markLen < 3) {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        var playloadStart = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = playloadStart;
                        } else {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = playloadStart;
                            } else {
                                playloadStart = lineScanner.cursor;
                            }
                        }

                        lineInfo.lineType = .{ .directive = .{
                            .markLen = markLen,
                            .markEndWithSpaces = playloadStart,
                        } };

                        if (isContainerFirstLine or currentAtomBlockInfo.blockType != .directive) {
                            const commentBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                            commentBlockInfo.blockType = .{
                                .directive = .{
                                    .startLine = lineInfo,
                                },
                            };

                            try blockArranger.stackAtomBlock(commentBlockInfo, isContainerFirstLine);

                            parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = commentBlockInfo;
                            atomBlockCount += 1;

                            // No need to do this.
                            // contentParser.on_new_atom_block();
                        }

                        contentParser.on_new_atom_block();
                        defer contentParser.on_new_atom_block(); // ToDo: might be unnecessary

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_directive_line_tokens(lineInfo, lineScanner.cursor, markLen == 3);

                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);

                        try parser.onNewDirectiveLine(lineInfo);
                    },
                    else => {},
                }

                // If line type is still not determined, then it is just a usual line.
                if (lineInfo.lineType == .blank) {
                    lineInfo.lineType = .{ .usual = .{
                        .markLen = 0,
                        .markEndWithSpaces = lineScanner.cursor,
                    } };

                    if (isContainerFirstLine or
                        currentAtomBlockInfo.blockType != .usual and
                        currentAtomBlockInfo.blockType != .header and
                        currentAtomBlockInfo.blockType != .footer)
                    {
                        const usualBlockInfo = try parser.createAndPushBlockInfoElement(allocator);
                        usualBlockInfo.blockType = .{
                            .usual = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(usualBlockInfo, isContainerFirstLine);

                        parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = usualBlockInfo;
                        atomBlockCount += 1;

                        contentParser.on_new_atom_block();
                    }

                    if (lineScanner.lineEnd == null) {
                        const contentEnd = try contentParser.parse_line_tokens(
                            lineInfo,
                            contentStart,
                            currentAtomBlockInfo.blockType != .header and contentStart == lineScanner.cursor,
                        );
                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);
                    }
                }
            } // :parse_line

            if (lineScanner.lineEnd) |end| {
                lineInfo.endType = end;
                lineInfo.range.end = lineScanner.cursor;
            } else unreachable;

            lineInfo.atomBlockIndex = atomBlockCount;
            lineInfo.index = lineScanner.cursorLineIndex;

            parser.tmdDoc.lines.push(lineInfoElement);
        }

        // Meaningful only for code snippet block (and popential later custom app block).
        parser.setEndLineForAtomBlock(currentAtomBlockInfo);

        // ToDo: remove this line. (Forget the reason.;( )
        contentParser.on_new_atom_block(); // try to determine line-end render manner for the last coment line.

        try contentParser.matchLinks(); // ToDo: same effect when being put in the above else-block.
    }
};

pub fn dumpTmdDoc(tmdDoc: *const tmd.Doc) void {
    var blockElement = tmdDoc.blocks.head();
    while (blockElement) |be| {
        defer blockElement = be.next;
        const blockInfo = &be.value;
        {
            var depth = blockInfo.nestingDepth;
            while (depth > 0) : (depth -= 1) {
                std.debug.print("  ", .{});
            }
        }
        std.debug.print("+{}: {s}", .{ blockInfo.nestingDepth, blockInfo.typeName() });
        switch (blockInfo.blockType) {
            .list_item => |item| {
                if (item.isFirst and item.isLast) {
                    std.debug.print(" (first, last)", .{});
                } else if (item.isFirst) {
                    std.debug.print(" (first)", .{});
                } else if (item.isLast) {
                    std.debug.print(" (last)", .{});
                }
            },
            else => {},
        }
        std.debug.print("\n", .{});
        if (blockInfo.isAtom()) {
            var lineInfo = blockInfo.getStartLine();
            const end = blockInfo.getEndLine();
            while (true) {
                var depth = blockInfo.nestingDepth + 1;
                while (depth > 0) : (depth -= 1) {
                    std.debug.print("  ", .{});
                }
                std.debug.print("- L{} @{}: <{s}> ({}..{}) ({}..{}) ({}..{}) <{s}> {}\n", .{
                    lineInfo.number(),
                    lineInfo.atomBlockIndex,
                    lineInfo.typeName(),
                    lineInfo.rangeTrimmed.start - lineInfo.range.start + 1,
                    lineInfo.rangeTrimmed.end - lineInfo.range.start + 1,
                    lineInfo.rangeTrimmed.start,
                    lineInfo.rangeTrimmed.end,
                    lineInfo.range.start,
                    lineInfo.range.end,
                    lineInfo.endTypeName(),
                    lineInfo.treatEndAsSpace,
                });

                if (lineInfo.tokens()) |tokens| {
                    var tokenInfoElement = tokens.head();
                    //if (true) tokenInfoElement = null; // debug switch
                    while (tokenInfoElement) |element| {
                        depth = blockInfo.nestingDepth + 2;
                        while (depth > 0) : (depth -= 1) {
                            std.debug.print("  ", .{});
                        }

                        const tokenInfo = &element.value;
                        //defer std.debug.print("==== tokenInfo.end(): {}, tokenInfo.end2(lineInfo): {}\n", .{tokenInfo.end(), tokenInfo.end2(lineInfo)});
                        std.debug.assert(tokenInfo.end() == tokenInfo.end2(lineInfo));

                        switch (tokenInfo.tokenType) {
                            .commentText => {
                                std.debug.print("|{}-{}: [{s}]", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    tokenInfo.typeName(),
                                });
                            },
                            .plainText => {
                                std.debug.print("|{}-{}: [{s}]", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    tokenInfo.typeName(),
                                });
                            },
                            .leadingMark => |m| {
                                std.debug.print("|{}-{}: {s}:{s}", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    tokenInfo.typeName(),
                                    m.typeName(),
                                });
                            },
                            .spanMark => |m| {
                                var open: []const u8 = "<";
                                var close: []const u8 = ">";
                                if (m.open) close = "" else open = " ";
                                var secondary: []const u8 = "";
                                if (m.secondary) secondary = "^";
                                std.debug.print("|{}-{}: {s}{s}{s}:{s}{s}", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    secondary,
                                    open,
                                    tokenInfo.typeName(),
                                    m.typeName(),
                                    close,
                                });
                            },
                            .evenBackticks => |s| {
                                var secondary: []const u8 = "";
                                if (s.secondary) secondary = "^";
                                std.debug.print("|{}-{}: {s}<{s}>", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    secondary,
                                    tokenInfo.typeName(),
                                });
                            },
                            .linkInfo => {
                                std.debug.print("|{}-{}: __{s}", .{
                                    tokenInfo.start() - lineInfo.range.start + 1,
                                    tokenInfo.end() - lineInfo.range.start + 1,
                                    tokenInfo.typeName(),
                                });
                            },
                        }

                        std.debug.print("\n", .{});

                        tokenInfoElement = element.next;
                    }
                }

                if (lineInfo == end) {
                    break;
                }

                const lineElement: *list.Element(tmd.LineInfo) = @alignCast(@fieldParentPtr("value", lineInfo));
                if (lineElement.next) |le| {
                    lineInfo = &le.value;
                } else unreachable; // should always break from above
            }
        }
    }
}

pub fn parse_anchor_id(anchorInfo: []const u8) []const u8 {
    return anchorInfo; // ToDo: return the valid prefix
}

//pub fn parse_block_close_playload(playload: []const u8) ?tmd.BlockContentFlow {
//    return null;
//}

// ToDo: remove this function.
pub fn parse_base_block_open_playload(playload: []const u8) tmd.BaseBlockAttibutes {
    var attrs = tmd.BaseBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "commentedOut").?;
    //const horizontalAlign = std.meta.fieldIndex(tmd.BlockAttibutes, "horizontalAlign").?;
    //const id = std.meta.fieldIndex(tmd.BlockAttibutes, "id").?;
    //const classes = std.meta.fieldIndex(tmd.BlockAttibutes, "classes").?;

    const lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) handle: {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break :handle;
                    if (item.len == 1) break :handle;
                    for (item[1..]) |c| {
                        if (c != '/') break :handle;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                //'>', '<' => {
                //    if (lastOrder >= horizontalAlign) break :handle;
                //    if (item.len != 2) break :handle;
                //    if (item[1] != '>' and item[1] != '<') break :handle;
                //    if (mem.eql(u8, item, "<<"))
                //        attrs.horizontalAlign = .left
                //    else if (mem.eql(u8, item, ">>"))
                //        attrs.horizontalAlign = .right
                //    else if (mem.eql(u8, item, "><"))
                //        attrs.horizontalAlign = .center
                //    else if (mem.eql(u8, item, "<>"))
                //        attrs.horizontalAlign = .justify
                //    ;
                //    lastOrder = horizontalAlign;
                //},
                //'#' => {
                //    if (lastOrder >= id) break :handle;
                //    if (item.len == 1) break :handle;
                //    attrs.id = item[1..];
                //    lastOrder = id;
                //},
                //'.' => {
                //    if (lastOrder >= classes) break :handle;
                //    if (item.len == 1) break :handle;
                //    attrs.classes = item[1..];
                //    lastOrder = classes;
                //},
                else => {
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }
    return attrs;
}

pub fn parse_code_block_open_playload(playload: []const u8) tmd.CodeBlockAttibutes {
    var attrs = tmd.CodeBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "commentedOut").?;
    //const language = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "language").?;

    const lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) handle: {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break :handle;
                    if (item.len == 1) break :handle;
                    for (item[1..]) |c| {
                        if (c != '/') break :handle;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    if (item.len > 0) {
                        attrs.language = item;
                    }
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }
    return attrs;
}

pub fn trim_blanks(str: []const u8) []const u8 {
    var i: usize = 0;
    while (i < str.len and LineScanner.blanksTable[str[i]]) : (i += 1) {}
    const str2 = str[i..];
    i = str2.len;
    while (i > 0 and LineScanner.blanksTable[str[i - 1]]) : (i -= 1) {}
    return str2[0..i];
}

pub fn slice_to_first_space(str: []const u8) []const u8 {
    var i: usize = 0;
    while (i < str.len and LineScanner.spacesTable[str[i]]) : (i += 1) {}
    return str[0..i];
}

pub fn ends_with_blank(data: []const u8) bool {
    if (data.len == 0) return false;
    return LineScanner.blanksTable[data[data.len - 1]];
}
