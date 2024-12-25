const std = @import("std");

const tmd = @import("tmd.zig");
const list = @import("list.zig");

pub fn dumpTmdDoc(tmdDoc: *const tmd.Doc) void {
    var blockElement = tmdDoc.blocks.head;
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
        if (blockInfo.nextSibling()) |sibling| {
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
                    var tokenInfoElement = tokens.head;
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
                            .leadingSpanMark => |m| {
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
                                var secondary: []const u8 = "";
                                if (m.open) close = "" else open = " ";
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
