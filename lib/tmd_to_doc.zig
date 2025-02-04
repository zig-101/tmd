const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");

const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
const LineScanner = @import("tmd_to_doc-line_scanner.zig");
const DocDumper = @import("tmd_to_doc-doc_dumper.zig");
const DocVerifier = @import("tmd_to_doc-doc_verifier.zig");
const DocParser = @import("tmd_to_doc-doc_parser.zig");

pub const trim_blanks = LineScanner.trim_blanks;
pub const parse_custom_block_open_playload = AttributeParser.parse_custom_block_open_playload;

pub fn parse_tmd(tmdData: []const u8, allocator: std.mem.Allocator) !tmd.Doc {
    if (tmdData.len > tmd.MaxDocSize) return error.DocSizeTooLarge;

    var tmdDoc = tmd.Doc{ .allocator = allocator, .data = tmdData };
    errdefer tmdDoc.destroy();

    const BlockRedBlack = tree.RedBlack(*tmd.Block, tmd.Block);
    const nilBlockTreeNodeElement = try list.createListElement(BlockRedBlack.Node, allocator);
    tmdDoc._blockTreeNodes.pushTail(nilBlockTreeNodeElement);
    const nilBlockTreeNode = &nilBlockTreeNodeElement.value;
    nilBlockTreeNode.* = BlockRedBlack.MakeNilNode();
    tmdDoc.blocksByID.init(nilBlockTreeNode);

    var docParser = DocParser{
        .tmdDoc = &tmdDoc,
    };
    try docParser.parseAll();

    DocDumper.dumpTmdDoc(&tmdDoc);
    DocVerifier.verifyTmdDoc(&tmdDoc);

    return tmdDoc;
}
