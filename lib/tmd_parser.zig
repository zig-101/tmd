const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const utf8 = @import("utf8.zig");

pub fn destroy_tmd_doc(tmdDoc: *tmd.Doc, allocator: mem.Allocator) void {
    list.destroyListElements(tmd.BlockInfo, tmdDoc.blocks, null, allocator);

    const T = struct {
        fn destroyLineTokens(lineInfo: *tmd.LineInfo, a: mem.Allocator) void {
            if (lineInfo.tokens()) |tokens| {
                list.destroyListElements(tmd.TokenInfo, tokens.*, null, a);
            }
        }
    };

    list.destroyListElements(tmd.LineInfo, tmdDoc.lines, T.destroyLineTokens, allocator);

    list.destroyListElements(tmd.ElementAttibutes, tmdDoc.elementAttributes, null, allocator);
    list.destroyListElements(tmd.BaseBlockAttibutes, tmdDoc.baseBlockAttibutes, null, allocator);
    list.destroyListElements(tmd.CodeBlockAttibutes, tmdDoc.codeBlockAttibutes, null, allocator);
    list.destroyListElements(tmd.CustomBlockAttibutes, tmdDoc.customBlockAttibutes, null, allocator);
    list.destroyListElements(tmd.ContentStreamAttributes, tmdDoc.contentStreamAttributes, null, allocator);

    list.destroyListElements(tmd.BlockInfoRedBlack.Node, tmdDoc.blockTreeNodes, null, allocator);

    list.destroyListElements(tmd.Link, tmdDoc.links, null, allocator);
    list.destroyListElements(*tmd.BlockInfo, tmdDoc.tocHeaders, null, allocator);

    tmdDoc.* = .{ .data = "" };
}

pub fn parse_tmd_doc(tmdData: []const u8, allocator: mem.Allocator) !tmd.Doc {
    var tmdDoc = tmd.Doc{ .data = tmdData };
    errdefer destroy_tmd_doc(&tmdDoc, allocator);

    const nilBlockTreeNodeElement = try list.createListElement(tmd.BlockInfoRedBlack.Node, allocator);
    tmdDoc.blockTreeNodes.push(nilBlockTreeNodeElement);
    const nilBlockTreeNode = &nilBlockTreeNodeElement.value;
    nilBlockTreeNode.* = .{
        .color = .black,
        .value = undefined,
    };
    tmdDoc.blocksByID.init(nilBlockTreeNode);

    var docParser = DocParser{
        .allocator = allocator,
        .tmdDoc = &tmdDoc,
        .lineScanner = LineScanner{ .data = tmdDoc.data },
    };
    try docParser.parseAll(tmdData);

    if (false and builtin.mode == .Debug) {
        dumpTmdDoc(&tmdDoc);
    }

    return tmdDoc;
}

//===========================================

