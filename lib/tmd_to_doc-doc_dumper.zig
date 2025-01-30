const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");

const config = @import("config");

pub fn dumpTmdDoc(tmdDoc: *const tmd.Doc) void {
    if (!config.dump_ast) return;
    std.debug.assert(builtin.mode == .Debug);

    var blockElement = tmdDoc.blocks.head;
    while (blockElement) |be| {
        defer blockElement = be.next;
        const block = &be.value;
        {
            var depth = block.nestingDepth;
            while (depth > 0) : (depth -= 1) {
                std.debug.print("  ", .{});
            }
        }
        std.debug.print("+{}: #{} {s}", .{ block.nestingDepth, block.index, block.typeName() });
        switch (block.blockType) {
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
        if (block.nextSibling()) |sibling| {
            std.debug.print(" (next sibling: #{} {s})", .{ sibling.index, sibling.typeName() });
        } else {
            std.debug.print(" (next sibling: <null>)", .{});
        }
        if (block.attributes) |attrs| {
            if (attrs.id.len > 0) {
                std.debug.print(" (id={s})", .{attrs.id});
            }
        }

        std.debug.print("\n", .{});

        if (block.isAtom()) {
            var line = block.startLine();
            const end = block.endLine();
            while (true) {
                var depth = block.nestingDepth + 1;
                while (depth > 0) : (depth -= 1) {
                    std.debug.print("  ", .{});
                }
                std.debug.print("- L{} @{}: <{s}> ({}..{}) ({}..{}) ({}..{}) <{s}> {}\n", .{
                    line.index.value(),
                    line.atomBlockIndex.value(),
                    line.typeName(),
                    line.prefixBlankEnd - line.start(.none) + 1,
                    line.suffixBlankStart - line.start(.none) + 1,
                    line.prefixBlankEnd,
                    line.suffixBlankStart,
                    line.start(.none),
                    line.end(.trimLineEnd),
                    line.endTypeName(),
                    line.treatEndAsSpace,
                });

                //if (line.tokens()) |tokens| {
                {
                    const tokens = &line.tokens;
                    var tokenElement = tokens.head;
                    //if (true) tokenElement = null; // debug switch
                    while (tokenElement) |element| {
                        depth = block.nestingDepth + 2;
                        while (depth > 0) : (depth -= 1) {
                            std.debug.print("  ", .{});
                        }

                        const token = &element.value;
                        //std.debug.print("==== <{s}>, token.end(): {}, token.end2(line): {}. {}\n", .{token.typeName(), token.end(), token.end2(line), token.end() == token.end2(line)});
                        std.debug.assert(token.end() == token.end2(line));

                        switch (token.*) {
                            .commentText => {
                                std.debug.print("|{}-{}: [{s}]", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    token.typeName(),
                                });
                            },
                            .content => {
                                std.debug.print("|{}-{}: [{s}]", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    token.typeName(),
                                });
                            },
                            .leadingSpanMark => |m| {
                                std.debug.print("|{}-{}: {s}:{s}", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    token.typeName(),
                                    m.typeName(),
                                });
                            },
                            .spanMark => |m| {
                                var open: []const u8 = "<";
                                var close: []const u8 = ">";
                                var secondary: []const u8 = "";
                                if (m.more.open) close = "" else open = " ";
                                if (m.more.secondary) secondary = "^";
                                std.debug.print("|{}-{}: {s}{s}{s}:{s}{s}", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    secondary,
                                    open,
                                    token.typeName(),
                                    m.typeName(),
                                    close,
                                });
                            },
                            .evenBackticks => |s| {
                                var secondary: []const u8 = "";
                                if (s.more.secondary) secondary = "^";
                                std.debug.print("|{}-{}: {s}<{s}>", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    secondary,
                                    token.typeName(),
                                });
                            },
                            inline .linkInfo, .extra => {
                                std.debug.print("|{}-{}: __{s}", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    token.typeName(),
                                });
                            },
                            inline .lineTypeMark, .containerMark => |_| {
                                std.debug.print("|{}-{}: {s}", .{
                                    token.start() - line.start(.none) + 1,
                                    token.end() - line.start(.none) + 1,
                                    token.typeName(),
                                });
                            },
                        }

                        std.debug.print("\n", .{});

                        tokenElement = element.next;
                    }
                }

                if (line == end) {
                    break;
                }

                const lineElement: *list.Element(tmd.Line) = @alignCast(@fieldParentPtr("value", line));
                if (lineElement.next) |le| {
                    line = &le.value;
                } else unreachable; // should always break from above
            }
        }
    }
}
