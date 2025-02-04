const std = @import("std");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");

const BlockArranger = @import("tmd_to_doc-block_manager.zig");
const ContentParser = @import("tmd_to_doc-content_parser.zig");
const LineScanner = @import("tmd_to_doc-line_scanner.zig");
const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
const LinkMatcher = @import("tmd_to_doc-link_matcher.zig");

const DocParser = @This();

//const DocParser = struct {
//allocator: std.mem.Allocator, // moved into tmd.Doc now.

tmdDoc: *tmd.Doc,
numBlocks: u32 = 0,

commentLineParser: *ContentParser = undefined,
lineScanner: LineScanner = undefined,

nextElementAttributes: ?tmd.ElementAttibutes = null,
lastBlock: *tmd.Block = undefined,

pendingTocHeaderBlock: ?*tmd.Block = null,

fn createAndPushBlockElement(parser: *DocParser) !*tmd.Block {
    var blockElement = try list.createListElement(tmd.Block, parser.tmdDoc.allocator);
    parser.tmdDoc.blocks.pushTail(blockElement);
    parser.tmdDoc.blockCount += 1;

    const block = &blockElement.value;
    block.attributes = null; // !important
    parser.numBlocks += 1;
    block.index = parser.numBlocks;

    parser.lastBlock = block;

    return block;
}