// BlockArranger determines block nesting depths.
const BlockArranger = struct {
    root: *tmd.BlockInfo,

    stackedBlocks: [tmd.MaxBlockNestingDepth]*tmd.BlockInfo = undefined,
    count_1: tmd.BlockNestingDepthType = 0,

    openingBaseBlocks: [tmd.MaxBlockNestingDepth]BaseContext = undefined,
    baseCount_1: tmd.BlockNestingDepthType = 0,

    const BaseContext = struct {
        nestingDepth: tmd.BlockNestingDepthType,
        commentedOut: bool,

        // !!! here, u6 must be larger than tmd.ListItemTypeIndex.
        openingListNestingDepths: [tmd.MaxListNestingDepthPerBase]u6 = [_]u6{0} ** tmd.MaxListNestingDepthPerBase,
        openingListCount: tmd.ListNestingDepthType = 0,
    };

    fn start(root: *tmd.BlockInfo, doc: *tmd.Doc) BlockArranger {
        root.* = .{ .nestingDepth = 0, .blockType = .{
            .root = .{ .doc = doc },
        } };

        var s = BlockArranger{
            .root = root,
            .count_1 = 1, // because of the fake first child
            .baseCount_1 = 0,
        };
        s.stackedBlocks[0] = root;
        s.openingBaseBlocks[0] = BaseContext{
            .nestingDepth = 0,
            .commentedOut = false,
        };
        s.stackedBlocks[s.count_1] = root; // fake first child (for implementation convenience)
        return s;
    }

    // This function should not be callsed deferredly.
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

    fn openBaseBlock(self: *BlockArranger, newBaseBlock: *tmd.BlockInfo, firstInContainer: bool, commentedOut: bool) !void {
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
                if (last.blockType == .base) {
                    @constCast(last).setNextSibling(newBaseBlock);
                }
                newBaseBlock.nestingDepth = self.count_1;
                self.stackedBlocks[self.count_1] = newBaseBlock;
            }
        }

        const newCommentedOut = commentedOut or self.openingBaseBlocks[self.baseCount_1].commentedOut;
        self.baseCount_1 += 1;
        self.openingBaseBlocks[self.baseCount_1] = BaseContext{
            .nestingDepth = self.count_1,
            .commentedOut = newCommentedOut,
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

        self.clearListContextInBase(false); // here, if the last is a blank, its nestingDepth will be adjusted.

        self.count_1 = baseContext.nestingDepth + 1;

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
        if (last.blockType != .root) last.setNextSibling(blockInfo);

        blockInfo.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = blockInfo;
    }

    fn shouldHeaderChildBeInTOC(self: *BlockArranger) bool {
        return self.stackedBlocks[self.count_1].nestingDepth - 1 == self.baseCount_1 and !self.openingBaseBlocks[self.baseCount_1].commentedOut;
    }

    fn stackContainerBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
        std.debug.assert(blockInfo.isContainer());
        std.debug.assert(blockInfo.blockType != .item);

        try self.stackAsChildOfBase(blockInfo);
    }

    fn assertBaseOpeningListCount(self: *BlockArranger) void {
        if (builtin.mode == .Debug) {
            var baseContext = &self.openingBaseBlocks[self.baseCount_1];

            var count: @TypeOf(baseContext.openingListCount) = 0;
            for (&baseContext.openingListNestingDepths) |d| {
                if (d != 0) count += 1;
            }
            //std.debug.print("==== {} : {}\n", .{ count, baseContext.openingListCount });
            std.debug.assert(count == baseContext.openingListCount);

            if (baseContext.openingListCount > 0) {
                //std.debug.print("assertBaseOpeningListCount {}, {} + {} + 1\n", .{ self.count_1, baseContext.nestingDepth, baseContext.openingListCount });

                std.debug.assert(self.count_1 == baseContext.nestingDepth + baseContext.openingListCount + 1);
            }
        }
    }

    // Returns whether or not a new list should be created.
    fn shouldCreateNewList(self: *BlockArranger, markTypeIndex: tmd.ListItemTypeIndex) bool {
        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);

        //return if (baseContext.openingListCount == 0) blk: {
        //    if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
        //        return error.NestingDepthTooLarge;
        //    }
        //    const last = self.stackedBlocks[self.count_1];
        //    self.count_1 = baseContext.nestingDepth + 1;
        //    if (last.blockType == .blank) {
        //        // Ensure the nestingDepth of the blank block.
        //        last.nestingDepth = self.count_1;
        //    }
        //
        //    break :blk true;
        //} else if (baseContext.openingListNestingDepths[markTypeIndex] != 0) blk: {
        //    //const last = self.stackedBlocks[self.count_1];
        //    //break :blk last.blockType == .attributes;
        //    break :blk false;
        //} else true;

        return baseContext.openingListCount == 0 or baseContext.openingListNestingDepths[markTypeIndex] == 0;
    }

    // listBlock != null means this is the first item in list.
    fn stackListItemBlock(self: *BlockArranger, listItemBlock: *tmd.BlockInfo, markTypeIndex: tmd.ListItemTypeIndex, listBlock: ?*tmd.BlockInfo) !void {
        std.debug.assert(listItemBlock.blockType == .item);

        self.assertBaseOpeningListCount();

        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);

        const newListItem = &listItemBlock.blockType.item;

        if (listBlock) |theListBlock| {
            std.debug.assert(theListBlock.blockType.list._itemTypeIndex == markTypeIndex);

            if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
                return error.NestingDepthTooLarge;
            }

            if (baseContext.openingListCount == 0) { // start list context
                const last = self.stackedBlocks[self.count_1];
                self.count_1 = baseContext.nestingDepth + 1;
                if (last.blockType == .blank) {
                    // Ensure the nestingDepth of the blank block.
                    last.nestingDepth = self.count_1;
                }
            } else std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] == 0);

            //if (baseContext.openingListNestingDepths[markTypeIndex] != 0) {
            //    // ToDo: now there are 3 alike such code pieces, unify them?
            //
            //    var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
            //    var depth = self.count_1 - 1;
            //    while (depth > baseContext.nestingDepth) : (depth -= 1) {
            //        std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
            //        std.debug.assert(self.stackedBlocks[depth].blockType == .item);
            //        var item = &self.stackedBlocks[depth].blockType.item;
            //
            //        //item.isLast = true;
            //        item.list.blockType.list.lastBullet = item.ownerBlockInfo();
            //        item.list.blockType.list._lastItemConfirmed = true;
            //        baseContext.openingListNestingDepths[item.list.blockType.list._itemTypeIndex] = 0;
            //        deltaCount += 1;
            //
            //        if (item.list.blockType.list._itemTypeIndex == markTypeIndex) {
            //            break;
            //        }
            //    }
            //
            //    baseContext.openingListCount -= deltaCount;
            //    self.count_1 = depth;
            //}

            //newListItem.isFirst = true;
            //newListItem.firstItem = listItemBlock;
            newListItem.list = theListBlock;

            theListBlock.nestingDepth = self.count_1; // the depth of the list is the same as its children

            listItemBlock.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = listItemBlock;

            baseContext.openingListNestingDepths[markTypeIndex] = self.count_1;
            baseContext.openingListCount += 1;
        } else {
            std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] != 0);

            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
            std.debug.assert(last.blockType != .item);

            var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
            var depth = self.count_1 - 1;
            while (depth > baseContext.nestingDepth) : (depth -= 1) {
                std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
                std.debug.assert(self.stackedBlocks[depth].blockType == .item);
                var itemBlock = self.stackedBlocks[depth];
                var item = &itemBlock.blockType.item;
                if (item.list.blockType.list._itemTypeIndex == markTypeIndex) {
                    //newListItem.firstItem = item.firstItem;
                    itemBlock.setNextSibling(listItemBlock);
                    newListItem.list = item.list;
                    break;
                }
                //item.isLast = true;
                item.list.blockType.list.lastBullet = item.ownerBlockInfo();
                item.list.blockType.list._lastItemConfirmed = true;
                baseContext.openingListNestingDepths[item.list.blockType.list._itemTypeIndex] = 0;
                deltaCount += 1;
            }

            std.debug.assert(depth > baseContext.nestingDepth);
            std.debug.assert(baseContext.openingListCount > deltaCount);

            if (deltaCount > 0) {
                baseContext.openingListCount -= deltaCount;

                if (last.blockType == .blank) {
                    // Ensure the nestingDepth of the blank block.
                    last.nestingDepth = depth + 1;

                    const lastBulletOfDeeperList = self.stackedBlocks[last.nestingDepth];
                    lastBulletOfDeeperList.setNextSibling(last);
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
        _ = forClosingBase; // ToDo: the logic will be a bit simpler but might be unnecessary.

        const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        std.debug.assert(self.count_1 > baseContext.nestingDepth);
        std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].blockType == .base or self.stackedBlocks[baseContext.nestingDepth].blockType == .root);

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
        std.debug.assert(last.blockType != .item);
        defer {
            self.count_1 = baseContext.nestingDepth + 1;
            if (last.blockType == .blank and last.nestingDepth != self.count_1) {
                // prevOfLast might be the last item in a just closed list.
                const prevOfLast = self.stackedBlocks[self.count_1];
                std.debug.assert(prevOfLast.blockType == .root or prevOfLast.nestingDepth == self.count_1);
                if (prevOfLast.blockType != .root) prevOfLast.setNextSibling(last);

                // Ensure the nestingDepth of the blank block.
                last.nestingDepth = self.count_1;
                self.stackedBlocks[self.count_1] = last;
            }
        }

        if (baseContext.openingListCount == 0) {
            return;
        }

        self.assertBaseOpeningListCount();

        {
            var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
            var depth = self.count_1 - 1;
            while (depth > baseContext.nestingDepth) : (depth -= 1) {
                std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
                std.debug.assert(self.stackedBlocks[depth].blockType == .item);
                var item = &self.stackedBlocks[depth].blockType.item;
                //item.isLast = true;
                item.list.blockType.list.lastBullet = item.ownerBlockInfo();
                item.list.blockType.list._lastItemConfirmed = true;
                baseContext.openingListNestingDepths[item.list.blockType.list._itemTypeIndex] = 0;
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

        if (last.blockType == .base) {
            @constCast(last).setNextSibling(blockInfo);
        }

        blockInfo.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = blockInfo;
    }

    fn stackFirstLevelHeaderBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo, firstInContainer: bool) !void {
        if (firstInContainer) {
            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.isContainer());
            std.debug.assert(last.nestingDepth == self.count_1);
            switch (last.blockType) {
                .item => |listItem| {
                    // listItem.confirmTabItem();
                    //listItem.list.blockType.list.isTab = true;
                    if (listItem.list.blockType.list.listType == .bullets)
                        listItem.list.blockType.list.listType = .tabs;
                },
                else => {},
            }
        } else {
            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.nestingDepth == self.count_1 or last.blockType == .base or last.blockType == .root);
            std.debug.assert(!last.isContainer());
            if (last.blockType == .attributes) {
                const container = self.stackedBlocks[self.count_1 - 1];
                switch (container.blockType) {
                    .item => |listItem| {
                        // listItem.confirmTabItem();
                        //listItem.list.blockType.list.isTab = true;
                        if (listItem.list.blockType.list.listType == .bullets)
                            listItem.list.blockType.list.listType = .tabs;
                    },
                    else => {},
                }
            }
        }

        try self.stackAtomBlock(blockInfo, firstInContainer);
    }
};

