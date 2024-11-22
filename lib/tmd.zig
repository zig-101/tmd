//! This module provides functions for parse tmd files (as tmd.Doc),
//! and functions for rendering (tmd.Doc) to HTML.

pub const parser = @import("tmd_parser.zig");
pub const render = @import("tmd_to_html.zig");

// The above two sub-namespaces and the following pub declartions
// in the current namespace are visible to the "tmd" module users.

const std = @import("std");
const builtin = @import("builtin");
const list = @import("list.zig");
const tree = @import("tree.zig");

pub const BlockInfoRedBlack = tree.RedBlack(*BlockInfo, BlockInfo);

pub const Doc = struct {
    data: []const u8,
    blocks: list.List(BlockInfo) = .{}, // ToDo: use SinglyLinkedList
    lines: list.List(LineInfo) = .{}, // ToDo: use SinglyLinkedList

    tocHeaders: list.List(*BlockInfo) = .{},
    titleHeader: ?*BlockInfo = null,
    // User should use the headerLevelNeedAdjusted method instead.
    _headerLevelNeedAdjusted: [MaxHeaderLevel]bool = .{false} ** MaxHeaderLevel,

    blocksByID: BlockInfoRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance

    // The followings are used to track allocations for destroying.
    // ToDo: prefix them with _?

    links: list.List(Link) = .{}, // ToDo: use SinglyLinkedList
    blockTreeNodes: list.List(BlockInfoRedBlack.Node) = .{}, // ToDo: use SinglyLinkedList
    // It is in blockTreeNodes when exists. So no need to destroy it solely in the end.
    freeBlockTreeNodeElement: ?*list.Element(BlockInfoRedBlack.Node) = null, // ToDo: use SinglyLinkedList
    elementAttributes: list.List(ElementAttibutes) = .{}, // ToDo: use SinglyLinkedList
    baseBlockAttibutes: list.List(BaseBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    codeBlockAttibutes: list.List(CodeBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    customBlockAttibutes: list.List(CustomBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    contentStreamAttributes: list.List(ContentStreamAttributes) = .{}, // ToDo: use SinglyLinkedList

    pub fn getBlockByID(self: *const @This(), id: []const u8) ?*BlockInfo {
        var a = ElementAttibutes{
            .id = id,
        };
        var b = BlockInfo{
            .blockType = undefined,
            .attributes = &a,
        };

        return if (self.blocksByID.search(&b)) |node| node.value else null;
    }

    pub fn rangeData(self: *const @This(), r: Range) []const u8 {
        return self.data[r.start..r.end];
    }

    pub fn headerLevelNeedAdjusted(self: *const @This(), level: u8) bool {
        std.debug.assert(1 <= level and level <= MaxHeaderLevel);
        return self._headerLevelNeedAdjusted[level - 1];
    }
};

pub const Range = struct {
    start: u32,
    end: u32,
};

// ToDo: u8 -> usize?
pub const MaxHeaderLevel: u8 = 4;
pub fn headerLevel(headeMark: []const u8) ?u8 {
    if (headeMark.len < 2) return null;
    if (headeMark[0] != '#' or headeMark[1] != '#') return null;
    if (headeMark.len == 2) return 1;
    return switch (headeMark[headeMark.len - 1]) {
        '#' => 1,
        '=' => 2,
        '+' => 3,
        '-' => 4,
        else => null,
    };
}

pub const MaxSpanMarkLength = 8; // not inclusive. And not include ^.

// Note: the two should be consistent.
pub const MaxListNestingDepthPerBase = 11;
pub const ListItemTypeIndex = u4;
pub const ListNestingDepthType = u8; // in fact, u4 is enough now

pub fn listItemTypeIndex(itemMark: []const u8) ListItemTypeIndex {
    switch (itemMark.len) {
        1, 2 => {
            var index: ListItemTypeIndex = switch (itemMark[0]) {
                '+' => 0,
                '-' => 1,
                '*' => 2,
                '~' => 3,
                ':' => 4,
                '=' => 5,
                else => unreachable,
            };

            if (itemMark.len == 1) {
                return index;
            }

            if (itemMark[1] != '.') unreachable;
            index += 6;

            return index;
        },
        else => unreachable,
    }
}

// When this function is called, .tabs is still unable to be determined.
pub fn listType(itemMark: []const u8) ListType {
    switch (itemMark.len) {
        1, 2 => return switch (itemMark[0]) {
            '+', '-', '*', '~' => .bullets,
            ':' => .definitions,
            else => unreachable,
        },
        else => unreachable,
    }
}

pub const ElementAttibutes = struct {
    id: []const u8 = "", // ToDo: should be a Range?
    classes: []const u8 = "", // ToDo: should be Range list?
    kvs: []const u8 = "", // ToDo: should be Range list?

    pub fn isForFootnote(self: *const @This()) bool {
        return self.id.len > 0 and self.id[0] == '^';
    }
};

pub const Link = struct {
    // ToDo: use pointer? Memory will be more fragmental.
    // ToDo: now this field is never set.
    // attrs: ElementAttibutes = .{},

    info: *LinkInfo,
};

pub const BaseBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
    horizontalAlign: enum {
        none,
        left,
        center,
        right,
        justify,
    } = .none,
    cellSpans: struct {
        axisSpan: u32 = 1,
        crossSpan: u32 = 1,
    } = .{},
};

pub const CodeBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
    language: []const u8 = "", // ToDo: use Range
    // ToDo
    // startLineNumber: u32 = 0, // ++n 0 means not show line numbers
    // filepath: []const u8 = "", // @@path
};

pub const ContentStreamAttributes = struct {
    content: []const u8 = "", // ToDo: use Range
};

pub const CustomBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
    app: []const u8 = "", // ToDo: use Range
    arguments: []const u8 = "", // ToDo: use Range
    // The argument is the content in the following custom block.
    // It might be a file path.
};

