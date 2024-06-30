const std = @import("std");
const builtin = @import("builtin");
const list = @import("list.zig");

pub const Doc = struct {
    data: []const u8,
    blocks: list.List(BlockInfo) = .{},
    blockAttributes: list.List(BlockAttibutes) = .{},
    lines: list.List(LineInfo) = .{},
    pendingLinks: list.List(*LinkInfo) = .{}, // ToDo
};

pub const Range = struct {
    start: u32,
    end: u32,
};

pub fn headerLevel(headeMark: []const u8) ?u8 {
    if (headeMark.len < 2) return null;
    if (headeMark[0] != '#' or headeMark[1] != '#') return null;
    if (headeMark.len == 2) return 1;
    return switch (headeMark[headeMark.len - 1]) {
        '#' => 1,
        '=' => 2,
        ':' => 3,
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

// A BlockAttibutes directive line
pub const BlockAttibutes = struct {
    //keepFormat: bool = false,

    //horizontalAlign: enum {
    //    none,
    //    left,
    //    center,
    //    justify,
    //    right,
    //} = .none,

    id: []const u8 = "", // ToDo: should be a Range?

    //classes: []const u8 = "", // ToDo: should be Range list?

    // ToDo: RangeListElement should be union {
    //    range: Range,
    //    next: *RangeListElement,
    // }
    // So that Ranges can be batch allocated together.
};

pub const BaseBlockAttibutes = struct {
    commentedOut: bool = false,
};

pub const CodeBlockAttibutes = struct {
    commentedOut: bool = false,
    language: []const u8 = "",
    // ToDo
    // startLineNumber: u32 = 0, // ++n 0 means not show line numbers
    // filepath: []const u8 = "", // @@path
};

pub const CustomBlockAttibutes = struct {
    commentedOut: bool = false,
    customApp: []const u8 = "",
    arguments: []const u8 = "",
    // The argument is the content in the following custom block.
    // It might be a file path.
};

// Note: keep the two consistent.
pub const MaxBlockNestingDepth = 64; // should be 2^N
pub const BlockNestingDepthType = u6; // must be capable of storing (count of stacked blocks)-1

pub const BlockInfo = struct {
    nestingDepth: u32 = 0,

    blockType: BlockType,

    attributes: ?*BlockAttibutes = null, // ToDo: maintain a list in doc for destroying

    pub fn typeName(self: *@This()) []const u8 {
        return @tagName(self.blockType);
    }

    // for atomic blocks

    pub fn isContainer(self: @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Container"),
        };
    }

    pub fn isAtomic(self: @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Atomic"),
        };
    }

    pub fn getStartLine(self: @This()) *LineInfo {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atomic")) {
                    return bt.startLine;
                }
                unreachable;
            },
        };
    }

    pub fn setStartLine(self: *@This(), lineInfo: *LineInfo) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atomic")) {
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
                if (@hasDecl(@TypeOf(bt), "Atomic")) {
                    return bt.endLine;
                }
                unreachable;
            },
        };
    }

    pub fn setEndLine(self: *@This(), lineInfo: *LineInfo) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atomic")) {
                    bt.endLine = lineInfo;
                    return;
                }
                unreachable;
            },
        };
    }
};

