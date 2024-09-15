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

    blockAttributes: list.List(BlockAttibutes) = .{}, // ToDo: use SinglyLinkedList

    blocksByID: BlockInfoRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance
    blockTreeNodes: list.List(BlockInfoRedBlack.Node) = .{}, // ToDo: use SinglyLinkedList
    // It is in blockTreeNodes when exists.
    freeBlockTreeNodeElement: ?*list.Element(BlockInfoRedBlack.Node) = null, // ToDo: use SinglyLinkedList

    links: list.List(Link) = .{}, // ToDo: use SinglyLinkedList

    // ToDo: need an option: whether or not title is set externally.
    //       If not, the first non-bare h1 header will be viewed as tiltle.
    tocHeaders: list.List(*BlockInfo) = .{},

    pub fn getBlockByID(self: *const @This(), id: []const u8) ?*BlockInfo {
        var a = BlockAttibutes{
            .common = .{ .id = id },
        };
        var b = BlockInfo{
            .blockType = undefined,
            .attributes = &a,
        };

        return if (self.blocksByID.search(&b)) |node| node.value else null;
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
pub const MaxListNestingDepthPerBase = 8;
pub const ListMarkTypeIndex = u3;
pub const ListNestingDepthType = u8; // in fact, u4 is enough now

pub fn listBulletIndex(bulletMark: []const u8) ListMarkTypeIndex {
    if (bulletMark.len > 2) unreachable;

    switch (bulletMark.len) {
        1, 2 => {
            var index: ListMarkTypeIndex = switch (bulletMark[0]) {
                '+' => 0,
                '-' => 1,
                '*' => 2,
                '~' => 3,
                else => unreachable,
            };

            if (bulletMark.len == 1) {
                return index;
            }

            if (bulletMark[1] != '.') unreachable;
            index += 4;

            return index;
        },
        else => unreachable,
    }
}

pub const ElementAttibutes = struct {
    // For any block:
    id: []const u8 = "", // ToDo: should be a Range?
    classes: []const u8 = "", // ToDo: should be Range list?
    kvs: []const u8 = "", // ToDo: should be Range list?

    pub fn isForFootnote(self: *const @This()) bool {
        return self.id.len > 0 and self.id[0] == '^';
    }
};

pub const Link = struct {
    attrs: ElementAttibutes = .{}, // ToDo: use pointer? Memory will be more fragmental.
    info: *LinkInfo,
};

pub const BlockAttibutes = struct {
    common: ElementAttibutes = .{}, // ToDo: use pointer? Memory will be more fragmental.

    extra: union(enum) {
        base: BaseBlockAttibutes,
        code: CodeBlockAttibutes, // ToDo: use pointer? Memory will be more fragmental.
        none: void,
    } = .none,
};

pub const BaseBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
    isFooter: bool = false, // ToDo: use Range
    horizontalAlign: enum {
        none,
        left,
        center,
        right,
        justify,
    } = .none,
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
    nestingDepth: u32 = 0,

    blockType: BlockType,

    attributes: ?*BlockAttibutes = null,

    hasNonMediaTokens: bool = false, // for certain atom blocks only (only .usual? ToDo: not only)

    pub fn typeName(self: *@This()) []const u8 {
        return @tagName(self.blockType);
    }

    // for atom blocks

    pub fn isContainer(self: @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Container"),
        };
    }

    pub fn isAtom(self: @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Atom"),
        };
    }

    pub fn getStartLine(self: @This()) *LineInfo {
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

    pub fn getEndLine(self: @This()) *LineInfo {
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
        const xID = if (xAttributes.common.id.len > 0) xAttributes.common.id else unreachable;
        const yID = if (yAttributes.common.id.len > 0) yAttributes.common.id else unreachable;
        return switch (std.mem.order(u8, xID, yID)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    pub fn ownerListElement(self: *@This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", self));
    }
};

pub const BlockType = union(enum) {
    // container block types

    // ToDo: add .firstBlock and .lastBlock fileds for container blocks?

    bullet: struct {
        //isFirst: bool, // ToDo: can be saved
        //isLast: bool, // ToDo: can be saved (need .list.lastItem)

        list: *BlockInfo, // a .list

        const Container = void;

        pub fn isFirst(self: *@This()) bool {
            return self.list.ownerListElement().next.? == self.ownerBlockInfo().ownerListElement();
        }

        pub fn isLast(self: *@This()) bool {
            return self.list.lastBullet == self.ownerBlockInfo();
        }

        pub fn ownerBlockInfo(self: *@This()) *BlockInfo {
            const blockType: *BlockType = @alignCast(@fieldParentPtr("bullet", self));
            return @alignCast(@fieldParentPtr("blockType", blockType));
        }
    },

    list: struct { // lists are implicitly formed.
        _markTypeIndex: ListMarkTypeIndex, // ToDo: save it or not?

        isTab: bool, // ToDo: can be saved.
        index: u32, // for debug purpose

        lastBullet: *BlockInfo = undefined,

        // Note: the depth of the list is the same as its children

        const Container = void;

        const BulletType = enum {
            unordered,
            ordered,
        };

        pub fn bulletType(self: @This()) BulletType {
            if (self._markTypeIndex & 0b100 != 0) return .ordered;
            return .unordered;
        }
    },

    indented: struct { // ToDo: merged with bullet as dl.
        const Container = void;
    },

    quotation: struct {
        const Container = void;
    },
    note: struct {
        const Container = void;
    },
    reveal: struct {
        const Container = void;
    },
    unstyled: struct {
        const Container = void;
    },

    // base context block

    root: struct {
        doc: *Doc,
    },

    base: struct {
        openLine: *LineInfo, // header list is stored in .openLine.
        closeLine: ?*LineInfo = null,

        pub fn openPlayloadRange(self: @This()) ?Range {
            const openLine = self.openLine;
            return switch (openLine.lineType) {
                .baseBlockOpen => |baseBlockOpen| blk: {
                    std.debug.assert(baseBlockOpen.markEndWithSpaces <= openLine.rangeTrimmed.end);
                    break :blk Range{ .start = baseBlockOpen.markEndWithSpaces, .end = openLine.rangeTrimmed.end };
                },
                else => unreachable,
            };
        }

        pub fn closePlayloadRange(self: @This()) ?Range {
            if (self.closeLine) |closeLine| {
                return switch (closeLine.lineType) {
                    .baseBlockClose => |baseBlockClose| blk: {
                        std.debug.assert(baseBlockClose.markEndWithSpaces <= closeLine.rangeTrimmed.end);
                        break :blk Range{ .start = baseBlockClose.markEndWithSpaces, .end = closeLine.rangeTrimmed.end };
                    },
                    else => unreachable,
                };
            }
            return null;
        }
    },

    // ToDo:
    //table: struct {},
    //tableRow: struct {},
    //tableCell: struct {},

    // atom block types

    blank: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;
    },

    line: struct {
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

    directive: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atom = void;
    },

    code: AtomBlockWithBoundary,

    custom: AtomBlockWithBoundary,
};

pub const AtomBlockWithBoundary = struct {
    startLine: *LineInfo = undefined,
    endLine: *LineInfo = undefined,

    // Note: the custom block end tag line might be missing.
    //       For .code, the endLine might not be a .codeSnippetEnd line.
    //          It can be also of .code or .codeSnippetStart.
    //       For .custom, the endLine might not be a .customEnd line.
    //          It can be also of .data or .customStart.

    // traits:
    const Atom = void;

    pub fn startPlayloadRange(self: @This()) Range {
        return switch (self.startLine.lineType) {
            inline .codeSnippetStart, .customStart => |start| blk: {
                std.debug.assert(start.markEndWithSpaces <= self.startLine.rangeTrimmed.end);
                break :blk Range{ .start = start.markEndWithSpaces, .end = self.startLine.rangeTrimmed.end };
            },
            else => unreachable,
        };
    }

    pub fn endPlayloadRange(self: @This()) ?Range {
        return switch (self.endLine.lineType) {
            inline .codeSnippetEnd, .customEnd => |end| blk: {
                std.debug.assert(end.markEndWithSpaces <= self.endLine.rangeTrimmed.end);
                break :blk Range{ .start = end.markEndWithSpaces, .end = self.endLine.rangeTrimmed.end };
            },
            else => null,
        };
    }
};

pub const LineInfo = struct {
    index: u32, // one basedd (for debug purpose only)
    atomBlockIndex: u32, // one based (for debug purpose only)

    range: Range,
    rangeTrimmed: Range, // without leanding and traling blanks (except .code lines)

    endType: LineEndType,

    // For content block lines.
    // The value is false when any of the following ones is true:
    // * this is the last line in the most nesting block.
    // * the line doesn't contain a plainText token.
    // * no plainText tokens after an open-mark token in the line.
    // * no plainText tokens before a close-mark token in the line.
    // * the last plainText token in the line ends with a CJK char
    //   and the first plainText token in the next line (in the same most nesting block)
    //   containing plainText tokens starts with a CJK char.
    treatEndAsSpace: bool = false,

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

    pub fn isDirective(self: @This()) bool {
        return switch (self.lineType) {
            .directive => true,
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

    pub fn ownerListElement(self: *@This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", self));
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
    bullet: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    indented: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    quotation: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    note: struct {
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
    line: struct {
        markLen: u32,
    },

    baseBlockOpen: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        // ToDo: doc should maintain a base list.
        //       Here should use a pointer pointing element in that list.
        //       The header list should be put in that element.
        //       That element should store more info, like commentedOut etc.
        //       Similar for codeSnippet ...
        // ToDo: now only for .root block.
        //headers: ?*list.List(*BlockInfo) = .{}, // for .base BlockInfo
    },
    baseBlockClose: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },

    codeSnippetStart: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },
    codeSnippetEnd: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },
    code: struct {},

    customStart: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },
    customEnd: struct {
        markLen: u32,
        markEndWithSpaces: u32,
    },
    data: struct {},

    directive: struct {
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
    plainText: struct {
        start: u32,
        // The value should be the same as the start of the next token, or end of line.
        // But it is good to keep it here, to verify the this value is the same as ....
        end: u32,

        // Finally, the list will exclude the last one if
        // it is only used for self-defined URL.
        nextInLink: ?*TokenInfo = null,
    },
    commentText: struct {
        start: u32,
        // The value should be the same as the end of line.
        end: u32,

        inDirective: bool,
    },
    evenBackticks: struct {
        start: u32,
        pairCount: u32,
        secondary: bool,

        // `` means a void char.
        // ^`` means a ` char.
        // ToDo: ```` means non-collapsable space?
    },
    spanMark: struct {
        // For a close mark, this might be the start of the attached blanks.
        // For a open mark, this might be the position of the secondary sign.
        start: u32,
        blankLen: u32, // blank char count after open-mark or before close-mark in a line.

        // ToDo: replace the bools as bits.

        open: bool,
        secondary: bool = false,
        markType: SpanMarkType, // might
        markLen: u8, // without the secondary char
        blankSpan: bool, // enclose no texts (plainTexts or treatEndAsSpace)

        inDirective: bool, // for .linkInfo
        urlConfirmed: bool = false, // for .linkInfo
        isFootnote: bool = false, // for .linkInfo

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
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

        pub fn inDirective(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().inDirective;
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
    leadingMark: struct {
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

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }
};

pub const SpanMarkType = enum(u8) {
    link,
    fontWeight,
    fontStyle,
    fontSize,
    spoiler,
    deleted,
    marked,
    supsub,
    code,
    escaped, // must be the last one

    pub const MarkCount = @typeInfo(@This()).Enum.fields.len;

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
};