fn tryToAttributeBlock(parser: *DocParser, oldLastBlock: *tmd.Block) !void {
    // std.debug.assert(oldLastBlock != parser.lastBlock); // possible equal in the end

    if (oldLastBlock.blockType != .attributes) {
        if (parser.nextElementAttributes) |as| {
            var block = oldLastBlock;
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

    // oldLastBlock.attributes = null; // moved to createAndPushBlockElement
}

fn tryToAttributeTheLastBlock(parser: *DocParser) !void {
    std.debug.assert(parser.lastBlock == &parser.tmdDoc.blocks.tail.?.value);
    switch (parser.lastBlock.blockType) {
        .attributes => if (parser.nextElementAttributes) |as| {
            try parser.setBlockAttributes(parser.lastBlock, as); // a footer attributes
        },
        else => try parser.tryToAttributeBlock(parser.lastBlock),
    }
}

fn setBlockAttributes(parser: *DocParser, block: *tmd.Block, as: tmd.ElementAttibutes) !void {
    var blockAttributesElement = try list.createListElement(tmd.ElementAttibutes, parser.tmdDoc.allocator);
    parser.tmdDoc._elementAttributes.pushTail(blockAttributesElement);

    const attrs = &blockAttributesElement.value;
    attrs.* = as;

    block.attributes = attrs;

    if (attrs.id.len > 0) {
        const blockTreeNodeElement = if (parser.tmdDoc._freeBlockTreeNodeElement) |e| blk: {
            parser.tmdDoc._freeBlockTreeNodeElement = null;
            break :blk e;
        } else blk: {
            const BlockRedBlack = tree.RedBlack(*tmd.Block, tmd.Block);
            const element = try list.createListElement(BlockRedBlack.Node, parser.tmdDoc.allocator);
            parser.tmdDoc._blockTreeNodes.pushTail(element);
            break :blk element;
        };

        const blockTreeNode = &blockTreeNodeElement.value;
        blockTreeNode.value = block;
        const n = parser.tmdDoc.blocksByID.insert(blockTreeNode);
        if (n != blockTreeNode) {
            parser.tmdDoc._freeBlockTreeNodeElement = blockTreeNodeElement;
        }
    }
}

//fn onNewAttributesLine(parser: *DocParser, line: *const tmd.Line, forBulletContainer: bool) !void {
fn onNewAttributesLine(parser: *DocParser, line: *const tmd.Line) !void {
    std.debug.assert(line.lineType == .attributes);
    //const tokens = line.lineType.attributes.tokens;
    //const commentElement = tokens.head orelse return;
    const lineTypeToken = line.lineTypeMarkToken() orelse unreachable;
    const commentToken = lineTypeToken.next() orelse return;
    if (commentToken.* != .commentText) return;
    std.debug.assert(commentToken.next() == null);
    //const commentToken = &commentElement.value;
    const comment = parser.tmdDoc.rangeData(commentToken.range());
    const attrs = AttributeParser.parse_element_attributes(comment);

    //if (forBulletContainer) {
    //    std.debug.assert(parser.nextElementAttributes == null);
    //    const attributesElement = parser.tmdDoc.blocks.tail orelse unreachable;
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

// atomBlock is an atom block, or a base/root block.
fn setEndLineForAtomBlock(parser: *DocParser, atomBlock: *tmd.Block) !void {
    if (parser.tmdDoc.lines.tail) |lastLineElement| {
        std.debug.assert(!parser.tmdDoc.blocks.empty());
        std.debug.assert(atomBlock.blockType != .root);
        if (atomBlock.blockType != .base) handle: {
            atomBlock.setEndLine(&lastLineElement.value);

            if (parser.pendingTocHeaderBlock) |headerBlock| {
                std.debug.assert(atomBlock.blockType == .header);
                std.debug.assert(headerBlock == atomBlock);

                if (headerBlock.blockType.header.isBare()) break :handle;

                const level = headerBlock.blockType.header.level(parser.tmdDoc.data);
                if (level == 1) {
                    if (parser.tmdDoc.titleHeader == null) {
                        parser.tmdDoc.titleHeader = headerBlock;
                        break :handle;
                    }
                }

                std.debug.assert(1 <= level and level <= tmd.MaxHeaderLevel);
                // used as hasNonBareHeaders temporarily.
                // Will correct it at the end of parsing.
                parser.tmdDoc._headerLevelNeedAdjusted[level - 1] = true;

                const element = try list.createListElement(*tmd.Block, parser.tmdDoc.allocator);
                parser.tmdDoc.tocHeaders.pushTail(element);
                element.value = headerBlock;
            }
        }
    } else std.debug.assert(atomBlock.blockType == .root);

    parser.pendingTocHeaderBlock = null;
}

pub fn createTokenForLine(self: *@This(), line: *tmd.Line) !*tmd.Token {
    var tokenElement = try list.createListElement(tmd.Token, self.tmdDoc.allocator);
    line.tokens.pushTail(tokenElement);
    return &tokenElement.value;
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
        .allocator = parser.tmdDoc.allocator,
    };
    try matcher.matchLinks(); // ToDo: same effect when being put in the above else-block.
}

fn parse(parser: *DocParser) !void {
    const allocator = parser.tmdDoc.allocator;
    const tmdData = parser.tmdDoc.data;
    parser.lineScanner = .{ .data = tmdData };

    const rootBlock = try parser.createAndPushBlockElement();
    var blockArranger = BlockArranger.start(rootBlock, parser.tmdDoc);
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

    var boundedBlockStartInfo: ?struct {
        lineType: tmd.Line.Type,
        markChar: u8,
        markLen: u32,
    } = null;

    // An atom block, or a base/root block.
    var currentAtomBlock = rootBlock;
    var atomBlockCount: u32 = 0;

    while (lineScanner.proceedToNextLine()) {
        var oldLastBlock = parser.lastBlock;

        var lineElement = try list.createListElement(tmd.Line, allocator);
        var line = &lineElement.value;
        line.* = .{};

        const lineStart: tmd.DocSize = @intCast(lineScanner.cursor);
        line._startAt.set(lineStart);

        //std.debug.print("--- line#{}\n", .{lineScanner.cursorLineIndex});

        line.lineType = .blank; // will be change below

        var suffixBlankStart: u32 = undefined;
        defer line.suffixBlankStart = @intCast(suffixBlankStart);

        parse_line: {
            _ = lineScanner.readUntilNotBlank();
            const leadingBlankEnd: tmd.DocSize = @intCast(lineScanner.cursor);

            // handle code/custom block context.
            if (boundedBlockStartInfo) |boundedBlockStart| {
                const markChar = boundedBlockStart.markChar;
                if (lineScanner.lineEnd) |_| {} else if (lineScanner.peekCursor() != markChar) {
                    _ = lineScanner.readUntilLineEnd();
                } else handle: {
                    lineScanner.advance(1);
                    const markLen = lineScanner.readUntilNotChar(markChar) + 1;

                    if (markLen != boundedBlockStart.markLen) {
                        if (lineScanner.lineEnd == null) _ = lineScanner.readUntilLineEnd();
                        break :handle;
                    }

                    line.prefixBlankEnd = leadingBlankEnd;

                    var playloadStart = lineScanner.cursor;
                    if (lineScanner.lineEnd) |_| {
                        suffixBlankStart = playloadStart;
                    } else {
                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = playloadStart;
                        } else {
                            playloadStart = lineScanner.cursor;
                            const numTrailingBlanks = lineScanner.readUntilLineEnd();
                            suffixBlankStart = lineScanner.cursor - numTrailingBlanks;
                        }
                    }

                    switch (boundedBlockStart.lineType) {
                        .codeBlockStart => {
                            line.lineType = .codeBlockEnd;

                            //const playloadRange = line.playloadRange();
                            const playloadRange = tmd.Range{ .start = playloadStart, .end = suffixBlankStart };
                            const playload = parser.tmdDoc.rangeData(playloadRange);
                            const attrs = AttributeParser.parse_code_block_close_playload(playload);
                            if (!std.meta.eql(attrs, .{})) {
                                var _contentStreamAttributesElement = try list.createListElement(tmd.ContentStreamAttributes, allocator);
                                parser.tmdDoc._contentStreamAttributes.pushTail(_contentStreamAttributesElement);
                                _contentStreamAttributesElement.value = attrs;
                                //line.lineType.codeBlockEnd.streamAttrs = &_contentStreamAttributesElement.value;
                                (try parser.createTokenForLine(line)).* = .{
                                    .extra = .{
                                        .info = .{
                                            .streamAttrs = &_contentStreamAttributesElement.value,
                                        },
                                    },
                                };
                            }
                        },
                        .customBlockStart => {
                            line.lineType = .customBlockEnd;
                        },
                        else => unreachable,
                    }
                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(leadingBlankEnd),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(playloadStart - leadingBlankEnd - markLen),
                        },
                    };

                    boundedBlockStartInfo = null;
                }

                if (line.lineType == .blank) {
                    std.debug.assert(lineScanner.lineEnd != null);
                    std.debug.assert(boundedBlockStartInfo != null);

                    line.lineType = switch (boundedBlockStart.lineType) {
                        .codeBlockStart => .code,
                        .customBlockStart => .data,
                        else => unreachable,
                    };
                    line.prefixBlankEnd = lineStart;
                    suffixBlankStart = lineScanner.cursor;
                } else {
                    std.debug.assert(boundedBlockStartInfo == null);

                    std.debug.assert(line.lineType == .codeBlockEnd or
                        line.lineType == .customBlockEnd);
                }

                break :parse_line;
            } // atom code/custom block context

            // handle blank line.
            if (lineScanner.lineEnd) |_| {
                // For a blank line, all blanks belongs to the line-end token.
                line.prefixBlankEnd = lineStart;
                suffixBlankStart = lineStart;

                line.lineType = .blank;

                if (currentAtomBlock.blockType != .blank) {
                    const blankBlock = try parser.createAndPushBlockElement();
                    blankBlock.blockType = .{
                        .blank = .{
                            .startLine = line,
                        },
                    };
                    try blockArranger.stackAtomBlock(blankBlock, false);

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = blankBlock;
                    atomBlockCount += 1;
                }

                break :parse_line;
            }

            line.prefixBlankEnd = leadingBlankEnd;

            const lineStartIgnoreLeadingBlanks = lineScanner.cursor;
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
                        lineScanner.setCursor(lineStartIgnoreLeadingBlanks);
                        break :handle;
                    }

                    const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                        suffixBlankStart = markEnd;
                        break :blk markEnd;
                    } else lineScanner.cursor;

                    (try parser.createTokenForLine(line)).* = .{
                        .containerMark = .{
                            .start = @intCast(lineStartIgnoreLeadingBlanks),
                            .blankLen = @intCast(markEndWithSpaces - markEnd),
                            .more = .{
                                .markLen = @intCast(markEnd - lineStartIgnoreLeadingBlanks),
                            },
                        },
                    };

                    std.debug.assert(markEnd - leadingBlankEnd == 1 or markEnd - leadingBlankEnd == 2);
                    const markStr = tmdData[leadingBlankEnd..markEnd];
                    const markTypeIndex = tmd.listItemTypeIndex(markStr);
                    const createNewList = blockArranger.shouldCreateNewList(markTypeIndex);
                    const listBlock: ?*tmd.Block = if (createNewList) blk: {
                        const listBlock = try parser.createAndPushBlockElement();
                        listBlock.blockType = .{
                            .list = .{
                                ._itemTypeIndex = markTypeIndex,
                                .listType = tmd.listType(markStr), // if .bullets, might be adjusted to .tabs later
                                .secondMode = markStr.len == 2,
                                .index = listCount,
                            },
                        };
                        listCount += 1;
                        break :blk listBlock;
                    } else null;

                    const listItemBlock = try parser.createAndPushBlockElement();
                    listItemBlock.blockType = .{
                        .item = .{
                            //.isFirst = false, // will be modified eventually
                            //.isLast = false, // will be modified eventually
                            .list = undefined, // will be modified below in stackListItemBlock
                        },
                    };

                    try blockArranger.stackListItemBlock(listItemBlock, markTypeIndex, listBlock);
                },
                '#', '>', '!', '?', '.' => |mark| handle: {
                    lineScanner.advance(1);
                    const markEnd = lineScanner.cursor;
                    const numSpaces = lineScanner.readUntilNotBlank();
                    if (numSpaces == 0 and lineScanner.lineEnd == null) { // not container
                        lineScanner.setCursor(lineStartIgnoreLeadingBlanks);
                        break :handle;
                    }

                    const markEndWithSpaces = if (lineScanner.lineEnd) |_| blk: {
                        suffixBlankStart = markEnd;
                        break :blk markEnd;
                    } else lineScanner.cursor;

                    const containerBlock = try parser.createAndPushBlockElement();

                    switch (mark) {
                        '#' => {
                            containerBlock.blockType = .{
                                .table = .{},
                            };
                        },
                        '>' => {
                            containerBlock.blockType = .{
                                .quotation = .{},
                            };
                        },
                        '!' => {
                            containerBlock.blockType = .{
                                .notice = .{},
                            };
                        },
                        '?' => {
                            containerBlock.blockType = .{
                                .reveal = .{},
                            };
                        },
                        '.' => {
                            containerBlock.blockType = .{
                                .plain = .{},
                            };
                        },
                        else => unreachable,
                    }

                    (try parser.createTokenForLine(line)).* = .{
                        .containerMark = .{
                            .start = @intCast(lineStartIgnoreLeadingBlanks),
                            .blankLen = @intCast(markEndWithSpaces - markEnd),
                            .more = .{
                                .markLen = 1,
                            },
                        },
                    };

                    try blockArranger.stackContainerBlock(containerBlock);
                },
                else => {},
            }

            const hasContainerMark = line.containerMarkToken() != null;
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

                    line.lineType = .seperator;
                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(leadingBlankEnd),
                            .markLen = @intCast(markLen),
                            .blankLen = 0,
                        },
                    };

                    const lineBlock = try parser.createAndPushBlockElement();
                    lineBlock.blockType = .{
                        .seperator = .{
                            .startLine = line,
                        },
                    };
                    try blockArranger.stackAtomBlock(lineBlock, hasContainerMark);

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = lineBlock;
                    atomBlockCount += 1;

                    suffixBlankStart = contentEnd;
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
                        suffixBlankStart = playloadStart;
                    } else {
                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = playloadStart;
                        } else {
                            playloadStart = lineScanner.cursor;
                            const numTrailingBlanks = lineScanner.readUntilLineEnd();
                            suffixBlankStart = lineScanner.cursor - numTrailingBlanks;
                        }
                    }

                    if (isOpenMark) {
                        line.lineType = .baseBlockOpen;

                        const baseBlock = try parser.createAndPushBlockElement();
                        baseBlock.blockType = .{
                            .base = .{
                                .openLine = line,
                            },
                        };

                        //const playloadRange = baseBlock.blockType.base.openPlayloadRange();
                        const playloadRange = tmd.Range{ .start = playloadStart, .end = suffixBlankStart };
                        const playload = parser.tmdDoc.rangeData(playloadRange);
                        const attrs = AttributeParser.parse_base_block_open_playload(playload);
                        if (!std.meta.eql(attrs, .{})) {
                            var _baseBlockAttibutesElement = try list.createListElement(tmd.BaseBlockAttibutes, allocator);
                            parser.tmdDoc._baseBlockAttibutes.pushTail(_baseBlockAttibutesElement);
                            _baseBlockAttibutesElement.value = attrs;
                            //baseBlock.blockType.base.openLine.lineType.baseBlockOpen.attrs = &_baseBlockAttibutesElement.value;
                            (try parser.createTokenForLine(line)).* = .{
                                .extra = .{
                                    .info = .{
                                        .baseBlockAttrs = &_baseBlockAttibutesElement.value,
                                    },
                                },
                            };
                        }

                        try blockArranger.openBaseBlock(baseBlock, hasContainerMark, attrs.commentedOut);

                        try parser.setEndLineForAtomBlock(currentAtomBlock);
                        currentAtomBlock = baseBlock;
                        atomBlockCount += 1;
                    } else {
                        line.lineType = .baseBlockClose;

                        const baseBlock = try blockArranger.closeCurrentBaseBlock();
                        baseBlock.blockType.base.closeLine = line;

                        try parser.setEndLineForAtomBlock(currentAtomBlock);
                        currentAtomBlock = baseBlock;
                        atomBlockCount += 1;

                        (try parser.createTokenForLine(line)).* = .{
                            .extra = .{
                                .info = .{
                                    .blockRef = null, // might be changed later
                                },
                            },
                        };
                    }

                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(contentStart),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(playloadStart - contentStart - markLen),
                        },
                    };
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
                        suffixBlankStart = playloadStart;
                    } else {
                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = playloadStart;
                        } else {
                            playloadStart = lineScanner.cursor;
                            const numTrailingBlanks = lineScanner.readUntilLineEnd();
                            suffixBlankStart = lineScanner.cursor - numTrailingBlanks;
                        }
                    }

                    const atomBlock = if (mark == '\'') blk: {
                        line.lineType = .codeBlockStart;

                        const codeBlock = try parser.createAndPushBlockElement();
                        codeBlock.blockType = .{
                            .code = .{
                                .startLine = line,
                            },
                        };

                        //const playloadRange = codeBlock.blockType.code.startPlayloadRange();
                        const playloadRange = tmd.Range{ .start = playloadStart, .end = suffixBlankStart };
                        const playload = parser.tmdDoc.rangeData(playloadRange);
                        const attrs = AttributeParser.parse_code_block_open_playload(playload);
                        if (!std.meta.eql(attrs, .{})) {
                            var _codeBlockAttibutesElement = try list.createListElement(tmd.CodeBlockAttibutes, allocator);
                            parser.tmdDoc._codeBlockAttibutes.pushTail(_codeBlockAttibutesElement);
                            _codeBlockAttibutesElement.value = attrs;
                            //codeBlock.blockType.code.startLine.lineType.codeBlockStart.attrs = &_codeBlockAttibutesElement.value;
                            (try parser.createTokenForLine(line)).* = .{
                                .extra = .{
                                    .info = .{
                                        .codeBlockAttrs = &_codeBlockAttibutesElement.value,
                                    },
                                },
                            };
                        }

                        break :blk codeBlock;
                    } else blk: {
                        std.debug.assert(mark == '"');

                        line.lineType = .customBlockStart;

                        const customBlock = try parser.createAndPushBlockElement();
                        customBlock.blockType = .{
                            .custom = .{
                                .startLine = line,
                            },
                        };

                        //const playloadRange = customBlock.blockType.custom.startPlayloadRange();
                        const playloadRange = tmd.Range{ .start = playloadStart, .end = suffixBlankStart };
                        const playload = parser.tmdDoc.rangeData(playloadRange);
                        const attrs = AttributeParser.parse_custom_block_open_playload(playload);
                        if (!std.meta.eql(attrs, .{})) {
                            var _customBlockAttibutesElement = try list.createListElement(tmd.CustomBlockAttibutes, allocator);
                            parser.tmdDoc._customBlockAttibutes.pushTail(_customBlockAttibutesElement);
                            _customBlockAttibutesElement.value = attrs;
                            //customBlock.blockType.custom.startLine.lineType.customBlockStart.attrs = &_customBlockAttibutesElement.value;
                            (try parser.createTokenForLine(line)).* = .{
                                .extra = .{
                                    .info = .{
                                        .customBlockAttrs = &_customBlockAttibutesElement.value,
                                    },
                                },
                            };
                        }

                        break :blk customBlock;
                    };

                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(contentStart),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(playloadStart - contentStart - markLen),
                        },
                    };

                    boundedBlockStartInfo = .{
                        .lineType = line.lineType,
                        .markChar = mark,
                        .markLen = markLen,
                    };

                    try blockArranger.stackAtomBlock(atomBlock, hasContainerMark);

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = atomBlock;
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
                        suffixBlankStart = markEnd;
                    } else {
                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = markEnd;
                        }
                    }

                    line.lineType = .header;
                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(contentStart),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(lineScanner.cursor - markEnd),
                        },
                    };

                    const headerBlock = try parser.createAndPushBlockElement();
                    headerBlock.blockType = .{
                        .header = .{
                            .startLine = line,
                        },
                    };
                    if (isFirstLevel) {
                        try blockArranger.stackFirstLevelHeaderBlock(headerBlock, hasContainerMark);
                    } else {
                        try blockArranger.stackAtomBlock(headerBlock, hasContainerMark);
                    }

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = headerBlock;
                    atomBlockCount += 1;

                    if (blockArranger.shouldHeaderChildBeInTOC()) {
                        // Will use the info in setEndLineForAtomBlock.
                        // Note: whether or not headerBlock is empty can't be determined now.
                        parser.pendingTocHeaderBlock = headerBlock;
                    }

                    contentParser.on_new_atom_block(currentAtomBlock);

                    if (lineScanner.lineEnd != null) {
                        // suffixBlankStart has been determined.
                        // And no data for parsing tokens.
                        break :handle;
                    }

                    const contentEnd = try contentParser.parse_header_line_tokens(line, lineScanner.cursor);
                    suffixBlankStart = contentEnd;
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
                        suffixBlankStart = markEnd;
                    } else {
                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = markEnd;
                        }
                    }

                    line.lineType = .usual;
                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(contentStart),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(lineScanner.cursor - markEnd),
                        },
                    };

                    const usualBlock = try parser.createAndPushBlockElement();
                    usualBlock.blockType = .{
                        .usual = .{
                            .startLine = line,
                        },
                    };
                    const newAtomBlock = usualBlock;

                    try blockArranger.stackAtomBlock(newAtomBlock, hasContainerMark);

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = newAtomBlock;
                    atomBlockCount += 1;

                    contentParser.on_new_atom_block(currentAtomBlock);

                    if (lineScanner.lineEnd != null) {
                        // suffixBlankStart has been determined.
                        // And no data for parsing tokens.
                        break :handle;
                    }

                    const contentEnd = try contentParser.parse_usual_line_tokens(line, lineScanner.cursor, true);
                    suffixBlankStart = contentEnd;
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
                    // NOTE: if items can be specified IDs again in the future,
                    //       remember handle the cases they are used as footnotes.
                    //       (render their childrens as the footnotes).

                    var playloadStart = lineScanner.cursor;
                    if (lineScanner.lineEnd) |_| {
                        suffixBlankStart = playloadStart;
                    } else {
                        //if (line.containerMark) |m| {
                        //    if (m == .item and lineScanner.peekCursor() == '<') {
                        //        lineScanner.advance(1);
                        //        forBulletContainer = true;
                        //    }
                        //}

                        _ = lineScanner.readUntilNotBlank();
                        if (lineScanner.lineEnd) |_| {
                            suffixBlankStart = playloadStart;
                        } else {
                            playloadStart = lineScanner.cursor;
                        }
                    }

                    line.lineType = .attributes;
                    (try parser.createTokenForLine(line)).* = .{
                        .lineTypeMark = .{
                            .start = @intCast(contentStart),
                            .markLen = @intCast(markLen),
                            .blankLen = @intCast(playloadStart - contentStart - markLen),
                        },
                    };

                    if (hasContainerMark or currentAtomBlock.blockType != .attributes) {
                        // There might be some new blocks created in the current iteration.
                        const realOldLast = parser.lastBlock;

                        // ...
                        const commentBlock = try parser.createAndPushBlockElement();
                        commentBlock.blockType = .{
                            .attributes = .{
                                .startLine = line,
                            },
                        };

                        try blockArranger.stackAtomBlock(commentBlock, hasContainerMark);

                        try parser.setEndLineForAtomBlock(currentAtomBlock);
                        currentAtomBlock = commentBlock;
                        atomBlockCount += 1;

                        // !! important
                        try parser.tryToAttributeBlock(realOldLast);
                        oldLastBlock = parser.lastBlock;
                    }

                    contentParser.on_new_atom_block(currentAtomBlock);
                    //defer contentParser.on_new_atom_block(); // ToDo: might be unnecessary

                    if (lineScanner.lineEnd != null) {
                        // suffixBlankStart has been determined.
                        // And no data for parsing tokens.
                        break :handle;
                    }

                    const contentEnd = try contentParser.parse_attributes_line_tokens(line, lineScanner.cursor);

                    suffixBlankStart = contentEnd;
                    std.debug.assert(lineScanner.lineEnd != null);

                    //try parser.onNewAttributesLine(line, forBulletContainer);
                    try parser.onNewAttributesLine(line);
                },
                else => {},
            }

            // If line type is still not determined, then it is just a usual line.
            if (line.lineType == .blank) {
                line.lineType = .usual;

                if (hasContainerMark or
                    currentAtomBlock.blockType != .usual and currentAtomBlock.blockType != .header
                //and currentAtomBlock.blockType != .footer
                ) {
                    const usualBlock = try parser.createAndPushBlockElement();
                    usualBlock.blockType = .{
                        .usual = .{
                            .startLine = line,
                        },
                    };
                    try blockArranger.stackAtomBlock(usualBlock, hasContainerMark);

                    try parser.setEndLineForAtomBlock(currentAtomBlock);
                    currentAtomBlock = usualBlock;
                    atomBlockCount += 1;

                    contentParser.on_new_atom_block(currentAtomBlock);
                }

                if (lineScanner.lineEnd == null) {
                    const contentEnd = try contentParser.parse_usual_line_tokens(
                        line,
                        contentStart,
                        //currentAtomBlock.blockType != .header and
                        contentStart == lineScanner.cursor,
                    );
                    suffixBlankStart = contentEnd;
                    std.debug.assert(lineScanner.lineEnd != null);
                }
            }
        } // :parse_line

        if (lineScanner.lineEnd) |end| {
            line.endType = end;
            line.endAt = @intCast(lineScanner.cursor + end.len());
        } else unreachable;

        line._atomBlockIndex.set(atomBlockCount);
        line._index.set(lineScanner.cursorLineIndex);

        parser.tmdDoc.lines.pushTail(lineElement);
        parser.tmdDoc.lineCount += 1;

        if (oldLastBlock != parser.lastBlock) {
            try parser.tryToAttributeBlock(oldLastBlock);
        }
    }

    // Meaningful only for code snippet block (and popential later custom app block).
    try parser.setEndLineForAtomBlock(currentAtomBlock);

    // ToDo: remove this line. (Forget the reason.;( )
    contentParser.on_new_atom_block(currentAtomBlock); // try to determine line-end spacing for the last coment line.

    blockArranger.end();

    try parser.onParseEnd();
}
//};