pub const MediaAttributes = struct {
    // ToDo: ...
};

// Note: keep the two consistent.
pub const MaxBlockNestingDepth = 64; // should be 2^N
pub const BlockNestingDepthType = u6; // must be capable of storing MaxBlockNestingDepth-1

pub const BlockInfo = struct {
    index: u32 = undefined, // one basedd (for debug purpose only)
    nestingDepth: u32 = 0,

    blockType: BlockType,

    attributes: ?*ElementAttibutes = null,

    hasNonMediaTokens: bool = false, // for certain atom blocks only (only .usual? ToDo: not only)

    pub fn typeName(self: *const @This()) []const u8 {
        return @tagName(self.blockType);
    }

    // for atom blocks

    pub fn isContainer(self: *const @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Container"),
        };
    }

    pub fn isAtom(self: *const @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Atom"),
        };
    }

    pub fn getStartLine(self: *const @This()) *LineInfo {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.startLine;
                }
                unreachable;
            },
        };
    }

    pub fn setStartLine(self: *@This(), lineInfo: *LineInfo) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.startLine = lineInfo;
                    return;
                }
                unreachable;
            },
        };
    }

    pub fn getEndLine(self: *const @This()) *LineInfo {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.endLine;
                }
                unreachable;
            },
        };
    }

    pub fn setEndLine(self: *@This(), lineInfo: *LineInfo) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.endLine = lineInfo;
                    return;
                }
                unreachable;
            },
        };
    }

    pub fn compare(x: *const @This(), y: *const @This()) isize {
        const xAttributes = x.attributes orelse unreachable;
        const yAttributes = y.attributes orelse unreachable;
        const xID = if (xAttributes.id.len > 0) xAttributes.id else unreachable;
        const yID = if (yAttributes.id.len > 0) yAttributes.id else unreachable;
        return switch (std.mem.order(u8, xID, yID)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    // Only atom blocks and base blocks can call this method.
    pub fn getFooterSibling(self: *const @This()) ?*BlockInfo {
        //if (self.isContainer()) unreachable;
        if (self.isContainer()) return null;

        if (self.nextSibling()) |sibling| {
            if (sibling.blockType == .attributes) {
                if (sibling.nextSibling() == null)
                    return sibling;
            }
        }

        return null;
    }

    pub fn ownerListElement(self: *const @This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", @constCast(self)));
    }

    pub fn next(self: *const @This()) ?*BlockInfo {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*BlockInfo {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn firstChild(self: *const @This()) ?*const BlockInfo {
        switch (self.blockType) {
            .root, .base => if (self.next()) |nextBlock| {
                if (nextBlock.nestingDepth > self.nestingDepth) return nextBlock;
            },
            else => {
                if (self.isContainer()) return self.next().?;
            },
        }

        return null;
    }

    pub fn nextSibling(self: *const @This()) ?*BlockInfo {
        return switch (self.blockType) {
            .root => null,
            .base => |base| blk: {
                const closeLine = base.closeLine orelse break :blk null;
                const nextBlock = closeLine.lineType.baseBlockClose.baseNextSibling orelse break :blk null;
                // The assurence is necessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            .list => |itemList| blk: {
                std.debug.assert(itemList._lastItemConfirmed);
                break :blk itemList.lastBullet.blockType.item.nextSibling;
            },
            .item => |*item| if (item.ownerBlockInfo() == item.list.blockType.list.lastBullet) null else item.nextSibling,
            inline .table, .quotation, .notice, .reveal, .unstyled => |container| blk: {
                const nextBlock = container.nextSibling orelse break :blk null;
                // ToDo: the assurence might be unnecessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            inline else => blk: {
                std.debug.assert(self.isAtom());
                if (self.blockType.ownerBlockInfo().next()) |nextBlock| {
                    std.debug.assert(nextBlock.nestingDepth <= self.nestingDepth);
                    if (nextBlock.nestingDepth == self.nestingDepth)
                        break :blk nextBlock;
                }
                break :blk null;
            },
        };
    }

    pub fn setNextSibling(self: *@This(), sibling: *BlockInfo) void {
        return switch (self.blockType) {
            .root => unreachable,
            .base => |base| {
                if (base.closeLine) |closeLine|
                    closeLine.lineType.baseBlockClose.baseNextSibling = sibling;
            },
            .list => |itemList| {
                std.debug.assert(itemList._lastItemConfirmed);
                //itemList.lastBullet.blockType.item.nextSibling = sibling;
                unreachable; // .list.nextSibling is always set through its .lastItem.
            },
            inline .item, .table, .quotation, .notice, .reveal, .unstyled => |*container| {
                container.nextSibling = sibling;
            },
            else => {
                std.debug.assert(self.isAtom());
                // do nothing
            },
        };
    }

    pub fn getSpecialHeaderChild(self: *const @This(), tmdData: []const u8) ?*const BlockInfo {
        std.debug.assert(self.isContainer() or self.blockType == .base);

        var child = self.firstChild() orelse return null;
        while (true) {
            switch (child.blockType) {
                .attributes => continue,
                .header => |header| if (header.level(tmdData) == 1) return child else break,
                else => break,
            }
            child = if (self.next()) |nextBlock| nextBlock else break;
        }
        return null;
    }
};

pub const ListType = enum {
    bullets,
    tabs,
    definitions,
};

pub const BlockType = union(enum) {
    // container block types

    // ToDo: add .firstBlock and .lastBlock fileds for container blocks?

    item: struct {
        //isFirst: bool, // ToDo: can be saved
        //isLast: bool, // ToDo: can be saved (need .list.lastItem)

        list: *BlockInfo, // a .list
        nextSibling: ?*BlockInfo = null, // for .list.lastBullet, it is .list's sibling.

        const Container = void;

        pub fn isFirst(self: *const @This()) bool {
            return self.list.next().? == self.ownerBlockInfo();
        }

        pub fn isLast(self: *const @This()) bool {
            return self.list.blockType.list.lastBullet == self.ownerBlockInfo();
        }

        pub fn ownerBlockInfo(self: *const @This()) *BlockInfo {
            const blockType: *BlockType = @alignCast(@fieldParentPtr("item", @constCast(self)));
            return blockType.ownerBlockInfo();
        }
    },

    list: struct { // lists are implicitly formed.
        _lastItemConfirmed: bool = false, // for debug
        _itemTypeIndex: ListItemTypeIndex, // ToDo: can be saved, just need a little more computitation.

        listType: ListType,
        secondMode: bool, // for .bullets: unordered/ordered, for .definitions, one-line or not
        index: u32, // for debug purpose

        lastBullet: *BlockInfo = undefined,
        // nextSibling: ?*BlockInfo, // .lastBullet.nextSibling

        // Note: the depth of the list is the same as its children

        const Container = void;

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.listType);
        }

        //pub fn bulletType(self: @This()) BulletType {
        //    if (self._itemTypeIndex & 0b100 != 0) return .ordered;
        //    return .unordered;
        //}
    },

    table: struct {
        const Container = void;
        nextSibling: ?*BlockInfo = null,
    },
    quotation: struct {
        const Container = void;
        nextSibling: ?*BlockInfo = null,
    },
    notice: struct {
        const Container = void;
        nextSibling: ?*BlockInfo = null,
    },
    reveal: struct {
        const Container = void;
        nextSibling: ?*BlockInfo = null,
    },
    unstyled: struct {
        const Container = void;
        nextSibling: ?*BlockInfo = null,
    },

    // base context block

    root: struct {
        doc: *Doc,
    },

    base: struct {
        openLine: *LineInfo,
        closeLine: ?*LineInfo = null,
        // nextSibling: ?*BlockInfo, // openLine.baseNextSibling

        pub fn attributes(self: @This()) BaseBlockAttibutes {
            return if (self.openLine.lineType.baseBlockOpen.attrs) |attrs| attrs.* else .{};
        }

        pub fn openPlayloadRange(self: @This()) Range {
            return self.openLine.playloadRange();
        }

        pub fn closePlayloadRange(self: @This()) ?Range {
            return if (self.closeLine) |closeLine| closeLine.playloadRange() else null;
        }
    },

    // atom block types

    blank: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;
    },

    seperator: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;
    },

    header: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;

        pub fn level(self: @This(), tmdData: []const u8) u8 {
            const headerLine = self.startLine;
            const start = headerLine.containerMarkEnd();
            const end = start + headerLine.lineType.header.markLen;
            return headerLevel(tmdData[start..end]) orelse unreachable;
        }

        // An empty header is used to insert toc.
        pub fn isBare(self: @This()) bool {
            return self.startLine == self.endLine and self.startLine.tokens().?.empty();
        }
    },

    usual: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // ToDo: when false, no need to render.
        //       So a block with a singal ` will outout nothing.
        //       Maybe needless with .blankSpan.
        // hasContent: bool = false,

        // traits:
        const Atom = void;
    },

    attributes: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;
    },

    code: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // Note: the block end tag line might be missing.
        //       The endLine might not be a .codeBlockEnd line.
        //       and it can be also of .code or .codeBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CodeBlockAttibutes {
            return if (self.startLine.lineType.codeBlockStart.attrs) |attrs| attrs.* else .{};
        }

        pub fn contentStreamAttributes(self: @This()) ContentStreamAttributes {
            return switch (self.endLine.lineType) {
                .codeBlockEnd => |end| if (end.streamAttrs) |attrs| attrs.* else .{},
                else => .{},
            };
        }

        pub fn startPlayloadRange(self: @This()) Range {
            return self.startLine.playloadRange();
        }

        pub fn endPlayloadRange(self: @This()) ?Range {
            return switch (self.endLine.lineType) {
                .codeBlockEnd => |_| self.endLine.playloadRange(),
                else => null,
            };
        }
    },

    custom: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // Note: the block end tag line might be missing.
        //       And the endLine might not be a .customBlockEnd line.
        //       It can be also of .data or .customBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CustomBlockAttibutes {
            return if (self.startLine.lineType.customBlockStart.attrs) |attrs| attrs.* else .{};
        }

        pub fn startPlayloadRange(self: @This()) Range {
            return self.startLine.playloadRange();
        }

        pub fn endPlayloadRange(self: @This()) ?Range {
            return switch (self.endLine.lineType) {
                .customBlockEnd => |_| self.endLine.playloadRange(),
                else => null,
            };
        }
    },

    pub fn ownerBlockInfo(self: *const @This()) *BlockInfo {
        return @alignCast(@fieldParentPtr("blockType", @constCast(self)));
    }
};

