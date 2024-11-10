const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

const config = @import("config");

const tmd = @import("tmd.zig");
const list = @import("list.zig");

const AttributeParser = @import("tmd_parser-attribute_parser.zig");
const LineScanner = @import("tmd_parser-line_scanner.zig");
const DocDumper = @import("tmd_parser-doc_dumper.zig");
const DocParser = @import("tmd_parser-doc_parser.zig");

pub const trim_blanks = LineScanner.trim_blanks;
pub const parse_custom_block_open_playload = AttributeParser.parse_custom_block_open_playload;

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
    };
    try docParser.parseAll();

    if (config.dump_ast and builtin.mode == .Debug) {
        DocDumper.dumpTmdDoc(&tmdDoc);
    }

    return tmdDoc;
}