pub const BlockType = union(enum) {
    // container block types

    // ToDo: add .firstBlock and .lastBlock fileds for container blocks?

    list_item: struct {
        isFirst: bool,
        isLast: bool,

        //bulletType: enum {
        //    unordered,
        //    ordered,
        //},

        _markTypeIndex: ListMarkTypeIndex,

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

    indented: struct {
        const Container = void;
    },
    block_quote: struct {
        const Container = void;
    },
    note_box: struct {
        const Container = void;
    },
    disclosure_box: struct {
        const Container = void;
    },
    unstyled_box: struct {
        const Container = void;
    },

    // base context block

    root: struct {
        headers: list.List(*BlockInfo) = .{},
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

    // atomic block types

    header: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // ToDo: for generating catalog
        // nextInBase: ?*BlockInfo = null,

        // traits:
        const Atomic = void;

        pub fn level(self: @This(), tmdData: []const u8) u8 {
            const headerLine = self.startLine;
            const start = headerLine.containerMarkEnd();
            const end = start + headerLine.lineType.header.markLen;
            return headerLevel(tmdData[start..end]) orelse unreachable;
        }
    },

    blank: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atomic = void;
    },

    usual: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // ToDo: when false, no need to render.
        //       So a block with a singal ` will outout nothing.
        //       Maybe needless with .blankSpan.
        // hasContent: bool = false,

        // traits:
        const Atomic = void;
    },

    directive: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,

        // traits:
        const Atomic = void;
    },

    code_snippet: struct {
        startLine: *LineInfo = undefined,
        endLine: *LineInfo = undefined,
        // Note: the code block end tag line might be missing.
        //       So endLine might not be a .codeSnippetEnd line.
        //       It can be also of .code or .codeSnippetStart.

        // traits:
        const Atomic = void;

        pub fn startPlayloadRange(self: @This()) Range {
            return switch (self.startLine.lineType) {
                .codeSnippetStart => |codeSnippetEnd| blk: {
                    std.debug.assert(codeSnippetEnd.markEndWithSpaces <= self.startLine.rangeTrimmed.end);
                    break :blk Range{ .start = codeSnippetEnd.markEndWithSpaces, .end = self.startLine.rangeTrimmed.end };
                },
                else => unreachable,
            };
        }

        pub fn endPlayloadRange(self: @This()) ?Range {
            return switch (self.endLine.lineType) {
                .codeSnippetEnd => |codeSnippetEnd| blk: {
                    std.debug.assert(codeSnippetEnd.markEndWithSpaces <= self.endLine.rangeTrimmed.end);
                    break :blk Range{ .start = codeSnippetEnd.markEndWithSpaces, .end = self.endLine.rangeTrimmed.end };
                },
                else => null,
            };
        }
    },
};

pub const LineInfo = struct {
    index: u32, // one basedd (for debug purpose only)
    atomicBlockIndex: u32, // one based (for debug purpose only)

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

    containerMark: ?ContainerLeadingMark,
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
            inline .usual, .header, .directive => |*lt| &lt.tokens,
            else => null,
        };
    }

    pub fn ownerListElement(self: *@This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", self));
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
    list_item: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    indented: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    block_quote: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    note_box: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    disclosure_box: struct {
        markEnd: u32,
        markEndWithSpaces: u32,
    },
    unstyled_box: struct {
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
        tokens: list.List(TokenInfo) = .{},
    },
    header: struct {
        markLen: u32,
        markEndWithSpaces: u32,
        tokens: list.List(TokenInfo) = .{},
    },

    baseBlockOpen: struct {
        markLen: u32,
        markEndWithSpaces: u32,

        // ToDo: doc should maintain a base list.
        //       Here should use a pointer pointing element in that list.
        //       The header list should be put in that element.
        //       That element should store more info, like commentedOut etc.
        //       Similar for codeSnippet ...
        headers: list.List(*BlockInfo) = .{}, // for .base BlockInfo
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
    },
    spanMark: struct {
        // For a close mark, this might be the start of the attached blanks.
        // For a open mark, this might be the position of the secondary sign.
        start: u32,
        blankLen: u32, // blank char count after open-mark or before close-mark in a line.

        open: bool,
        secondary: bool = false,
        markType: SpanMarkType, // might
        markLen: u8, // without the secondary char
        blankSpan: bool, // enclose no texts (plainTexts or treatEndAsSpace)

        inDirective: bool, // for .linkInfo
        urlConfirmed: bool = false, // for .linkInfo

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // A linkInfo token is always before an open .link SpanMarkType token.
    linkInfo: struct {
        next: ?*@This() = null,
        info: union(enum) {
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

pub const LineSpanMarkType = enum(u8) {
    // used in usual blocks:
    lineBreak, // \\
    comment, // //
    media, // ::
    anchor, // ==
    //class,   // ..
};