pub const LineInfo = struct {
    index: u32, // one basedd (for debug purpose only)
    atomBlockIndex: u32, // one based (for debug purpose only)

    range: Range,
    rangeTrimmed: Range, // without leanding and traling blanks (except .code lines)

    endType: LineEndType,

    treatEndAsSpace: bool = false,

    // ...
    containerMark: ?ContainerLeadingMark, // !!! remember init it after alloc
    lineType: LineType, // ToDo: renamed to lineType

    pub fn number(self: @This()) usize {
        return @intCast(self.index); // + 1;
    }

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self.lineType);
    }

    pub fn endTypeName(self: @This()) []const u8 {
        return @tagName(self.endType);
    }

    pub fn isAttributes(self: @This()) bool {
        return switch (self.lineType) {
            .attributes => true,
            else => false,
        };
    }

    pub fn containerMarkEnd(self: @This()) u32 {
        return if (self.containerMark) |containerMark| blk: {
            switch (containerMark) {
                inline else => |m| break :blk m.markEndWithSpaces,
            }
        } else blk: {
            break :blk self.rangeTrimmed.start;
        };
    }

    pub fn tokens(self: *@This()) ?*list.List(TokenInfo) {
        return switch (self.lineType) {
            inline else => |*lt| {
                if (@hasField(@TypeOf(lt.*), "tokens")) {
                    return &lt.tokens;
                }
                return null;
            },
        };
    }

    pub fn ownerListElement(self: *const @This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", @constCast(self)));
    }

    pub fn next(self: *const @This()) ?*LineInfo {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*LineInfo {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn start(self: *const @This(), trimContainerMark: bool, trimLeadingSpaces: bool) u32 {
        if (trimContainerMark) {
            if (self.containerMark) |mark| switch (mark) {
                inline else => |m| {
                    return m.markEndWithSpaces;
                },
            };
        }
        return if (trimLeadingSpaces) self.rangeTrimmed.start else self.range.start;
    }

    pub fn end(self: *const @This(), trimmTrailingSpaces: bool) u32 {
        return if (trimmTrailingSpaces) self.rangeTrimmed.end else self.range.end;
    }

    // ToDo: to opotimize, don't let parser use this method to
    //       get playload data for parsing.
    pub fn playloadRange(self: @This()) Range {
        return switch (self.lineType) {
            inline .baseBlockOpen,
            .baseBlockClose,
            .codeBlockStart,
            .codeBlockEnd,
            .customBlockStart,
            .customBlockEnd,
            => |lineType| blk: {
                std.debug.assert(lineType.markEndWithSpaces <= self.rangeTrimmed.end);
                break :blk Range{ .start = lineType.markEndWithSpaces, .end = self.rangeTrimmed.end };
            },
            else => unreachable,
        };
    }

    pub fn isBoundary(self: @This()) bool {
        return switch (self.lineType) {
            inline .baseBlockOpen, .baseBlockClose, .codeBlockStart, .codeBlockEnd, .customBlockStart, .customBlockEnd => true,
            else => false,
        };
    }
};

pub const LineEndType = enum {
    void, // doc end
    n, // \n
    rn, // \r\n

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }

    pub fn len(self: @This()) u32 {
        return switch (self) {
            .void => 0,
            .n => 1,
            .rn => 2,
        };
    }
};