const ContentParser = struct {
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

    fn make(docParser: *DocParser) ContentParser {
        std.debug.assert(MarkCount <= 32);

        return .{
            .docParser = docParser,
        };
    }

    fn deinit(_: *ContentParser) void {
        // ToDo: looks nothing needs to do here.

        // Note: here should only release resource (memory).
        //       If there are other jobs to do,
        //       they should be put in another function
        //       and that function should not be called deferredly.
    }

    fn init(self: *ContentParser) void {
        self.codeSpanStatus = self.span_status(.code);
        self.linkSpanStatus = self.span_status(.link);
    }

    fn isCommentLineParser(self: *const ContentParser) bool {
        return self == self.docParser.commentLineParser;
    }

    fn span_status(self: *ContentParser, markType: tmd.SpanMarkType) *SpanStatus {
        return &self.blockSession.spanStatuses[markType.asInt()];
    }

    fn on_new_atom_block(self: *ContentParser, atomBlock: *tmd.BlockInfo) void {
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

    fn parse_attributes_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32) !u32 {
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

    fn parse_usual_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32, handleLineSpanMark: bool) !u32 {
        self.set_currnet_line(lineInfo, lineStart);

        return try self.parse_line_tokens(handleLineSpanMark);
    }

    fn parse_header_line_tokens(self: *ContentParser, lineInfo: *tmd.LineInfo, lineStart: u32) !u32 {
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

            if (handleLineSpanMark) {
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
            }

            if (lineScanner.lineEnd != null) { // the line only contains one leading mark
                std.debug.assert(lineScanner.cursor > textStart);
                _ = try self.create_plain_text_token(textStart, lineScanner.cursor);
                break :parse_tokens lineScanner.cursor;
            }

            const codeMark = LineScanner.spanMarksTable['`'].?;
            const codeSpanStatus = self.codeSpanStatus;

            parse_span_marks: while (true) {
                std.debug.assert(lineScanner.lineEnd == null);

                const precedence = if (codeSpanStatus.openMark) |_| codeMark.precedence else 0;
                const numBlanks = lineScanner.readUntilSpanMarkChar(precedence);

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

    // Match link definitions.

    fn tokenAsString(self: *const ContentParser, plainTextTokenInfo: *const tmd.TokenInfo) []const u8 {
        return self.docParser.tmdDoc.data[plainTextTokenInfo.start()..plainTextTokenInfo.end()];
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

            const rbtree = tree.RedBlack(NodeValue, NodeValue);
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
                const n = self.tryToGetFreeNode() orelse try self.allocator.create(Node);

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

            fn setUrlSourceForNode(node: *Node, urlSource: ?*tmd.TokenInfo, confirmed: bool, attrs: ?*tmd.ElementAttibutes) void {
                var le = node.value.linkInfos.head();
                while (le) |linkInfoElement| {
                    if (linkInfoElement.value.info != .urlSourceText) {
                        //std.debug.print("    333 aaa exact match, found and setSourceOfURL.\n", .{});
                        linkInfoElement.value.setSourceOfURL(urlSource, confirmed);
                        linkInfoElement.value.attrs = attrs;
                    } else {
                        //std.debug.print("    333 aaa exact match, found but sourceURL has set.\n", .{});
                    }
                    le = linkInfoElement.next;
                }

                if (node.value.deeperTree.count == 0) {
                    // ToDo: delete the node (not necessary).
                }
            }

            fn setUrlSourceForTreeNodes(theTree: *Tree, urlSource: ?*tmd.TokenInfo, confirmed: bool, attrs: ?*tmd.ElementAttibutes) void {
                const NodeHandler = struct {
                    urlSource: ?*tmd.TokenInfo,
                    confirmed: bool,
                    attrs: ?*tmd.ElementAttibutes,

                    pub fn onNode(h: @This(), node: *Node) void {
                        setUrlSourceForTreeNodes(&node.value.deeperTree, h.urlSource, h.confirmed, h.attrs);
                        setUrlSourceForNode(node, h.urlSource, h.confirmed, h.attrs);
                    }
                };

                const handler = NodeHandler{ .urlSource = urlSource, .confirmed = confirmed, .attrs = attrs };
                theTree.traverseNodes(handler);
            }
        };
    }

    const LinkForTree = struct {
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

    fn destroyRevisedLinkText(link: *LinkForTree, a: mem.Allocator) void {
        a.free(link.revisedLinkText.asString());
    }

    const NormalPatricia = Patricia(RevisedLinkText);
    const InvertedPatricia = Patricia(InvertedRevisedLinkText);

    const Matcher = struct {
        normalPatricia: *NormalPatricia,
        invertedPatricia: *InvertedPatricia,

        fn doForLinkDefinition(self: @This(), linkDef: *LinkForTree) void {
            const linkInfo = linkDef.info();
            std.debug.assert(linkInfo.inComment());

            const urlSource = linkInfo.info.urlSourceText.?;
            const confirmed = linkInfo.urlConfirmed();
            const attrs = linkInfo.attrs;

            const linkText = linkDef.revisedLinkText.asString();

            //std.debug.print("    333 linkText = {s}\n", .{linkText});

            // ToDo: require that the ending "..." must be amtomic?
            const ddd = "...";
            if (mem.endsWith(u8, linkText, ddd)) {
                if (linkText.len == ddd.len) {
                    //std.debug.print("    333 all match.\n", .{});
                    // all match

                    NormalPatricia.setUrlSourceForTreeNodes(&self.normalPatricia.topTree, urlSource, confirmed, attrs);
                    //InvertedPatricia.setUrlSourceForTreeNodes(&self.invertedPatricia.topTree, urlSource, confirmed, attrs);

                    self.normalPatricia.clear();
                    self.invertedPatricia.clear();
                } else {
                    //std.debug.print("    333 leading match.\n", .{});
                    // leading match

                    const revisedLinkText = linkDef.revisedLinkText.prefix(linkDef.revisedLinkText.len - @as(u32, ddd.len));
                    if (self.normalPatricia.searchLinkInfo(revisedLinkText, true)) |node| {
                        NormalPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed, attrs);
                        NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
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
                        InvertedPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed, attrs);
                        InvertedPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
                    } else {
                        //std.debug.print("    333 trailing match. Not found.\n", .{});
                    }
                } else {
                    //std.debug.print("    333 exact match.\n", .{});
                    // exact match

                    if (self.normalPatricia.searchLinkInfo(linkDef.revisedLinkText, false)) |node| {
                        //std.debug.print("    333 exact match, found.\n", .{});
                        NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
                    } else {
                        //std.debug.print("    333 exact match, not found.\n", .{});
                    }
                }
            }
        }
    };

    fn matchLinks(self: *ContentParser) !void {
        const links = &self.docParser.tmdDoc.links;
        if (links.empty()) return;

        var linksForTree: list.List(LinkForTree) = .{};
        defer list.destroyListElements(LinkForTree, linksForTree, destroyRevisedLinkText, self.docParser.allocator);

        var normalPatricia = NormalPatricia{ .allocator = self.docParser.allocator };
        normalPatricia.init();
        defer normalPatricia.deinit();

        var invertedPatricia = InvertedPatricia{ .allocator = self.docParser.allocator };
        invertedPatricia.init();
        defer invertedPatricia.deinit();

        const matcher = Matcher{
            .normalPatricia = &normalPatricia,
            .invertedPatricia = &invertedPatricia,
        };

        // The top-to-bottom pass.
        var linkElement = links.head().?;
        while (true) {
            const linkInfo = linkElement.value.info;
            switch (linkInfo.info) {
                .urlSourceText => unreachable,
                .firstPlainText => |plainTextToken| blk: {
                    const firstTextToken = if (plainTextToken) |first| first else {
                        // The link should be ignored in rendering.

                        //std.debug.print("ignored for no plainText tokens\n", .{});
                        linkInfo.setSourceOfURL(null, false);
                        break :blk;
                    };

                    var linkTextLen: u32 = 0;
                    var lastToken = firstTextToken;
                    // count sum length without the last text token
                    while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                        defer lastToken = nextToken;
                        const str = self.tokenAsString(lastToken);
                        linkTextLen = copyLinkText(DummyLinkText{}, linkTextLen, str);
                    }

                    // handle the last text token
                    {
                        const str = trim_blanks(self.tokenAsString(lastToken));
                        if (linkInfo.inComment()) {
                            if (copyLinkText(DummyLinkText{}, 0, str) == 0) {
                                // This link definition will be ignored.

                                //std.debug.print("ignored for blank link definition\n", .{});
                                linkInfo.setSourceOfURL(null, false);
                                break :blk;
                            }
                        } else if (isValidURL(str)) {
                            // For built-in cases, no need to call callback to determine the url.

                            //std.debug.print("self defined url: {s}\n", .{str});
                            linkInfo.setSourceOfURL(lastToken, true);

                            if (lastToken == firstTextToken and mem.startsWith(u8, str, "#")) {
                                linkInfo.setFootnote(true);
                            }

                            break :blk;
                        } else {
                            linkTextLen = copyLinkText(DummyLinkText{}, linkTextLen, str);
                        }

                        if (linkTextLen == 0) {
                            // The link should be ignored in rendering.

                            //std.debug.print("ignored for blank link text\n", .{});
                            linkInfo.setSourceOfURL(null, false);
                            break :blk;
                        }
                    }

                    // build RevisedLinkText

                    const textPtr: [*]u8 = (try self.docParser.allocator.alloc(u8, linkTextLen)).ptr;
                    const revisedLinkText = RevisedLinkText{
                        .len = linkTextLen,
                        .text = textPtr,
                    };

                    const theElement = try self.docParser.allocator.create(list.Element(LinkForTree));
                    linksForTree.push(theElement);
                    theElement.value.setInfoAndText(linkInfo, revisedLinkText);
                    const linkForTree = &theElement.value;

                    const confirmed = while (true) { // ToDo: use a labled non-loop block
                        const realLinkText = RealLinkText{
                            .text = textPtr, // == revisedLinkText.text,
                        };

                        var linkTextLen2: u32 = 0;
                        lastToken = firstTextToken;
                        // build text data without the last text token
                        while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                            defer lastToken = nextToken;
                            const str = self.tokenAsString(lastToken);
                            linkTextLen2 = copyLinkText(realLinkText, linkTextLen2, str);
                        }

                        // handle the last text token
                        const str = trim_blanks(self.tokenAsString(lastToken));
                        if (linkInfo.inComment()) {
                            std.debug.assert(linkTextLen2 == linkTextLen);

                            //std.debug.print("    222 linkText = {s}\n", .{revisedLinkText.asString()});

                            //std.debug.print("==== /{s}/, {}\n", .{ str, isValidURL(str) });

                            break isValidURL(str);
                        } else {
                            std.debug.assert(!isValidURL(str));

                            // For a link whose url is not built-in determined,
                            // all of its text tokens are used as link texts.

                            linkTextLen2 = copyLinkText(realLinkText, linkTextLen2, str);
                            std.debug.assert(linkTextLen2 == linkTextLen);

                            //std.debug.print("    111 linkText = {s}\n", .{revisedLinkText.asString()});

                            try normalPatricia.putLinkInfo(revisedLinkText, &linkForTree.linkInfoElementNormal);
                            try invertedPatricia.putLinkInfo(revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
                            break :blk;
                        }
                    };

                    std.debug.assert(linkInfo.inComment());

                    linkInfo.setSourceOfURL(lastToken, confirmed);
                    matcher.doForLinkDefinition(linkForTree);
                },
            }

            if (linkElement.next) |next| {
                linkElement = next;
            } else break;
        }

        // The bottom-to-top pass.
        {
            normalPatricia.clear();
            invertedPatricia.clear();

            var element = linksForTree.tail();
            while (element) |theElement| {
                const linkForTree = &theElement.value;
                const theLinkInfo = linkForTree.info();
                if (theLinkInfo.inComment()) {
                    std.debug.assert(theLinkInfo.info == .urlSourceText);
                    matcher.doForLinkDefinition(linkForTree);
                } else if (theLinkInfo.info != .urlSourceText) {
                    try normalPatricia.putLinkInfo(linkForTree.revisedLinkText, &linkForTree.linkInfoElementNormal);
                    try invertedPatricia.putLinkInfo(linkForTree.revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
                }
                element = theElement.prev;
            }
        }

        // The final pass (for still unmatched links).
        {
            var element = linksForTree.head();
            while (element) |theElement| {
                const theLinkInfo = theElement.value.info();
                if (theLinkInfo.info != .urlSourceText) {
                    theLinkInfo.setSourceOfURL(theLinkInfo.info.firstPlainText, false);
                }
                element = theElement.next;
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
        table['&'] = .media;
        table['!'] = .escape;
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
            //table['!'] = .{ .markType = .escaped, .precedence = 3, .minLen = 2 };
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
                else => {
                    ls.cursor += lineEnd.len();
                    std.debug.assert(ls.cursor <= ls.data.len);
                    if (ls.cursor >= ls.data.len) return false;
                },
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

    fn checkFollowing(ls: *LineScanner, prefix: []const u8) bool {
        const k = ls.cursor + 1;
        if (k >= ls.data.len) return false;
        return std.mem.startsWith(u8, ls.data[k..], prefix);
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
    allocator: mem.Allocator,

    tmdDoc: *tmd.Doc,
    numBlocks: u32 = 0,

    commentLineParser: *ContentParser = undefined,
    lineScanner: LineScanner,

    nextElementAttributes: ?tmd.ElementAttibutes = null,
    lastBlockInfo: *tmd.BlockInfo = undefined,

    pendingTocHeaderBlock: ?*tmd.BlockInfo = null,

    fn createAndPushBlockInfoElement(parser: *DocParser) !*tmd.BlockInfo {
        var blockInfoElement = try list.createListElement(tmd.BlockInfo, parser.allocator);
        parser.tmdDoc.blocks.push(blockInfoElement);
        const blockInfo = &blockInfoElement.value;
        blockInfo.attributes = null; // !important
        parser.numBlocks += 1;
        blockInfo.index = parser.numBlocks;

        parser.lastBlockInfo = blockInfo;

        return blockInfo;
    }

    fn tryToAttributeBlock(parser: *DocParser, oldLastBlockInfo: *tmd.BlockInfo) !void {
        // std.debug.assert(oldLastBlockInfo != parser.lastBlockInfo); // possible equal in the end

        if (oldLastBlockInfo.blockType != .attributes) {
            if (parser.nextElementAttributes) |as| {
                var block = oldLastBlockInfo;
                const attributesBlock = while (block.ownerListElement().prev) |prevElement| {
                    const prevBlock = &prevElement.value;
                    switch (prevBlock.blockType) {
                        .attributes => break prevBlock,
                        else => block = prevBlock,
                    }
                } else unreachable;

                std.debug.assert(block.blockType != .attributes);

                if (attributesBlock.getNextSibling() == block) {
                    try parser.setBlockAttributes(block, as);
                } else {
                    try parser.setBlockAttributes(attributesBlock, as); // a footer attributes
                }

                parser.nextElementAttributes = null;
            }
        }

        // oldLastBlockInfo.attributes = null; // moved to createAndPushBlockInfoElement
    }

    fn tryToAttributeTheLastBlock(parser: *DocParser) !void {
        std.debug.assert(parser.lastBlockInfo == &parser.tmdDoc.blocks.tail().?.value);
        switch (parser.lastBlockInfo.blockType) {
            .attributes => if (parser.nextElementAttributes) |as| {
                try parser.setBlockAttributes(parser.lastBlockInfo, as); // a footer attributes
            },
            else => try parser.tryToAttributeBlock(parser.lastBlockInfo),
        }
    }

    fn setBlockAttributes(parser: *DocParser, blockInfo: *tmd.BlockInfo, as: tmd.ElementAttibutes) !void {
        var blockAttributesElement = try list.createListElement(tmd.ElementAttibutes, parser.allocator);
        parser.tmdDoc.elementAttributes.push(blockAttributesElement);

        const attrs = &blockAttributesElement.value;
        attrs.* = as;

        blockInfo.attributes = attrs;

        if (attrs.id.len > 0) {
            const blockTreeNodeElement = if (parser.tmdDoc.freeBlockTreeNodeElement) |e| blk: {
                parser.tmdDoc.freeBlockTreeNodeElement = null;
                break :blk e;
            } else blk: {
                const element = try list.createListElement(tmd.BlockInfoRedBlack.Node, parser.allocator);
                parser.tmdDoc.blockTreeNodes.push(element);
                break :blk element;
            };

            const blockTreeNode = &blockTreeNodeElement.value;
            blockTreeNode.value = blockInfo;
            const n = parser.tmdDoc.blocksByID.insert(blockTreeNode);
            if (n != blockTreeNode) {
                parser.tmdDoc.freeBlockTreeNodeElement = blockTreeNodeElement;
            }
        }
    }

    //fn onNewAttributesLine(parser: *DocParser, lineInfo: *const tmd.LineInfo, forBulletContainer: bool) !void {
    fn onNewAttributesLine(parser: *DocParser, lineInfo: *const tmd.LineInfo) !void {
        std.debug.assert(lineInfo.lineType == .attributes);
        const tokens = lineInfo.lineType.attributes.tokens;
        const headElement = tokens.head() orelse return;
        if (headElement.value.tokenType != .commentText) return;
        std.debug.assert(headElement.next == null);
        const commentToken = &headElement.value;
        const comment = parser.tmdDoc.data[commentToken.start()..commentToken.end()];
        const attrs = parse_element_attributes(comment);

        //if (forBulletContainer) {
        //    std.debug.assert(parser.nextElementAttributes == null);
        //    const attributesElement = parser.tmdDoc.blocks.tail() orelse unreachable;
        //    std.debug.assert(attributesElement.value.blockType == .attributes);
        //    const bulletElement = attributesElement.prev orelse unreachable;
        //    std.debug.assert(bulletElement.value.blockType == .item);
        //    return try parser.setBlockAttributes(&bulletElement.value, attrs);
        //}

        if (attrs.id.len > 0) {
            if (parser.nextElementAttributes) |*as| {
                as.id = attrs.id;
            } else {
                parser.nextElementAttributes = .{ .id = attrs.id };
            }
        }
        if (attrs.classes.len > 0) {
            if (parser.nextElementAttributes) |*as| {
                as.classes = attrs.classes;
            } else {
                parser.nextElementAttributes = .{ .classes = attrs.classes };
            }
        }
    }

    // atomBlockInfo is an atom block, or a base/root block.
    fn setEndLineForAtomBlock(parser: *DocParser, atomBlockInfo: *tmd.BlockInfo) !void {
        if (parser.tmdDoc.lines.tail()) |lastLineInfoElement| {
            std.debug.assert(!parser.tmdDoc.blocks.empty());
            std.debug.assert(atomBlockInfo.blockType != .root);
            if (atomBlockInfo.blockType != .base) handle: {
                atomBlockInfo.setEndLine(&lastLineInfoElement.value);

                if (parser.pendingTocHeaderBlock) |headerBlock| {
                    std.debug.assert(atomBlockInfo.blockType == .header);
                    std.debug.assert(headerBlock == atomBlockInfo);

                    const level = headerBlock.blockType.header.level(parser.tmdDoc.data);
                    if (level == 1) {
                        if (parser.tmdDoc.titleHeader == null) {
                            parser.tmdDoc.titleHeader = headerBlock;
                            break :handle;
                        }
                    }

                    if (headerBlock.blockType.header.isBare()) break :handle;

                    std.debug.assert(1 <= level and level <= tmd.MaxHeaderLevel);
                    // used as hasNonBareHeaders temporarily.
                    // Will correct it at the end of parsing.
                    parser.tmdDoc._headerLevelNeedAdjusted[level - 1] = true;

                    const element = try list.createListElement(*tmd.BlockInfo, parser.allocator);
                    parser.tmdDoc.tocHeaders.push(element);
                    element.value = headerBlock;
                }
            }
        } else std.debug.assert(atomBlockInfo.blockType == .root);

        parser.pendingTocHeaderBlock = null;
    }

    fn onParseEnd(parser: *DocParser) !void {
        // ...
        try parser.tryToAttributeTheLastBlock();

        // ...
        const from = for (&parser.tmdDoc._headerLevelNeedAdjusted, 0..) |has, level| {
            if (!has) break level + 1;
        } else return;

        for (from..parser.tmdDoc._headerLevelNeedAdjusted.len) |level| {
            parser.tmdDoc._headerLevelNeedAdjusted[level] = false;
        }
    }

    fn parseAll(parser: *DocParser, tmdData: []const u8) !void {
        const rootBlockInfo = try parser.createAndPushBlockInfoElement();
        var blockArranger = BlockArranger.start(rootBlockInfo, parser.tmdDoc);
        // defer blockArranger.end(); // should not be called deferredly. Put in the end of the function now.

        var commentLineParser = ContentParser.make(parser);
        commentLineParser.init();
        defer commentLineParser.deinit(); // ToDo: needed?
        parser.commentLineParser = &commentLineParser;

        var contentParser = ContentParser.make(parser);
        contentParser.init();
        defer contentParser.deinit(); // ToDo: needed?

        const lineScanner = &parser.lineScanner;

        var listCount: u32 = 0;

        var boundedBlockStartInfo: ?union(enum) {
            codeBlockStart: *std.meta.FieldType(tmd.LineType, .codeBlockStart),
            customBlockStart: *std.meta.FieldType(tmd.LineType, .customBlockStart),

            fn markLen(self: @This()) u32 {
                return switch (self) {
                    inline else => |t| t.markLen,
                };
            }

            fn markChar(self: @This()) u8 {
                return switch (self) {
                    .codeBlockStart => '\'',
                    .customBlockStart => '"',
                };
            }
        } = null;

        // An atom block, or a base/root block.
        var currentAtomBlockInfo = rootBlockInfo;
        var atomBlockCount: u32 = 0;

        while (lineScanner.proceedToNextLine()) {
            var oldLastBlockInfo = parser.lastBlockInfo;

            var lineInfoElement = try list.createListElement(tmd.LineInfo, parser.allocator);
            var lineInfo = &lineInfoElement.value;
            lineInfo.containerMark = null;
            lineInfo.range.start = lineScanner.cursor;
            // ToDo: remove this line.
            //lineInfo.tokens = .{}; // !! Must be initialized. Otherwise undefined behavior.

            //std.debug.print("--- line#{}\n", .{lineScanner.cursorLineIndex});

            lineInfo.lineType = .{ .blank = .{} }; // will be change below

            parse_line: {
                _ = lineScanner.readUntilNotBlank();
                const leadingBlankEnd = lineScanner.cursor;

                // handle code/custom block context.
                if (boundedBlockStartInfo) |boundedBlockStart| {
                    const markChar = boundedBlockStart.markChar();
                    if (lineScanner.lineEnd) |_| {} else if (lineScanner.peekCursor() != markChar) {
                        _ = lineScanner.readUntilLineEnd();
                    } else handle: {
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(markChar) + 1;

                        //const codeBlockStartLineType: *tmd.LineType = @alignCast(@fieldParentPtr("codeBlockStart", codeBlockStart));
                        //const codeBlockStartLineInfo: *tmd.LineInfo = @alignCast(@fieldParentPtr("lineType", codeBlockStartLineType));
                        //std.debug.print("=== {}, {}, {s}\n", .{boundedBlockStart.markLen(), markLen, tmdData[lineInfo.rangeTrimmed.start..lineInfo.rangeTrimmed.end]});

                        if (markLen != boundedBlockStart.markLen()) {
                            if (lineScanner.lineEnd == null) _ = lineScanner.readUntilLineEnd();
                            break :handle;
                        }

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

                        switch (boundedBlockStart) {
                            .codeBlockStart => {
                                lineInfo.lineType = .{ .codeBlockEnd = .{
                                    .markLen = markLen,
                                    .markEndWithSpaces = playloadStart,
                                } };

                                const playloadRange = lineInfo.playloadRange();
                                const playload = parser.tmdDoc.rangeData(playloadRange);
                                const attrs = parse_code_block_close_playload(playload);
                                if (!std.meta.eql(attrs, .{})) {
                                    var contentStreamAttributesElement = try list.createListElement(tmd.ContentStreamAttributes, parser.allocator);
                                    parser.tmdDoc.contentStreamAttributes.push(contentStreamAttributesElement);
                                    contentStreamAttributesElement.value = attrs;
                                    lineInfo.lineType.codeBlockEnd.streamAttrs = &contentStreamAttributesElement.value;
                                }
                            },
                            .customBlockStart => {
                                lineInfo.lineType = .{ .customBlockEnd = .{
                                    .markLen = markLen,
                                    .markEndWithSpaces = playloadStart,
                                } };
                            },
                        }

                        boundedBlockStartInfo = null;
                    }

                    if (lineInfo.lineType == .blank) {
                        std.debug.assert(lineScanner.lineEnd != null);
                        std.debug.assert(boundedBlockStartInfo != null);

                        lineInfo.lineType = switch (boundedBlockStart) {
                            .codeBlockStart => .{ .code = .{} },
                            .customBlockStart => .{ .data = .{} },
                        };
                        lineInfo.rangeTrimmed.start = lineInfo.range.start;
                        lineInfo.rangeTrimmed.end = lineScanner.cursor;
                    } else {
                        std.debug.assert(boundedBlockStartInfo == null);

                        std.debug.assert(lineInfo.lineType == .codeBlockEnd or
                            lineInfo.lineType == .customBlockEnd);
                    }

                    break :parse_line;
                } // atom code/custom block context

                lineInfo.rangeTrimmed.start = leadingBlankEnd;

                // handle blank line.
                if (lineScanner.lineEnd) |_| {
                    lineInfo.lineType = .{ .blank = .{} };
                    lineInfo.rangeTrimmed.end = leadingBlankEnd;

                    if (currentAtomBlockInfo.blockType != .blank) {
                        const blankBlockInfo = try parser.createAndPushBlockInfoElement();
                        blankBlockInfo.blockType = .{
                            .blank = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(blankBlockInfo, false);

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = blankBlockInfo;
                        atomBlockCount += 1;
                    }

                    break :parse_line;
                }

                const lineStart = lineScanner.cursor;
                // try to parse leading container mark.
                switch (lineScanner.peekCursor()) {
                    '*', '+', '-', '~', ':' => |mark| handle: {
                        if (lineScanner.peekNext() == '.') {
                            lineScanner.advance(1);
                        } else if (mark == '-' and lineScanner.peekNext() == '-') {
                            break :handle;
                        }

                        lineScanner.advance(1);
                        const markEnd = lineScanner.cursor;
                        const numSpaces = lineScanner.readUntilNotBlank();
                        if (numSpaces == 0 and lineScanner.lineEnd == null) { // not list item
                            lineScanner.setCursor(lineStart);
                            lineInfo.containerMark = null;
                            break :handle;
                        }

                        const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                            lineInfo.rangeTrimmed.end = markEnd;
                            break :blk markEnd;
                        } else lineScanner.cursor;

                        lineInfo.containerMark = .{ .item = .{
                            .markEnd = markEnd,
                            .markEndWithSpaces = markEndWithSpaces,
                        } };

                        std.debug.assert(markEnd - leadingBlankEnd == 1 or markEnd - leadingBlankEnd == 2);
                        const markStr = tmdData[leadingBlankEnd..markEnd];
                        const markTypeIndex = tmd.listItemTypeIndex(markStr);
                        const createNewList = blockArranger.shouldCreateNewList(markTypeIndex);
                        const listBlockInfo: ?*tmd.BlockInfo = if (createNewList) blk: {
                            const listBlockInfo = try parser.createAndPushBlockInfoElement();
                            listBlockInfo.blockType = .{
                                .list = .{
                                    ._itemTypeIndex = markTypeIndex,
                                    .listType = tmd.listType(markStr), // if .bullets, might be adjusted to .tabs later
                                    .secondMode = markStr.len == 2,
                                    .index = listCount,
                                },
                            };
                            listCount += 1;
                            break :blk listBlockInfo;
                        } else null;

                        const listItemBlockInfo = try parser.createAndPushBlockInfoElement();
                        listItemBlockInfo.blockType = .{
                            .item = .{
                                //.isFirst = false, // will be modified eventually
                                //.isLast = false, // will be modified eventually
                                .list = undefined, // will be modified below in stackListItemBlock
                            },
                        };

                        try blockArranger.stackListItemBlock(listItemBlockInfo, markTypeIndex, listBlockInfo);
                    },
                    '#', '>', '!', '?', '.' => |mark| handle: {
                        lineScanner.advance(1);
                        const markEnd = lineScanner.cursor;
                        const numSpaces = lineScanner.readUntilNotBlank();
                        if (numSpaces == 0 and lineScanner.lineEnd == null) { // not container
                            lineScanner.setCursor(lineStart);
                            lineInfo.containerMark = null;
                            break :handle;
                        }

                        const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                            lineInfo.rangeTrimmed.end = markEnd;
                            break :blk markEnd;
                        } else lineScanner.cursor;

                        const containerBlockInfo = try parser.createAndPushBlockInfoElement();
                        switch (mark) {
                            '#' => {
                                lineInfo.containerMark = .{ .table = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .table = .{},
                                };
                            },
                            '>' => {
                                lineInfo.containerMark = .{ .quotation = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .quotation = .{},
                                };
                            },
                            '!' => {
                                lineInfo.containerMark = .{ .notice = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .notice = .{},
                                };
                            },
                            '?' => {
                                lineInfo.containerMark = .{ .reveal = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .reveal = .{},
                                };
                            },
                            '.' => {
                                lineInfo.containerMark = .{ .unstyled = .{
                                    .markEnd = markEnd,
                                    .markEndWithSpaces = markEndWithSpaces,
                                } };
                                containerBlockInfo.blockType = .{
                                    .unstyled = .{},
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

                const contentStart = lineScanner.cursor;

                // try to parse atom block mark.
                if (lineScanner.lineEnd != null) {
                    // contentStart keeps unchanged.
                } else switch (lineScanner.peekCursor()) { // try to parse atom block mark
                    '-' => handle: {
                        lineScanner.advance(1);
                        const markLen = 1 + lineScanner.readUntilNotChar('-');
                        if (markLen < 3) {
                            lineScanner.setCursor(contentStart); // not perfect but avoid bugs
                            break :handle;
                        }

                        const contentEnd = lineScanner.cursor;
                        if (lineScanner.lineEnd == null) {
                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd == null) break :handle;
                        }

                        lineInfo.lineType = .{ .line = .{
                            .markLen = markLen,
                        } };

                        const lineBlockInfo = try parser.createAndPushBlockInfoElement();
                        lineBlockInfo.blockType = .{
                            .line = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(lineBlockInfo, lineInfo.containerMark != null);

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = lineBlockInfo;
                        atomBlockCount += 1;

                        lineInfo.rangeTrimmed.end = contentEnd;
                    },
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

                            const baseBlockInfo = try parser.createAndPushBlockInfoElement();
                            baseBlockInfo.blockType = .{
                                .base = .{
                                    .openLine = lineInfo,
                                },
                            };

                            const playloadRange = baseBlockInfo.blockType.base.openPlayloadRange();
                            const playload = parser.tmdDoc.rangeData(playloadRange);
                            const attrs = parse_base_block_open_playload(playload);
                            if (!std.meta.eql(attrs, .{})) {
                                var baseBlockAttibutesElement = try list.createListElement(tmd.BaseBlockAttibutes, parser.allocator);
                                parser.tmdDoc.baseBlockAttibutes.push(baseBlockAttibutesElement);
                                baseBlockAttibutesElement.value = attrs;
                                baseBlockInfo.blockType.base.openLine.lineType.baseBlockOpen.attrs = &baseBlockAttibutesElement.value;
                            }

                            try blockArranger.openBaseBlock(baseBlockInfo, lineInfo.containerMark != null, attrs.commentedOut);

                            try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = baseBlockInfo;
                            atomBlockCount += 1;
                        } else {
                            lineInfo.lineType = .{ .baseBlockClose = .{
                                .markLen = markLen,
                                .markEndWithSpaces = playloadStart,
                            } };

                            const baseBlockInfo = try blockArranger.closeCurrentBaseBlock();
                            baseBlockInfo.blockType.base.closeLine = lineInfo;

                            try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = baseBlockInfo;
                            atomBlockCount += 1;
                        }
                    },
                    '\'', '"' => |mark| handle: {
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

                        const atomBlock = if (mark == '\'') blk: {
                            lineInfo.lineType = .{ .codeBlockStart = .{
                                .markLen = markLen,
                                .markEndWithSpaces = playloadStart,
                            } };

                            boundedBlockStartInfo = .{
                                .codeBlockStart = &lineInfo.lineType.codeBlockStart,
                            };

                            const codeBlockInfo = try parser.createAndPushBlockInfoElement();
                            codeBlockInfo.blockType = .{
                                .code = .{
                                    .startLine = lineInfo,
                                },
                            };

                            const playloadRange = codeBlockInfo.blockType.code.startPlayloadRange();
                            const playload = parser.tmdDoc.rangeData(playloadRange);
                            const attrs = parse_code_block_open_playload(playload);
                            if (!std.meta.eql(attrs, .{})) {
                                var codeBlockAttibutesElement = try list.createListElement(tmd.CodeBlockAttibutes, parser.allocator);
                                parser.tmdDoc.codeBlockAttibutes.push(codeBlockAttibutesElement);
                                codeBlockAttibutesElement.value = attrs;
                                codeBlockInfo.blockType.code.startLine.lineType.codeBlockStart.attrs = &codeBlockAttibutesElement.value;
                            }

                            break :blk codeBlockInfo;
                        } else blk: {
                            std.debug.assert(mark == '"');

                            lineInfo.lineType = .{ .customBlockStart = .{
                                .markLen = markLen,
                                .markEndWithSpaces = playloadStart,
                            } };

                            boundedBlockStartInfo = .{
                                .customBlockStart = &lineInfo.lineType.customBlockStart,
                            };

                            const customBlockInfo = try parser.createAndPushBlockInfoElement();
                            customBlockInfo.blockType = .{
                                .custom = .{
                                    .startLine = lineInfo,
                                },
                            };

                            const playloadRange = customBlockInfo.blockType.custom.startPlayloadRange();
                            const playload = parser.tmdDoc.rangeData(playloadRange);
                            const attrs = parse_custom_block_open_playload(playload);
                            if (!std.meta.eql(attrs, .{})) {
                                var customBlockAttibutesElement = try list.createListElement(tmd.CustomBlockAttibutes, parser.allocator);
                                parser.tmdDoc.customBlockAttibutes.push(customBlockAttibutesElement);
                                customBlockAttibutesElement.value = attrs;
                                customBlockInfo.blockType.custom.startLine.lineType.customBlockStart.attrs = &customBlockAttibutesElement.value;
                            }

                            break :blk customBlockInfo;
                        };

                        try blockArranger.stackAtomBlock(atomBlock, lineInfo.containerMark != null);

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = atomBlock;
                        atomBlockCount += 1;
                    },
                    '#' => handle: {
                        // Must starts with 2 #.
                        if (lineScanner.peekNext() != '#') {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        } else {
                            lineScanner.advance(1);
                            if (lineScanner.peekNext() != '#') {
                                lineScanner.setCursor(contentStart);
                                break :handle;
                            }
                        }

                        var isFirstLevel = true;
                        lineScanner.advance(1);
                        const markLen = if (lineScanner.peekNext()) |c| blk: {
                            lineScanner.advance(1);
                            switch (c) {
                                '#', '=', '+', '-' => |mark| {
                                    isFirstLevel = mark == '#';
                                    lineScanner.advance(1);
                                    break :blk 4 + lineScanner.readUntilNotChar(mark);
                                },
                                else => break :blk 3,
                            }
                        } else 3;

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

                        const headerBlockInfo = try parser.createAndPushBlockInfoElement();
                        headerBlockInfo.blockType = .{
                            .header = .{
                                .startLine = lineInfo,
                            },
                        };
                        if (isFirstLevel) {
                            try blockArranger.stackFirstLevelHeaderBlock(headerBlockInfo, lineInfo.containerMark != null);
                        } else {
                            try blockArranger.stackAtomBlock(headerBlockInfo, lineInfo.containerMark != null);
                        }

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = headerBlockInfo;
                        atomBlockCount += 1;

                        if (blockArranger.shouldHeaderChildBeInTOC()) {
                            // Will use the info in setEndLineForAtomBlock.
                            // Note: whether or not headerBlockInfo is empty can't be determined now.
                            parser.pendingTocHeaderBlock = headerBlockInfo;
                        }

                        contentParser.on_new_atom_block(currentAtomBlockInfo);

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_header_line_tokens(lineInfo, lineScanner.cursor);
                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);
                    },
                    ';' => |mark| handle: {
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

                        //const newAtomBlock = if (mark == ';') blk: {
                        lineInfo.lineType = .{ .usual = .{
                            .markLen = markLen,
                            .markEndWithSpaces = lineScanner.cursor,
                        } };

                        const usualBlockInfo = try parser.createAndPushBlockInfoElement();
                        usualBlockInfo.blockType = .{
                            .usual = .{
                                .startLine = lineInfo,
                            },
                        };
                        const newAtomBlock = usualBlockInfo;

                        try blockArranger.stackAtomBlock(newAtomBlock, lineInfo.containerMark != null);

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = newAtomBlock;
                        atomBlockCount += 1;

                        contentParser.on_new_atom_block(currentAtomBlockInfo);

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_usual_line_tokens(lineInfo, lineScanner.cursor, true);
                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);
                    },
                    '@' => |mark| handle: {
                        lineScanner.advance(1);
                        const markLen = lineScanner.readUntilNotChar(mark) + 1;
                        if (markLen < 3) {
                            lineScanner.setCursor(contentStart);
                            break :handle;
                        }

                        //var forBulletContainer = false;
                        // NOTE: if items can be specified IDS again in the future,
                        //       remember handle the cases they are used as footnotes.
                        //       (render their childrens as the footnotes).

                        var playloadStart = lineScanner.cursor;
                        if (lineScanner.lineEnd) |_| {
                            lineInfo.rangeTrimmed.end = playloadStart;
                        } else {
                            //if (lineInfo.containerMark) |m| {
                            //    if (m == .item and lineScanner.peekCursor() == '<') {
                            //        lineScanner.advance(1);
                            //        forBulletContainer = true;
                            //    }
                            //}

                            _ = lineScanner.readUntilNotBlank();
                            if (lineScanner.lineEnd) |_| {
                                lineInfo.rangeTrimmed.end = playloadStart;
                            } else {
                                playloadStart = lineScanner.cursor;
                            }
                        }

                        lineInfo.lineType = .{ .attributes = .{
                            .markLen = markLen,
                            .markEndWithSpaces = playloadStart,
                        } };

                        if (lineInfo.containerMark != null or currentAtomBlockInfo.blockType != .attributes) {
                            // There might be some new blocks created in the current iteration.
                            const realOldLast = parser.lastBlockInfo;

                            // ...
                            const commentBlockInfo = try parser.createAndPushBlockInfoElement();
                            commentBlockInfo.blockType = .{
                                .attributes = .{
                                    .startLine = lineInfo,
                                },
                            };

                            try blockArranger.stackAtomBlock(commentBlockInfo, lineInfo.containerMark != null);

                            try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                            currentAtomBlockInfo = commentBlockInfo;
                            atomBlockCount += 1;

                            // !! important
                            try parser.tryToAttributeBlock(realOldLast);
                            oldLastBlockInfo = parser.lastBlockInfo;
                        }

                        contentParser.on_new_atom_block(currentAtomBlockInfo);
                        //defer contentParser.on_new_atom_block(); // ToDo: might be unnecessary

                        if (lineScanner.lineEnd != null) {
                            // lineInfo.rangeTrimmed.end has been determined.
                            // And no data for parsing tokens.
                            break :handle;
                        }

                        const contentEnd = try contentParser.parse_attributes_line_tokens(lineInfo, lineScanner.cursor);

                        lineInfo.rangeTrimmed.end = contentEnd;
                        std.debug.assert(lineScanner.lineEnd != null);

                        //try parser.onNewAttributesLine(lineInfo, forBulletContainer);
                        try parser.onNewAttributesLine(lineInfo);
                    },
                    else => {},
                }

                // If line type is still not determined, then it is just a usual line.
                if (lineInfo.lineType == .blank) {
                    lineInfo.lineType = .{ .usual = .{
                        .markLen = 0,
                        .markEndWithSpaces = lineScanner.cursor,
                    } };

                    if (lineInfo.containerMark != null or
                        currentAtomBlockInfo.blockType != .usual and currentAtomBlockInfo.blockType != .header
                    //and currentAtomBlockInfo.blockType != .footer
                    ) {
                        const usualBlockInfo = try parser.createAndPushBlockInfoElement();
                        usualBlockInfo.blockType = .{
                            .usual = .{
                                .startLine = lineInfo,
                            },
                        };
                        try blockArranger.stackAtomBlock(usualBlockInfo, lineInfo.containerMark != null);

                        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);
                        currentAtomBlockInfo = usualBlockInfo;
                        atomBlockCount += 1;

                        contentParser.on_new_atom_block(currentAtomBlockInfo);
                    }

                    if (lineScanner.lineEnd == null) {
                        const contentEnd = try contentParser.parse_usual_line_tokens(
                            lineInfo,
                            contentStart,
                            //currentAtomBlockInfo.blockType != .header and
                            contentStart == lineScanner.cursor,
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

            if (oldLastBlockInfo != parser.lastBlockInfo) {
                try parser.tryToAttributeBlock(oldLastBlockInfo);
            }
        }

        // Meaningful only for code snippet block (and popential later custom app block).
        try parser.setEndLineForAtomBlock(currentAtomBlockInfo);

        // ToDo: remove this line. (Forget the reason.;( )
        contentParser.on_new_atom_block(currentAtomBlockInfo); // try to determine line-end render manner for the last coment line.

        try contentParser.matchLinks(); // ToDo: same effect when being put in the above else-block.

        blockArranger.end();

        try parser.onParseEnd();
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
        std.debug.print("+{}: #{} {s}", .{ blockInfo.nestingDepth, blockInfo.index, blockInfo.typeName() });
        switch (blockInfo.blockType) {
            .list => |itemList| {
                std.debug.print(" (index: {}, type: {s}, 2nd mode: {})", .{ itemList.index, itemList.typeName(), itemList.secondMode });
            },
            .item => |*listItem| {
                std.debug.print(" (@list#{})", .{listItem.list.blockType.list.index});
                if (listItem.isFirst() and listItem.isLast()) {
                    std.debug.print(" (first, last)", .{});
                } else if (listItem.isFirst()) {
                    std.debug.print(" (first)", .{});
                } else if (listItem.isLast()) {
                    std.debug.print(" (last)", .{});
                }
            },
            else => {},
        }
        if (blockInfo.getNextSibling()) |sibling| {
            std.debug.print(" (next sibling: #{} {s})", .{ sibling.index, sibling.typeName() });
        } else {
            std.debug.print(" (next sibling: <null>)", .{});
        }
        if (blockInfo.attributes) |attrs| {
            if (attrs.id.len > 0) {
                std.debug.print(" (id={s})", .{attrs.id});
            }
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

// ToDo: remove the following parse functions (use tokens instead)?

// Use HTML4 spec:
//     ID and NAME tokens must begin with a letter ([A-Za-z]) and
//     may be followed by any number of letters, digits ([0-9]),
//     hyphens ("-"), underscores ("_"), colons (":"), and periods (".").
const charIdLevels = blk: {
    var table = [1]u3{0} ** 127;

    for ('a'..'z', 'A'..'Z') |i, j| {
        table[i] = 6;
        table[j] = 6;
    }
    for ('0'..'9') |i| table[i] = 5;
    table['_'] = 4;
    table['-'] = 3;
    table[':'] = 2;
    table['.'] = 1;
    break :blk table;
};

pub fn parse_element_attributes(playload: []const u8) tmd.ElementAttibutes {
    var attrs = tmd.ElementAttibutes{};

    const id = std.meta.fieldIndex(tmd.ElementAttibutes, "id").?;
    const classes = std.meta.fieldIndex(tmd.ElementAttibutes, "classes").?;
    const kvs = std.meta.fieldIndex(tmd.ElementAttibutes, "kvs").?;

    var lastOrder: isize = -1;
    var kvList: ?struct {
        first: []const u8,
        last: []const u8,
    } = null;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '#' => {
                    if (lastOrder >= id) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or charIdLevels[item[1]] != 6) break;
                    for (item[2..]) |c| {
                        if (c >= 128 or charIdLevels[c] < 1) break :parse;
                    }
                    attrs.id = item[1..];
                    lastOrder = id;
                },
                '.' => {
                    // classes can't contain periods, but can contain colons.
                    // (This is TMD specific. HTML4 allows periods in classes).

                    // classes are seperated by semicolons.

                    // ToDo: support .class1 .class2?

                    if (lastOrder >= classes) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or charIdLevels[item[1]] != 6) break;
                    for (item[2..]) |c| {
                        if (c == ';') continue; // seperators (TMD specific)
                        if (c >= 128 or charIdLevels[c] < 2) break :parse;
                    }

                    attrs.classes = item[1..];
                    lastOrder = classes;
                },
                else => {
                    // key-value pairs are seperated by SPACE or TAB chars.
                    // Key parsing is the same as ID parsing.
                    // Values containing SPACE and TAB chars must be quoted in `...` (the Go literal string form).

                    if (lastOrder > kvs) break;

                    if (item.len < 3) break;

                    // ToDo: write a more pricise implementation.

                    if (std.mem.indexOfScalar(u8, item, '=')) |i| {
                        if (0 < i and i < item.len - 1) {
                            if (kvList == null) kvList = .{ .first = item, .last = item } else kvList.?.last = item;
                        } else break;
                    } else break;

                    lastOrder = kvs;
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    if (kvList) |v| {
        const start = @intFromPtr(v.first.ptr);
        const end = @intFromPtr(v.last.ptr + v.last.len);
        attrs.kvs = v.first.ptr[0 .. end - start];
    }

    return attrs;
}

pub fn parse_base_block_open_playload(playload: []const u8) tmd.BaseBlockAttibutes {
    var attrs = tmd.BaseBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "commentedOut").?;
    //const isFooter = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "isFooter").?;
    const horizontalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "horizontalAlign").?;
    const cellSpans = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "cellSpans").?;

    var lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    defer lastOrder = commentedOut;

                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                },
                //'&' => {
                //    if (lastOrder >= isFooter) break;
                //    defer lastOrder = horizontalAlign;
                //
                //    if (item.len != 2) break;
                //    if (item[1] != '&') break;
                //    attrs.isFooter = true;
                //},
                '>', '<' => {
                    if (lastOrder >= horizontalAlign) break;
                    defer lastOrder = horizontalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '>' and item[1] != '<') break;
                    if (mem.eql(u8, item, "<<"))
                        attrs.horizontalAlign = .left
                    else if (mem.eql(u8, item, ">>"))
                        attrs.horizontalAlign = .right
                    else if (mem.eql(u8, item, "><"))
                        attrs.horizontalAlign = .center
                    else if (mem.eql(u8, item, "<>"))
                        attrs.horizontalAlign = .justify;
                },
                '.' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 3) break;
                    if (item[1] != '.') break;
                    const trimDotDot = item[2..];
                    const colonPos = std.mem.indexOfScalar(u8, trimDotDot, ':') orelse trimDotDot.len;
                    if (colonPos == 0 or colonPos == trimDotDot.len - 1) break;
                    const axisSpan = std.fmt.parseInt(u32, trimDotDot[0..colonPos], 10) catch break;
                    const crossSpan = if (colonPos == trimDotDot.len) 1 else std.fmt.parseInt(u32, trimDotDot[colonPos + 1 ..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = axisSpan,
                        .crossSpan = crossSpan,
                    };
                },
                ':' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 2) break;
                    const crossSpan = std.fmt.parseInt(u32, item[1..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = 1,
                        .crossSpan = crossSpan,
                    };
                },
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
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
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

pub fn parse_code_block_close_playload(playload: []const u8) tmd.ContentStreamAttributes {
    var attrs = tmd.ContentStreamAttributes{};

    var arrowFound = false;
    var content: []const u8 = "";

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) {
            if (!arrowFound) {
                if (item.len != 2) return attrs;
                for (item) |c| if (c != '<') return attrs;
                arrowFound = true;
            } else if (content.len > 0) {
                return attrs;
            } else if (item.len > 0) {
                content = item;
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    attrs.content = content;
    return attrs;
}

pub fn parse_custom_block_open_playload(playload: []const u8) tmd.CustomBlockAttibutes {
    var attrs = tmd.CustomBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "commentedOut").?;
    //const app = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "app").?;

    const lastOrder: isize = -1;

    var it = mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    if (item.len > 0) {
                        attrs.app = item;
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

pub fn isValidURL(text: []const u8) bool {
    // ToDo: more precisely and performant.

    return mem.startsWith(u8, text, "#") or mem.startsWith(u8, text, "http") or mem.indexOf(u8, text, ".htm") != null or mem.indexOf(u8, text, ".html") != null;
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
