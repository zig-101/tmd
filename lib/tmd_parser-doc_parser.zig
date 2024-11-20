const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const list = @import("list.zig");

const BlockArranger = @import("tmd_parser-block_manager.zig");
const ContentParser = @import("tmd_parser-content_parser.zig");
const LineScanner = @import("tmd_parser-line_scanner.zig");
const AttributeParser = @import("tmd_parser-attribute_parser.zig");
const LinkMatcher = @import("tmd_parser-link_matcher.zig");

const DocParser = @This();

//const DocParser = struct {
allocator: mem.Allocator,

tmdDoc: *tmd.Doc,
numBlocks: u32 = 0,

commentLineParser: *ContentParser = undefined,
lineScanner: LineScanner = undefined,

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
            const attributesBlock = while (block.prev()) |prevBlock| {
                switch (prevBlock.blockType) {
                    .attributes => break prevBlock,
                    else => block = prevBlock,
                }
            } else unreachable;

            std.debug.assert(block.blockType != .attributes);

            if (attributesBlock.nextSibling() == block) {
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
    const comment = parser.tmdDoc.rangeData(commentToken.range());
    const attrs = AttributeParser.parse_element_attributes(comment);

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

pub fn parseAll(parser: *DocParser) !void {
    try parser.parse();

    const matcher = LinkMatcher{
        .tmdData = parser.tmdDoc.data,
        .links = &parser.tmdDoc.links,
        .allocator = parser.allocator,
    };
    try matcher.matchLinks(); // ToDo: same effect when being put in the above else-block.
}

fn parse(parser: *DocParser) !void {
    const tmdData = parser.tmdDoc.data;
    parser.lineScanner = .{ .data = tmdData };

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
                            const attrs = AttributeParser.parse_code_block_close_playload(playload);
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

            // handle blank line.
            if (lineScanner.lineEnd) |_| {
                // For a blank line, all blanks belongs to the line-end token.
                lineInfo.rangeTrimmed.start = lineInfo.range.start;
                lineInfo.rangeTrimmed.end = lineInfo.range.start;

                lineInfo.lineType = .{ .blank = .{} };

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

            lineInfo.rangeTrimmed.start = leadingBlankEnd;

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

                    lineInfo.lineType = .{ .seperator = .{
                        .markLen = markLen,
                    } };

                    const lineBlockInfo = try parser.createAndPushBlockInfoElement();
                    lineBlockInfo.blockType = .{
                        .seperator = .{
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
                        const attrs = AttributeParser.parse_base_block_open_playload(playload);
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
                        const attrs = AttributeParser.parse_code_block_open_playload(playload);
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
                        const attrs = AttributeParser.parse_custom_block_open_playload(playload);
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

    blockArranger.end();

    try parser.onParseEnd();
}
//};