// ToDo: use an enum filed + common fileds.
//       And use u30 for cursor values.
pub const ContainerLeadingMark = union(enum) {
    item: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    table: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    quotation: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    notice: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    reveal: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    unstyled: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }
};

pub const LineType = union(enum) {
    blank: struct {},
    usual: struct {
        // A usual line might start with 3+ semicolon or nothing.
        // So either markLen == 0, or markLen >= 3
        markLen: u32,
        markEndWithSpaces: u32,
        tokens: list.List(TokenInfo) = .{},
    },
    header: struct {
        markLen: u32,
        markEndWithSpaces: u32,
        tokens: list.List(TokenInfo) = .{},
    },
    seperator: struct {
        markLen: u32,
    },

    baseBlockOpen: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        attrs: ?*BaseBlockAttibutes = null, // ToDo
    },
    baseBlockClose: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        baseNextSibling: ?*BlockInfo = null,
    },

    codeBlockStart: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        attrs: ?*CodeBlockAttibutes = null, // ToDo
    },
    codeBlockEnd: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        streamAttrs: ?*ContentStreamAttributes = null, // ToDo
    },
    code: struct {},

    customBlockStart: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        attrs: ?*CustomBlockAttibutes = null, // ToDo
    },
    customBlockEnd: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },
    data: struct {},

    attributes: struct {
        markLen: u32,
        markEndWithSpaces: u32,
        tokens: list.List(TokenInfo) = .{},
    },
};

