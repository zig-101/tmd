//! This module provides functions for parse tmd files (as tmd.Doc),
//! and functions for rendering (tmd.Doc) to HTML.

pub const parser = @import("tmd_parser.zig");
pub const render = @import("tmd_to_html.zig");
pub const tests = @import("tests.zig");

// The above two sub-namespaces and the following pub declartions
// in the current namespace are visible to the "tmd" module users.

const std = @import("std");
const builtin = @import("builtin");
const list = @import("list.zig");
const tree = @import("tree.zig");

pub const DocSize = u28; // max 256M (in practice, most TMD doc sizes < 1M)
pub const MaxDocSize: u32 = 1 << @bitSizeOf(DocSize) - 1;

pub const Doc = struct {
    data: []const u8,
    blocks: list.List(Block) = .{},
    lines: list.List(Line) = .{},

    tocHeaders: list.List(*Block) = .{},
    titleHeader: ?*Block = null,
    // User should use the headerLevelNeedAdjusted method instead.
    _headerLevelNeedAdjusted: [MaxHeaderLevel]bool = .{false} ** MaxHeaderLevel,

    blocksByID: BlockRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance

    // The followings are used to track allocations for destroying.
    // ToDo: prefix them with _?

    links: list.List(Link) = .{}, // ToDo: use Link.next
    _blockTreeNodes: list.List(BlockRedBlack.Node) = .{}, // ToDo: use SinglyLinkedList
    // It is in _blockTreeNodes when exists. So no need to destroy it solely in the end.
    _freeBlockTreeNodeElement: ?*list.Element(BlockRedBlack.Node) = null,
    _elementAttributes: list.List(ElementAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _baseBlockAttibutes: list.List(BaseBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _codeBlockAttibutes: list.List(CodeBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _customBlockAttibutes: list.List(CustomBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _contentStreamAttributes: list.List(ContentStreamAttributes) = .{}, // ToDo: use SinglyLinkedList

    const BlockRedBlack = tree.RedBlack(*Block, Block);

    pub fn getBlockByID(self: *const @This(), id: []const u8) ?*Block {
        var a = ElementAttibutes{
            .id = id,
        };
        var b = Block{
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

    info: *Token.LinkInfo,
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
    verticalAlign: enum {
        none,
        top,
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

pub const Block = struct {
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

    pub fn getStartLine(self: *const @This()) *Line {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.startLine;
                }
                unreachable;
            },
        };
    }

    pub fn setStartLine(self: *@This(), line: *Line) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.startLine = line;
                    return;
                }
                unreachable;
            },
        };
    }

    pub fn getEndLine(self: *const @This()) *Line {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.endLine;
                }
                unreachable;
            },
        };
    }

    pub fn setEndLine(self: *@This(), line: *Line) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.endLine = line;
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
    pub fn getFooterSibling(self: *const @This()) ?*Block {
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

    pub fn next(self: *const @This()) ?*Block {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*Block {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn firstChild(self: *const @This()) ?*const Block {
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

    pub fn nextSibling(self: *const @This()) ?*Block {
        return switch (self.blockType) {
            .root => null,
            .base => |base| blk: {
                const closeLine = base.closeLine orelse break :blk null;
                const nextBlock = closeLine.extraInfo().?.blockRef orelse break :blk null;
                // The assurence is necessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            .list => |itemList| blk: {
                std.debug.assert(itemList._lastItemConfirmed);
                break :blk itemList.lastBullet.blockType.item.nextSibling;
            },
            .item => |*item| if (item.ownerBlock() == item.list.blockType.list.lastBullet) null else item.nextSibling,
            inline .table, .quotation, .notice, .reveal, .plain => |container| blk: {
                const nextBlock = container.nextSibling orelse break :blk null;
                // ToDo: the assurence might be unnecessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            inline else => blk: {
                std.debug.assert(self.isAtom());
                if (self.blockType.ownerBlock().next()) |nextBlock| {
                    std.debug.assert(nextBlock.nestingDepth <= self.nestingDepth);
                    if (nextBlock.nestingDepth == self.nestingDepth)
                        break :blk nextBlock;
                }
                break :blk null;
            },
        };
    }

    // Note, for .base, it is a potential sibling.
    pub fn setNextSibling(self: *@This(), sibling: *Block) void {
        return switch (self.blockType) {
            .root => unreachable,
            .base => |base| {
                if (base.closeLine) |closeLine| {
                    if (closeLine.extraInfo()) |info| info.blockRef = sibling;
                }
            },
            .list => |itemList| {
                std.debug.assert(itemList._lastItemConfirmed);
                //itemList.lastBullet.blockType.item.nextSibling = sibling;
                unreachable; // .list.nextSibling is always set through its .lastItem.
            },
            inline .item, .table, .quotation, .notice, .reveal, .plain => |*container| {
                container.nextSibling = sibling;
            },
            else => {
                std.debug.assert(self.isAtom());
                // do nothing
            },
        };
    }

    pub fn getSpecialHeaderChild(self: *const @This(), tmdData: []const u8) ?*const Block {
        std.debug.assert(self.isContainer() or self.blockType == .base);
        var child = self.firstChild() orelse return null;
        while (true) {
            switch (child.blockType) {
                .attributes => {
                    child = if (child.nextSibling()) |sibling| sibling else break;
                    continue;
                },
                .header => |header| if (header.level(tmdData) == 1) return child else break,
                else => break,
            }
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

        list: *Block, // a .list
        nextSibling: ?*Block = null, // for .list.lastBullet, it is .list's sibling.

        const Container = void;

        pub fn isFirst(self: *const @This()) bool {
            return self.list.next().? == self.ownerBlock();
        }

        pub fn isLast(self: *const @This()) bool {
            return self.list.blockType.list.lastBullet == self.ownerBlock();
        }

        pub fn ownerBlock(self: *const @This()) *Block {
            const blockType: *BlockType = @alignCast(@fieldParentPtr("item", @constCast(self)));
            return blockType.ownerBlock();
        }
    },

    list: struct { // lists are implicitly formed.
        _lastItemConfirmed: bool = false, // for debug
        _itemTypeIndex: ListItemTypeIndex, // ToDo: can be saved, just need a little more computitation.

        listType: ListType,
        secondMode: bool, // for .bullets: unordered/ordered, for .definitions, one-line or not
        index: u32, // for debug purpose

        lastBullet: *Block = undefined,
        // nextSibling: ?*Block, // .lastBullet.nextSibling

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
        nextSibling: ?*Block = null,
    },
    quotation: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    notice: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    reveal: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    plain: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },

    // base context block

    root: struct {
        doc: *Doc,
    },

    base: struct {
        openLine: *Line,
        closeLine: ?*Line = null,
        // nextSibling: ?*Block, // openLine.baseNextSibling

        pub fn attributes(self: @This()) BaseBlockAttibutes {
            if (self.openLine.extraInfo()) |info| {
                if (info.baseBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
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
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    seperator: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    header: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;

        pub fn level(self: @This(), tmdData: []const u8) u8 {
            const headerLine = self.startLine;
            const start = headerLine.start(.trimContainerMark);
            const end = start + headerLine.firstNonContainerMarkToken().?.lineTypeMark.markLen;
            return headerLevel(tmdData[start..end]) orelse unreachable;
        }

        // An empty header is used to insert toc.
        pub fn isBare(self: @This()) bool {
            //return self.startLine == self.endLine and self.startLine.tokens().?.empty();
            return self.startLine == self.endLine and self.startLine.lineTypeMarkToken().?.next() == null;
        }
    },

    usual: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // ToDo: when false, no need to render.
        //       So a block with a singal ` will outout nothing.
        //       Maybe needless with .blankSpan.
        // hasContent: bool = false,

        // traits:
        const Atom = void;
    },

    attributes: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    code: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // Note: the block end tag line might be missing.
        //       The endLine might not be a .codeBlockEnd line.
        //       and it can be also of .code or .codeBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CodeBlockAttibutes {
            if (self.startLine.extraInfo()) |info| {
                if (info.codeBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
        }

        pub fn _contentStreamAttributes(self: @This()) ContentStreamAttributes {
            switch (self.endLine.lineType) {
                .codeBlockEnd => {
                    if (self.endLine.extraInfo()) |info| {
                        if (info.streamAttrs) |attrs| return attrs.*;
                    }
                },
                else => {},
            }
            return .{};
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
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // Note: the block end tag line might be missing.
        //       And the endLine might not be a .customBlockEnd line.
        //       It can be also of .data or .customBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CustomBlockAttibutes {
            if (self.startLine.extraInfo()) |info| {
                if (info.customBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
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

    pub fn ownerBlock(self: *const @This()) *Block {
        return @alignCast(@fieldParentPtr("blockType", @constCast(self)));
    }
};

fn voidOr(T: type) type {
    const ValueType = if (builtin.mode == .Debug) T else void;

    return struct {
        value: ValueType,

        pub fn get(self: @This()) T {
            if (builtin.mode != .Debug) return 0;
            return self.value;
        }

        pub fn set(self: *@This(), v: T) void {
            if (builtin.mode != .Debug) return;
            self.value = v;
        }
    };
}

fn identify(T: type) type {
    return struct {
        value: T,

        pub fn get(self: @This()) T {
            return self.value;
        }

        pub fn set(self: *@This(), v: T) void {
            self.value = v;
        }
    };
}

pub const Line = struct {
    pub const Type = enum(u4) {
        blank,
        usual,
        header,
        seperator,
        attributes,

        baseBlockOpen,
        baseBlockClose,

        codeBlockStart,
        codeBlockEnd,
        code,

        customBlockStart,
        customBlockEnd,
        data,
    };

    pub const EndType = enum(u2) {
        void, // doc end
        n, // \n
        rn, // \r\n

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self);
        }

        pub fn len(self: @This()) u2 {
            return switch (self) {
                .void => 0,
                .n => 1,
                .rn => 2,
            };
        }
    };

    index: voidOr(u32) = undefined, // one based (for debug purpose only) ToDo: voidOf(u32)
    atomBlockIndex: voidOr(u32) = undefined, // one based (for debug purpose only) ToDo: voidOf(u32)

    startAt: voidOr(DocSize) = undefined,

    // ToDo: it looks packing the following 6 fields doesn't reduce size at all.
    //       They use totally 91 bits, so 12 bytes (96 bits) are sufficient.
    //       But zig compiler will use 16 bytes for the packed struct anyway.
    //       Because the compiler always thinks the alignment of the packed struct is 16.
    //
    //       So maybe it is best to manually pack these fields.
    //       Use three u32 fields ...
    //       This can save 4 bytes.
    //       (Or use 3 packed structs instead? Each is composed of two origial fields.)

    // This is the end pos of the line end token.
    // It is also the start pos of the next line.
    endAt: DocSize = undefined,

    prefixBlankEnd: DocSize = undefined,
    suffixBlankStart: DocSize = undefined,

    endType: EndType = undefined,

    treatEndAsSpace: bool = false,

    lineType: Type = undefined,

    tokens: list.List(Token) = .{},

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self.lineType);
    }

    pub fn endTypeName(self: @This()) []const u8 {
        return @tagName(self.endType);
    }

    pub fn isAttributes(self: @This()) bool {
        return self.lineType == .attributes;
    }

    pub fn ownerListElement(self: *const @This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", @constCast(self)));
    }

    pub fn next(self: *const @This()) ?*Line {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*Line {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn hasContainerMark(self: *const @This()) bool {
        return if (self.tokens.head) |tokenElement| tokenElement.value == .containerMark else false;
    }

    pub fn firstNonContainerMarkToken(self: *const @This()) ?*Token {
        if (self.tokens.head) |tokenElement| {
            if (tokenElement.value != .containerMark) return &tokenElement.value;
            if (tokenElement.next) |nextElement| {
                return &nextElement.value;
            }
        }
        return null;
    }

    pub fn lineTypeMarkToken(self: *const @This()) ?*Token {
        if (self.firstNonContainerMarkToken()) |token| {
            if (token.* == .lineTypeMark) return token;
            if (token.* == .extra) {
                std.debug.assert(token.next().?.* == .lineTypeMark);
                return token.next().?;
            }
        }
        return null;
    }

    pub fn extraInfo(self: *const @This()) ?*Token.Extra.Info {
        if (self.firstNonContainerMarkToken()) |token| {
            if (token.* == .extra) {
                std.debug.assert(token.next().?.* == .lineTypeMark);
                return &token.extra.info;
            }
        }
        return null;
    }

    fn startPos(self: *const @This()) DocSize {
        if (builtin.mode == .Debug) return self.startAt.get();
        return if (self.prev()) |prevLine| prevLine.endAt else 0;
    }

    pub fn start(self: *const @This(), trimOption: enum { none, trimContainerMark, trimLeadingSpaces }) DocSize {
        switch (trimOption) {
            .none => return self.startPos(),
            .trimLeadingSpaces => return self.prefixBlankEnd,
            .trimContainerMark => {
                if (self.tokens.head) |tokenElement| {
                    switch (tokenElement.value) {
                        .containerMark => return tokenElement.value.end(),
                        else => {},
                    }
                }
                return self.prefixBlankEnd;
            },
        }
    }

    pub fn end(self: *const @This(), trimOption: enum { none, trimLineEnd, trimTrailingSpaces }) DocSize {
        return switch (trimOption) {
            .none => self.endAt,
            .trimLineEnd => self.endAt - self.endType.len(),
            .trimTrailingSpaces => self.suffixBlankStart,
        };
    }

    pub fn range(self: *const @This(), trimOtion: enum { none, trimLineEnd, trimSpaces }) Range {
        return switch (trimOtion) {
            .none => .{ .start = self.startPos(), .end = self.endAt },
            .trimLineEnd => .{ .start = self.startPos(), .end = self.endAt - self.endType.len() },
            .trimSpaces => .{ .start = self.prefixBlankEnd, .end = self.suffixBlankStart },
        };
    }

    // ToDo: to opotimize, don't let parser use this method to
    //       get playload data for parsing.
    pub fn playloadRange(self: *const @This()) Range {
        std.debug.print("======= 000\n", .{});
        switch (self.lineType) {
            inline .baseBlockOpen,
            .baseBlockClose,
            .codeBlockStart,
            .codeBlockEnd,
            .customBlockStart,
            .customBlockEnd,
            => {
                const playloadStart = self.lineTypeMarkToken().?.end();
                std.debug.assert(playloadStart <= self.suffixBlankStart);
                return Range{ .start = playloadStart, .end = self.suffixBlankStart };
            },
            else => unreachable,
        }
    }

    pub fn isBoundary(self: *const @This()) bool {
        return switch (self.lineType) {
            inline .baseBlockOpen, .baseBlockClose, .codeBlockStart, .codeBlockEnd, .customBlockStart, .customBlockEnd => true,
            else => false,
        };
    }
};

// Tokens consume most memory after a doc is parsed.
// So try to keep the size of TokenType small and use as few tokens as possible.
//
// Try to keep the size of each TokenType field <= (4 + 4 + NativeWordSize) bytes.
//
// It is possible to make size of TokenType be 8 on 32-bit systems? (By discarding
// the .start property of each TokenType).
//
// Now, even all the fields of a union type reserved enough bits for the union tag,
// the compiler will still use extra alignment bytes for the union tag.
// So the size of TokenType is 24 bytes now.
// Maybe future zig compiler will make optimization to reduce the size to 16 bytes.
//
// An unmature idea is to add an extra enum field which only use
// the reserved bits to emulate the union tag manually.
// I'm nore sure how safe this way is now.
//
//     tag: struct {
//        _: uN,
//        _type: enum(uM) { // M == 16*8 - N
//            content,
//            commentText,
//            ...
//        },
//     },
//     content: ...,
//     commentText: ...,

pub const Token = union(enum) {
    pub const PlainText = std.meta.FieldType(Token, .content);
    pub const CommentText = std.meta.FieldType(Token, .commentText);
    pub const EvenBackticks = std.meta.FieldType(Token, .evenBackticks);
    pub const SpanMark = std.meta.FieldType(Token, .spanMark);
    pub const LinkInfo = std.meta.FieldType(Token, .linkInfo);
    pub const LeadingSpanMark = std.meta.FieldType(Token, .leadingSpanMark);
    pub const ContainerMark = std.meta.FieldType(Token, .containerMark);
    pub const LineTypeMark = std.meta.FieldType(Token, .lineTypeMark);
    pub const Extra = std.meta.FieldType(Token, .extra);

    content: struct {
        start: DocSize,
        // The value should be the same as the start of the next token, or end of line.
        // But it is good to keep it here, to verify the this value is the same as ....
        end: DocSize,

        // Finally, the list will exclude the last one if
        // it is only used for self-defined URL.
        nextInLink: ?*Token = null,
    },
    commentText: struct {
        start: DocSize,
        // The value should be the same as the end of line.
        end: DocSize,

        inAttributesLine: bool, // ToDo: don't use commentText tokens for attributes lines.
    },
    // ToDo: follow a .media LineSpanMarkType.
    //mediaInfo: struct {
    //    attrs: *MediaAttributes,
    //},
    evenBackticks: struct {
        start: DocSize,
        pairCount: DocSize,
        secondary: bool,

        // `` means a void char.
        // ```` means (pairCount-1) non-collapsable spaces?
        // ^```` means pairCount ` chars.
    },
    spanMark: struct {
        // For a close mark, this might be the start of the attached blanks.
        // For a open mark, this might be the position of the secondary sign.
        start: DocSize,
        blankLen: DocSize, // blank char count after open-mark or before close-mark in a line.

        markType: SpanMarkType, // might
        markLen: u8, // without the secondary char

        more: packed struct {
            open: bool,
            secondary: bool = false,
            blankSpan: bool, // enclose no texts (contents or evenBackticks or treatEndAsSpace)

            inComment: bool, // for .linkInfo
            urlSourceSet: bool = false, // for .linkInfo
            urlConfirmed: bool = false, // for .linkInfo
            isFootnote: bool = false, // for .linkInfo
        },

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // A linkInfo token is always before an open .link SpanMarkType token.
    linkInfo: struct {
        info: packed union {
            // This is only used for link matching.
            firstPlainText: ?*Token, // null for a blank link span

            // This is a list, it is the head.
            // Surely, if urlConfirmed, it is the only one in the list.
            urlSourceText: ?*Token, // null for a blank link span
        },

        fn followingOpenLinkSpanMark(self: *const @This()) *SpanMark {
            const token: *const Token = @alignCast(@fieldParentPtr("linkInfo", self));
            const m = token.followingSpanMark();
            std.debug.assert(m.markType == .link and m.more.open == true);
            return m;
        }

        pub fn isFootnote(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.isFootnote;
        }

        pub fn setFootnote(self: *const @This(), is: bool) void {
            self.followingOpenLinkSpanMark().more.isFootnote = is;
        }

        pub fn inComment(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.inComment;
        }

        pub fn urlConfirmed(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.urlConfirmed;
        }

        pub fn urlSourceSet(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.urlSourceSet;
        }

        pub fn setSourceOfURL(self: *@This(), urlSource: ?*Token, confirmed: bool) void {
            std.debug.assert(!self.urlSourceSet());

            self.followingOpenLinkSpanMark().more.urlConfirmed = confirmed;
            self.info = .{
                .urlSourceText = urlSource,
            };

            self.followingOpenLinkSpanMark().more.urlSourceSet = true;
        }
    },
    leadingSpanMark: struct {
        start: DocSize,
        blankLen: DocSize, // blank char count after the mark.
        more: packed struct {
            markLen: u2, // ToDo: remove it? It must be 2 now.
            markType: LineSpanMarkType,

            // when isBare is false,
            // * for .media, the next token is a .content token.
            // * for .comment and .anchor, the next token is a .commentText token.
            isBare: bool = false,
        },

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    containerMark: struct {
        start: DocSize,
        blankLen: DocSize,
        more: packed struct {
            markLen: u2,
            //markType: ContainerType, // can be determined by the start char
        },
    },
    lineTypeMark: struct { // excluding container marks
        start: DocSize,
        blankLen: DocSize,
        markLen: DocSize,

        // For containing line with certain lien types,
        // an extra token is followed by this .lineTypeMark token.
    },
    extra: struct {
        pub const Info = std.meta.FieldType(@This(), .info);

        info: packed union {
            // followed by a .lineTypeMark token in a .baseBlockClose line
            blockRef: ?*Block,
            // followed by a .lineTypeMark token in a .baseBlockOpen line
            baseBlockAttrs: ?*BaseBlockAttibutes,
            // followed by a .lineTypeMark token in a .codeBlockStart line
            codeBlockAttrs: ?*CodeBlockAttibutes,
            // followed by a .lineTypeMark token in a .codeBlockEnd line
            streamAttrs: ?*ContentStreamAttributes,
            // followed by a .lineTypeMark token in a .customBlockStart line
            customBlockAttrs: ?*CustomBlockAttibutes,
        },
    },

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }

    pub fn range(self: *const @This()) Range {
        return .{ .start = self.start(), .end = self.end() };
    }

    pub fn start(self: *const @This()) DocSize {
        switch (self.*) {
            .linkInfo => {
                if (self.next()) |nextToken| {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(nextToken.* == .spanMark);
                        const m = nextToken.spanMark;
                        std.debug.assert(m.markType == .link and m.more.open == true);
                    }
                    return nextToken.start();
                } else unreachable;
            },
            .extra => {
                if (self.next()) |nextToken| {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(nextToken.* == .lineTypeMark);
                    }
                    return nextToken.start();
                } else unreachable;
            },
            inline else => |token| {
                return token.start;
            },
        }
    }

    pub fn end(self: *const @This()) DocSize {
        switch (self.*) {
            .commentText => |t| {
                return t.end;
            },
            .content => |t| {
                return t.end;
            },
            .evenBackticks => |s| {
                var e = self.start() + (s.pairCount << 1);
                if (s.secondary) e += 1;
                return e;
            },
            .spanMark => |m| {
                var e = self.start() + m.markLen + m.blankLen;
                if (m.more.secondary) e += 1;
                return e;
            },
            .linkInfo, .extra => {
                return self.start();
            },
            inline .leadingSpanMark, .containerMark => |m| {
                return self.start() + m.more.markLen + m.blankLen;
            },
            .lineTypeMark => |m| {
                return self.start() + m.markLen + m.blankLen;
            },
        }
    }

    // Debug purpose. Used to verify end() == end2(line).
    pub fn end2(self: *@This(), _: *Line) DocSize {
        if (self.next()) |nextToken| {
            return nextToken.start();
        }
        // The old implementation.
        // ToDo: now, the assumption is false for some lines with playload.
        // return line.suffixBlankStart;
        // The current temp implementation.
        return self.end();
    }

    // ToDo: if self is const, return const. Possible?
    pub fn next(self: *const @This()) ?*Token {
        const tokenElement: *const list.Element(Token) = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.next) |te| {
            return &te.value;
        }
        return null;
    }

    pub fn prev(self: *const @This()) ?*Token {
        const tokenElement: *const list.Element(Token) = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.prev) |te| {
            return &te.value;
        }
        return null;
    }

    fn followingSpanMark(self: *const @This()) *SpanMark {
        if (self.next()) |nextToken| {
            switch (nextToken.*) {
                .spanMark => |*m| {
                    return m;
                },
                else => unreachable,
            }
        } else unreachable;
    }
};

pub const SpanMarkType = enum(u4) {
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
pub const LineSpanMarkType = enum(u3) {
    lineBreak, // \\
    comment, // //
    media, // &&
    escape, // !!
    spoiler, // ??
};