pub const TokenInfo = struct {
    tokenType: TokenType,

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self.tokenType);
    }

    pub fn range(self: *const @This()) Range {
        return .{ .start = self.start(), .end = self.end() };
    }

    pub fn start(self: *const @This()) u32 {
        switch (self.tokenType) {
            .linkInfo => {
                if (self.next()) |nextTokenInfo| {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(nextTokenInfo.tokenType == .spanMark);
                        const m = nextTokenInfo.tokenType.spanMark;
                        std.debug.assert(m.markType == .link and m.open == true);
                    }
                    return nextTokenInfo.start();
                } else unreachable;
            },
            inline else => |token| {
                return token.start;
            },
        }
    }

    pub fn end(self: *const @This()) u32 {
        switch (self.tokenType) {
            .commentText => |t| {
                return t.end;
            },
            .plainText => |t| {
                return t.end;
            },
            .evenBackticks => |s| {
                var e = self.start() + (s.pairCount << 1);
                if (s.secondary) e += 1;
                return e;
            },
            .spanMark => |m| {
                var e = self.start() + m.markLen + m.blankLen;
                if (m.secondary) e += 1;
                return e;
            },
            .linkInfo => {
                return self.start();
            },
            .leadingMark => |m| {
                return self.start() + m.markLen + m.blankLen;
            },
        }
    }

    // Used to verify end() == end2(lineInfo).
    pub fn end2(self: *@This(), lineInfo: *LineInfo) u32 {
        if (self.next()) |nextTokenInfo| {
            return nextTokenInfo.start();
        }
        return lineInfo.rangeTrimmed.end;
    }

    // ToDo: if self is const, return const. Possible?
    fn next(self: *const @This()) ?*TokenInfo {
        const tokenElement: *const list.Element(TokenInfo) = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.next) |te| {
            return &te.value;
        }
        return null;
    }

    fn followingSpanMark(self: *const @This()) *SpanMark {
        if (self.next()) |nextTokenInfo| {
            switch (nextTokenInfo.tokenType) {
                .spanMark => |*m| {
                    return m;
                },
                else => unreachable,
            }
        } else unreachable;
    }
};

pub const PlainText = std.meta.FieldType(TokenType, .plainText);
pub const CommentText = std.meta.FieldType(TokenType, .commentText);
pub const DummyCodeSpans = std.meta.FieldType(TokenType, .evenBackticks);
pub const SpanMark = std.meta.FieldType(TokenType, .spanMark);
pub const LeadingMark = std.meta.FieldType(TokenType, .leadingMark);
pub const LinkInfo = std.meta.FieldType(TokenType, .linkInfo);

pub const TokenType = union(enum) {

    // Try to keep each field size <= (32 + 32 + 64) bits.

    // ToDo: lineEndSpace (merged into plainText. .start == .end means lineEndSpace)
    plainText: packed struct {
        start: u32,
        // The value should be the same as the start of the next token, or end of line.
        // But it is good to keep it here, to verify the this value is the same as ....
        end: u32,

        // Finally, the list will exclude the last one if
        // it is only used for self-defined URL.
        nextInLink: ?*TokenInfo = null,
    },
    commentText: packed struct {
        start: u32,
        // The value should be the same as the end of line.
        end: u32,

        inAttributesLine: bool, // ToDo: don't use commentText tokens for attributes lines.
    },
    evenBackticks: packed struct {
        start: u32,
        pairCount: u32,
        secondary: bool,

        // `` means a void char.
        // ```` means (pairCount-1) non-collapsable spaces?
        // ^```` means pairCount ` chars.
    },
    spanMark: packed struct {
        // For a close mark, this might be the start of the attached blanks.
        // For a open mark, this might be the position of the secondary sign.
        start: u32,
        blankLen: u32, // blank char count after open-mark or before close-mark in a line.

        open: bool,
        secondary: bool = false,
        markType: SpanMarkType, // might
        markLen: u8, // without the secondary char
        blankSpan: bool, // enclose no texts (plainTexts or treatEndAsSpace)

        inComment: bool, // for .linkInfo
        urlConfirmed: bool = false, // for .linkInfo
        isFootnote: bool = false, // for .linkInfo

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // ToDo: with the zig tip, this size of this type is 24.
    //       In fact, 16 is enough.
    // A linkInfo token is always before an open .link SpanMarkType token.
    linkInfo: struct {
        attrs: ?*ElementAttibutes = null,
        info: union(enum) {
            // This is only used for link matching.
            firstPlainText: ?*TokenInfo, // null for a blank link span

            // This is a list, it is the head.
            // Surely, if urlConfirmed, it is the only one in the list.
            urlSourceText: ?*TokenInfo, // null for a blank link span
        },

        fn followingOpenLinkSpanMark(self: *const @This()) *SpanMark {
            const tokenType: *const TokenType = @alignCast(@fieldParentPtr("linkInfo", self));
            const tokenInfo: *const TokenInfo = @alignCast(@fieldParentPtr("tokenType", tokenType));
            const m = tokenInfo.followingSpanMark();
            std.debug.assert(m.markType == .link and m.open == true);
            return m;
        }

        pub fn isFootnote(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().isFootnote;
        }

        pub fn setFootnote(self: *const @This(), is: bool) void {
            self.followingOpenLinkSpanMark().isFootnote = is;
        }

        pub fn inComment(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().inComment;
        }

        pub fn urlConfirmed(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().urlConfirmed;
        }

        pub fn setSourceOfURL(self: *@This(), urlSource: ?*TokenInfo, confirmed: bool) void {
            std.debug.assert(self.info != .urlSourceText);

            self.info = .{
                .urlSourceText = urlSource,
            };

            self.followingOpenLinkSpanMark().urlConfirmed = confirmed;
        }
    },
    leadingMark: packed struct {
        start: u32,
        blankLen: u32, // blank char count after the mark.
        markType: LineSpanMarkType,
        markLen: u32,

        // when isBare is false,
        // * for .media, the next token is a .plainText token.
        // * for .comment and .anchor, the next token is a .commentText token.
        isBare: bool = false,

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // ToDo: follow a .media LineSpanMarkType.
    //mediaInfo: struct {
    //    attrs: *MediaAttributes,
    //},

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }
};

pub const SpanMarkType = enum(u8) {
    link,
    fontWeight,
    fontStyle,
    fontSize,
    deleted,
    marked,
    supsub,
    code, // must be the last one (why? forget the reason)

    pub const MarkCount = @typeInfo(@This()).@"enum".fields.len;

    pub fn asInt(self: @This()) u8 {
        return @intFromEnum(self);
    }

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }
};

// used in usual blocks:
pub const LineSpanMarkType = enum(u8) {
    lineBreak, // \\
    comment, // //
    media, // @@
    escape, // !!
    spoiler, // ??
};
