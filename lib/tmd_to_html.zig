const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const parser = @import("tmd_parser.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");

pub fn tmd_to_html(tmdDoc: tmd.Doc, writer: anytype, completeHTML: bool, allocator: mem.Allocator) !void {
    var r = TmdRender{
        .doc = tmdDoc,
        .allocator = allocator,
    };
    if (completeHTML) {
        try writeHead(writer);
        try r.render(writer, true);
        try writeFoot(writer);
    } else {
        try r.render(writer, false);
    }
}

const FootnoteRedBlack = tree.RedBlack(*Footnote, Footnote);
const Footnote = struct {
    id: []const u8,
    orderIndex: u32 = undefined,
    refCount: u32 = undefined,
    block: ?*tmd.BlockInfo = undefined,

    pub fn compare(x: *const @This(), y: *const @This()) isize {
        return switch (mem.order(u8, x.id, y.id)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
};

const BlockInfoElement = list.Element(tmd.BlockInfo);
const LineInfoElement = list.Element(tmd.LineInfo);
const TokenInfoElement = list.Element(tmd.TokenInfo);

const TabListInfo = struct {
    orderId: u32,
    nextItemOrderId: u32 = 0,
};

const TmdRender = struct {
    doc: tmd.Doc,

    nullBlockInfoElement: list.Element(tmd.BlockInfo) = .{
        .value = .{
            // only use the nestingDepth field.
            .nestingDepth = 0,
            .blockType = .{
                .blank = .{},
            },
        },
    },

    tabListInfos: [tmd.MaxBlockNestingDepth]TabListInfo = undefined,
    currentTabListDepth: i32 = -1,
    nextTabListOrderId: u32 = 0,

    footnotesByID: FootnoteRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance
    footnoteNodes: list.List(FootnoteRedBlack.Node) = .{}, // for destroying

    allocator: mem.Allocator,

    fn cleanup(self: *TmdRender) void {
        const T = struct {
            fn destroyFootnoteNode(node: *FootnoteRedBlack.Node, a: mem.Allocator) void {
                a.destroy(node.value);
            }
        };
        list.destroyListElements(FootnoteRedBlack.Node, self.footnoteNodes, T.destroyFootnoteNode, self.allocator);
    }

    fn onFootnoteReference(self: *TmdRender, id: []const u8) !*Footnote {
        var footnote = @constCast(&Footnote{
            .id = id,
        });
        if (self.footnotesByID.search(footnote)) |node| {
            footnote = node.value;
            footnote.refCount += 1;
            return footnote;
        }

        footnote = try self.allocator.create(Footnote);
        footnote.* = .{
            .id = id,
            .orderIndex = @intCast(self.footnotesByID.count + 1),
            .refCount = 1,
            .block = self.doc.getBlockByID(id),
        };

        const nodeElement = try list.createListElement(FootnoteRedBlack.Node, self.allocator);
        self.footnoteNodes.push(nodeElement);

        const node = &nodeElement.value;
        node.value = footnote;
        std.debug.assert(node == self.footnotesByID.insert(node));

        return footnote;
    }

    fn render(self: *TmdRender, w: anytype, renderRoot: bool) !void {
        defer self.cleanup();

        var nilFootnoteTreeNode = FootnoteRedBlack.Node{
            .color = .black,
            .value = undefined,
        };
        self.footnotesByID.init(&nilFootnoteTreeNode);

        const element = self.doc.blocks.head();

        if (element) |blockInfoElement| {
            std.debug.assert(blockInfoElement.value.blockType == .root);
            if (renderRoot) _ = try w.write("\n<div class=\"tmd-doc\">\n");
            std.debug.assert((try self.renderBlockChildren(w, blockInfoElement, 0)) == &self.nullBlockInfoElement);
            try self.writeFootnotes(w);
            if (renderRoot) _ = try w.write("\n</div>\n");
        } else unreachable;
    }

    fn writeTableOfContents(self: *TmdRender, w: anytype, level: u8) !void {
        if (self.doc.tocHeaders.empty()) return;

        _ = try w.write("\n<ul class=\"tmd-list tmd-toc\">\n");

        var levelOpened: [tmd.MaxHeaderLevel + 1]bool = .{false} ** (tmd.MaxHeaderLevel + 1);
        var lastLevel: u8 = tmd.MaxHeaderLevel + 1;
        var listElement = self.doc.tocHeaders.head();
        if (listElement) |element| if (element.value.blockType.header.level(self.doc.data) == 1) {
            listElement = element.next; // skip the title header
        };
        while (listElement) |element| {
            defer listElement = element.next;
            const headerBlock = element.value;
            const headerLevel = headerBlock.blockType.header.level(self.doc.data);
            if (headerLevel > level) continue;

            defer lastLevel = headerLevel;

            //std.debug.print("== lastLevel={}, level={}\n", .{lastLevel, level});

            if (lastLevel > headerLevel) {
                for (headerLevel..lastLevel) |level_1| if (levelOpened[level_1]) {
                    // close last level
                    levelOpened[level_1] = false;
                    _ = try w.write("</ul>\n");
                };
            } else if (lastLevel < headerLevel) {
                // open level
                levelOpened[headerLevel - 1] = true;
                _ = try w.write("\n<ul class=\"tmd-list tmd-toc\">\n");
            }

            _ = try w.write("<li class=\"tmd-list-item tmd-toc-item\">");

            const id = if (headerBlock.attributes) |as| as.common.id else "";

            // ToDo:
            //_ = try w.write("hdr:");
            // try self.writeUsualContentAsID(w, headerBlock);
            // Maybe it is better to pre-generate the IDs, to avoid duplications.

            if (id.len == 0) _ = try w.write("<span class=\"tmd-broken-link\"") else {
                _ = try w.write("<a href=\"#");
                _ = try w.write(id);
            }
            _ = try w.write("\">");

            try self.writeUsualContentBlockLines(w, headerBlock, false);

            if (id.len == 0) _ = try w.write("</span>\n") else _ = try w.write("</a>\n");

            _ = try w.write("</li>\n");
        }

        for (&levelOpened) |opened| if (opened) {
            _ = try w.write("</ul>\n");
        };

        _ = try w.write("</ul>\n");
    }

    fn writeFootnotes(self: *TmdRender, w: anytype) !void {
        if (self.footnoteNodes.empty()) return;

        _ = try w.write("\n<ol class=\"tmd-list tmd-footnotes\">\n");

        var listElement = self.footnoteNodes.head();
        while (listElement) |element| {
            defer listElement = element.next;
            const footnote = element.value.value;

            _ = try w.print("<li id=\"fn:{s}\" class=\"tmd-list-item tmd-footnote-item\">\n", .{footnote.id});
            const missing_flag = if (footnote.block) |block| blk: {
                switch (block.blockType) {
                    .bullet => _ = try self.renderBlockChildren(w, block.ownerListElement(), 0),
                    else => _ = try self.renderBlock(w, block),
                }
                break :blk "";
            } else "?";

            for (1..footnote.refCount + 1) |n| {
                _ = try w.print(" <a href=\"#fn:{s}:ref-{}\">↩︎{s}</a>", .{ footnote.id, n, missing_flag });
            }
            _ = try w.write("</li>\n");
        }

        _ = try w.write("</ol>\n");
    }

    fn renderBlockChildren(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        return self.renderNextBlocks(w, parentElement.value.nestingDepth, parentElement, atMostCount);
    }

    fn renderBlock(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo) !*BlockInfoElement {
        const blockElement = blockInfo.ownerListElement();
        if (blockElement.prev) |prevElement| {
            return self.renderNextBlocks(w, blockInfo.nestingDepth - 1, prevElement, 1);
        } else {
            std.debug.assert(blockElement == self.doc.blocks.head());
            return &self.nullBlockInfoElement;
        }
    }

    fn getFollowingLevel1HeaderBlockElement(self: *TmdRender, parentElement: *BlockInfoElement) ?*BlockInfoElement {
        var afterElement = parentElement;
        while (afterElement.next) |element| {
            const blockInfo = &element.value;
            switch (blockInfo.blockType) {
                .directive => afterElement = element,
                .header => if (blockInfo.blockType.header.level(self.doc.data) == 1) {
                    return element;
                } else break,
                else => break,
            }
        }
        return null;
    }

    fn renderListItems(self: *TmdRender, w: anytype, listBlockInfo: *tmd.BlockInfo) !*BlockInfoElement {
        std.debug.assert(listBlockInfo.nestingDepth >= 1);
        const parentNestingDepth_1 = listBlockInfo.nestingDepth - 1;
        var lastElement = listBlockInfo.ownerListElement();
        while (true) {
            const nextElement = try self.renderNextBlocks(w, parentNestingDepth_1, lastElement, 1);

            // if (nextElement == &self.nullBlockInfoElement) return nextElement; // will enter the else branch below

            switch (nextElement.value.blockType) {
                .bullet => |listItem| {
                    if (listItem.list != listBlockInfo) return nextElement;
                    lastElement = nextElement.prev.?;
                },
                else => return nextElement,
            }
        }
    }

    const TableCell = struct {
        row: u32,
        col: u32,
        block: *tmd.BlockInfo,

        // Used to sort column-oriented table cells.
        fn compare(_: void, x: @This(), y: @This()) bool {
            if (x.col < y.col) return true;
            if (x.col > y.col) return false;
            if (x.row < y.row) return true;
            if (x.row > y.row) return false;
            unreachable;
        }
    };

    fn collectTableCells(self: *TmdRender, firstTableChild: *tmd.BlockInfo) ![]TableCell {
        var numCells: usize = 0;
        var firstNonLineChild: ?*tmd.BlockInfo = null;
        var child = firstTableChild;
        while (true) {
            switch (child.blockType) {
                .directive => {},
                .line => {},
                else => {
                    numCells += 1;
                    if (firstNonLineChild == null) firstNonLineChild = child;
                },
            }

            child = child.getNextSibling() orelse break;
            std.debug.assert(child.nestingDepth == firstTableChild.nestingDepth);
        }

        if (numCells == 0) return &.{};

        const cells = try self.allocator.alloc(TableCell, numCells);
        var row: u32 = 0;
        var col: u32 = 0;
        var index: usize = 0;
        var rowNeedChange = false;
        child = firstNonLineChild orelse unreachable;
        while (true) {
            switch (child.blockType) {
                .directive => {},
                .line => {
                    rowNeedChange = true;
                    col = 0;
                },
                else => {
                    if (rowNeedChange) {
                        row += 1;
                        rowNeedChange = false;
                    }
                    defer col += 1;
                    defer index += 1;

                    cells[index] = .{
                        .row = row,
                        .col = col,
                        .block = child,
                    };
                },
            }

            child = child.getNextSibling() orelse break;
        }
        std.debug.assert(index == cells.len);

        return cells;
    }

    fn renderTableHeaderCellBlock(self: *TmdRender, w: anytype, tableHeaderCellBlock: *tmd.BlockInfo) !void {
        _ = try w.write("<th>\n");
        try self.writeUsualContentBlockLines(w, tableHeaderCellBlock, false);
        _ = try w.write("</th>\n");
    }

    fn renderTableCellBlock(self: *TmdRender, w: anytype, tableCellBlock: *tmd.BlockInfo) !void {
        switch (tableCellBlock.blockType) {
            .header => |header| {
                if (header.level(self.doc.data) == 1)
                    return try self.renderTableHeaderCellBlock(w, tableCellBlock);
            },
            .base => |_| {
                if (self.getFollowingLevel1HeaderBlockElement(tableCellBlock.ownerListElement())) |headerElement| {
                    const headerBlock = &headerElement.value;
                    if (headerBlock.getNextSibling() == null)
                        return try self.renderTableHeaderCellBlock(w, headerBlock);
                }
            },
            else => {},
        }

        _ = try w.write("<td>\n");
        _ = try self.renderBlock(w, tableCellBlock);
        _ = try w.write("</td>\n");
    }

    fn renderTableBlock_RowOriented(self: *TmdRender, w: anytype, tableBlockInfo: *tmd.BlockInfo, firstChild: *tmd.BlockInfo) !?*tmd.BlockInfo {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) return try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
        defer self.allocator.free(cells);

        _ = try w.write("\n<table");
        try writeBlockAttributes(w, "tmd-table", tableBlockInfo.attributes);
        _ = try w.write(">\n");
        _ = try w.write("<tr>\n");

        var lastRow: u32 = 0;
        for (cells) |cell| {
            if (cell.row != lastRow) {
                lastRow = cell.row;

                _ = try w.write("</tr>\n");
                _ = try w.write("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block);
        }

        _ = try w.write("</tr>\n");
        _ = try w.write("</table>\n");

        return tableBlockInfo.getNextSibling();
    }

    fn renderTableBlock_ColumnOriented(self: *TmdRender, w: anytype, tableBlockInfo: *tmd.BlockInfo, firstChild: *tmd.BlockInfo) !?*tmd.BlockInfo {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) return try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
        defer self.allocator.free(cells);

        std.sort.pdq(TableCell, cells, {}, TableCell.compare);

        _ = try w.write("\n<table");
        try writeBlockAttributes(w, "tmd-table", tableBlockInfo.attributes);
        _ = try w.write(">\n");
        _ = try w.write("<tr>\n");

        var lastCol: u32 = 0;
        for (cells) |cell| {
            if (cell.col != lastCol) {
                lastCol = cell.col;

                _ = try w.write("</tr>\n");
                _ = try w.write("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block);
        }

        _ = try w.write("</tr>\n");
        _ = try w.write("</table>\n");

        return tableBlockInfo.getNextSibling();
    }

    fn renderTableBlocks_WithoutCells(_: *TmdRender, w: anytype, tableBlockInfo: *tmd.BlockInfo) !?*tmd.BlockInfo {
        _ = try w.write("\n<div");
        try writeBlockAttributes(w, "tmd-table-no-cells", tableBlockInfo.attributes);
        _ = try w.write("></div>\n");

        return tableBlockInfo.getNextSibling();
    }

    fn renderTableBlock(self: *TmdRender, w: anytype, tableBlockInfo: *tmd.BlockInfo) !*BlockInfoElement {
        const child = tableBlockInfo.next() orelse unreachable;
        const columnOriented = switch (child.blockType) {
            .usual => |usual| blk: {
                if (usual.startLine != usual.endLine) break :blk false;
                break :blk if (usual.startLine.tokens()) |tokens| tokens.empty() else false;
            },
            else => false,
        };

        const nextBlock = if (columnOriented) blk: {
            if (child.getNextSibling()) |sibling|
                break :blk try self.renderTableBlock_ColumnOriented(w, tableBlockInfo, sibling);

            break :blk try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
        } else try self.renderTableBlock_RowOriented(w, tableBlockInfo, child);

        return if (nextBlock) |sibling| sibling.ownerListElement() else &self.nullBlockInfoElement;
    }

    fn renderBlockChildrenForLargeQuotationBlock(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockAttributes(w, "tmd-usual", blockInfo.attributes);
            _ = try w.write(">\n");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        return element;
    }

    fn renderBlockChildrenForNoteBlock(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockAttributes(w, "tmd-note-header", blockInfo.attributes);
            _ = try w.write(">\n");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        _ = try w.write("\n<div class=\"tmd-note-content\">\n");

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div>\n");
        return element;
    }

    fn renderBlockChildrenForRevealBlock(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        _ = try w.write("\n<details>\n");

        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<summary");
            try writeBlockAttributes(w, "", blockInfo.attributes);
            _ = try w.write(">\n");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</summary>\n");

            break :blk headerElement;
        } else blk: {
            _ = try w.write("<summary></summary>\n");

            break :blk parentElement;
        };

        _ = try w.write("<div class=\"tmd-reveal-content\">");
        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div></details>\n");
        return element;
    }

    fn renderBlockChildrenForUnstyledBox(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockAttributes(w, "tmd-unstyled-header", blockInfo.attributes);
            _ = try w.write(">\n");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);

        return element;
    }

    fn renderNextBlocks(self: *TmdRender, w: anytype, parentNestingDepth: u32, afterElement: *BlockInfoElement, atMostCount: u32) anyerror!*BlockInfoElement {
        var remainingCount: u32 = if (atMostCount > 0) atMostCount + 1 else 0;
        if (afterElement.next) |nextElement| {
            var element = nextElement;
            while (true) {
                const blockInfo = &element.value;
                if (blockInfo.nestingDepth <= parentNestingDepth) {
                    return element;
                }
                if (remainingCount > 0) {
                    remainingCount -= 1;
                    if (remainingCount == 0) {
                        return element;
                    }
                }
                switch (blockInfo.blockType) {
                    .root => unreachable,
                    .base => |base| handle: {
                        const attrs = if (base.openPlayloadRange()) |r| blk: {
                            const playload = self.doc.data[r.start..r.end];
                            break :blk parser.parse_base_block_open_playload(playload);
                        } else tmd.BaseBlockAttibutes{};

                        if (attrs.commentedOut) {
                            element = try self.renderBlockChildren(std.io.null_writer, element, 0);
                            break :handle;
                        }

                        if (attrs.isFooter) _ = try w.write("\n<footer") else _ = try w.write("\n<div");

                        if (attrs.isFooter) {
                            try writeBlockAttributes(w, "tmd-base tmd-footer", blockInfo.attributes);
                        } else {
                            try writeBlockAttributes(w, "tmd-base", blockInfo.attributes);
                        }

                        switch (attrs.horizontalAlign) {
                            .none => {},
                            .left => _ = try w.write(" style=\"text-align: left;\""),
                            .center => _ = try w.write(" style=\"text-align: center;\""),
                            .justify => _ = try w.write(" style=\"text-align: justify;\""),
                            .right => _ = try w.write(" style=\"text-align: right;\""),
                        }
                        _ = try w.write(">");
                        element = try self.renderBlockChildren(w, element, 0);
                        if (attrs.isFooter) {
                            _ = try w.write("\n</footer>\n");
                        } else {
                            _ = try w.write("\n</div>\n");
                        }
                    },

                    // containers

                    .list => |itemList| {
                        switch (itemList.listType) {
                            .bullets => {
                                // open
                                {
                                    _ = try w.write(if (itemList.secondMode) "\n<ol" else "\n<ul");

                                    try writeBlockAttributes(w, "tmd-list", blockInfo.attributes);
                                    _ = try w.write(">");
                                }

                                // items
                                element = try self.renderListItems(w, blockInfo);

                                // close
                                {
                                    _ = try w.write(if (itemList.secondMode) "\n</ol>\n" else "\n</ul>\n");
                                }
                            },
                            .tabs => {
                                // Todo: if secondMode, prefixed a number in tab?

                                // open
                                {
                                    _ = try w.write("\n<div");
                                    try writeBlockAttributes(w, "tmd-tab", blockInfo.attributes);
                                    _ = try w.write(">");

                                    const orderId = self.nextTabListOrderId;
                                    self.nextTabListOrderId += 1;

                                    std.debug.assert(self.currentTabListDepth >= -1 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                    self.currentTabListDepth += 1;
                                    self.tabListInfos[@intCast(self.currentTabListDepth)] = TabListInfo{
                                        .orderId = orderId,
                                    };
                                }

                                // items
                                element = try self.renderListItems(w, blockInfo);

                                // close
                                {
                                    _ = try w.write("\n</div>\n");

                                    std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                    self.currentTabListDepth -= 1;
                                }
                            },
                            .definitions => {
                                // open
                                {
                                    _ = try w.write("\n<dl");
                                    const defsClass = if (itemList.secondMode) "tmd-list tmd-defs-oneline" else "tmd-list tmd-defs";
                                    try writeBlockAttributes(w, defsClass, blockInfo.attributes);
                                    _ = try w.write(">\n");
                                }

                                // items
                                element = try self.renderListItems(w, blockInfo);

                                // close
                                {
                                    _ = try w.write("\n</dl>\n");
                                }
                            },
                        }
                    },
                    .bullet => |*listItem| {
                        switch (listItem.list.blockType.list.listType) {
                            .bullets => {
                                _ = try w.write("\n<li");
                                try writeBlockAttributes(w, "tmd-list-item", blockInfo.attributes);
                                _ = try w.write(">\n");
                                element = try self.renderBlockChildren(w, element, 0);
                                _ = try w.write("\n</li>\n");
                            },
                            .tabs => {
                                std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                //self.tabListInfos[@intCast(self.currentTabListDepth)].nextItemOrderId += 1;
                                const tabInfo = &self.tabListInfos[@intCast(self.currentTabListDepth)];
                                tabInfo.nextItemOrderId += 1;

                                _ = try w.print("<input type=\"radio\" class=\"tmd-tab-radio\" name=\"tmd-tab-{d}\" id=\"tmd-tab-{d}-input-{d}\"", .{
                                    tabInfo.orderId, tabInfo.orderId, tabInfo.nextItemOrderId,
                                });
                                if (listItem.isFirst()) {
                                    _ = try w.write(" checked");
                                }
                                _ = try w.write(">\n");
                                _ = try w.print("<label for=\"tmd-tab-{d}-input-{d}\" class=\"tmd-tab-label\"", .{
                                    tabInfo.orderId, tabInfo.nextItemOrderId,
                                });

                                const afterElement2 = if (self.getFollowingLevel1HeaderBlockElement(element)) |headerElement| blk: {
                                    const headerBlockInfo = &headerElement.value;

                                    try writeBlockAttributes(w, "tmd-tab-header", headerBlockInfo.attributes);
                                    _ = try w.write(">");

                                    if (listItem.list.blockType.list.secondMode)
                                        _ = try w.print("{d}. ", .{tabInfo.nextItemOrderId});

                                    try self.writeUsualContentBlockLines(w, headerBlockInfo, false);

                                    break :blk headerElement;
                                } else blk: {
                                    _ = try w.write(">\n");

                                    if (listItem.list.blockType.list.secondMode)
                                        _ = try w.print("{d}. ", .{tabInfo.nextItemOrderId});

                                    break :blk element;
                                };

                                _ = try w.write("</label>\n");

                                _ = try w.write("\n<div");
                                try writeBlockAttributes(w, "tmd-tab-content", blockInfo.attributes);
                                _ = try w.write(">\n");
                                element = try self.renderNextBlocks(w, element.value.nestingDepth, afterElement2, 0);
                                _ = try w.write("\n</div>\n");
                            },
                            .definitions => {
                                const lastElement = if (self.getFollowingLevel1HeaderBlockElement(element)) |headerElement| blk: {
                                    const headerBlockInfo = &headerElement.value;

                                    _ = try w.write("<dt");
                                    try writeBlockAttributes(w, "", headerBlockInfo.attributes);
                                    _ = try w.write(">");
                                    try self.writeUsualContentBlockLines(w, headerBlockInfo, false);
                                    _ = try w.write("</dt>");

                                    break :blk headerElement;
                                } else element;

                                _ = try w.write("\n<dd>\n");
                                element = try self.renderNextBlocks(w, element.value.nestingDepth, lastElement, 0);
                                _ = try w.write("\n</dd>\n");
                            },
                        }
                    },
                    .table => {
                        element = try self.renderTableBlock(w, blockInfo);
                    },
                    .quotation => {
                        _ = try w.write("\n<div");
                        if (self.getFollowingLevel1HeaderBlockElement(element)) |_| {
                            try writeBlockAttributes(w, "tmd-quotation-large", blockInfo.attributes);
                            _ = try w.write(">\n");
                            element = try self.renderBlockChildrenForLargeQuotationBlock(w, element, 0);
                        } else {
                            try writeBlockAttributes(w, "tmd-quotation", blockInfo.attributes);
                            _ = try w.write(">\n");
                            element = try self.renderBlockChildren(w, element, 0);
                        }
                        _ = try w.write("\n</div>\n");
                    },
                    .note => {
                        _ = try w.write("\n<div");
                        try writeBlockAttributes(w, "tmd-note", blockInfo.attributes);
                        _ = try w.write(">\n");
                        element = try self.renderBlockChildrenForNoteBlock(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .reveal => {
                        _ = try w.write("\n<div");
                        try writeBlockAttributes(w, "tmd-reveal", blockInfo.attributes);
                        _ = try w.write(">\n");
                        element = try self.renderBlockChildrenForRevealBlock(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .unstyled => {
                        _ = try w.write("\n<div");
                        try writeBlockAttributes(w, "tmd-unstyled", blockInfo.attributes);
                        _ = try w.write(">\n");
                        element = try self.renderBlockChildrenForUnstyledBox(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },

                    // atom

                    .line => |_| {
                        _ = try w.print("<hr class=\"tmd-line\"/>\n", .{});

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .header => |header| {
                        element = element.next orelse &self.nullBlockInfoElement;

                        const level = header.level(self.doc.data);
                        if (header.isBare()) {
                            try self.writeTableOfContents(w, level);
                        } else {
                            _ = try w.print("\n<h{}", .{level});
                            try writeBlockAttributes(w, tmdHeaderClass(level), blockInfo.attributes);
                            _ = try w.write(">\n");

                            try self.writeUsualContentBlockLines(w, blockInfo, false);

                            _ = try w.print("</h{}>\n", .{level});
                        }
                    },
                    .usual => |usual| {
                        const usualLine = usual.startLine.lineType.usual;
                        const writeBlank = usualLine.markLen > 0 and usualLine.tokens.empty();

                        _ = try w.write("\n<div");
                        try writeBlockAttributes(w, "tmd-usual", blockInfo.attributes);
                        _ = try w.write(">\n");
                        try self.writeUsualContentBlockLines(w, blockInfo, writeBlank);
                        _ = try w.write("\n</div>\n");

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .directive => {
                        //_ = try w.write("\n<div></div>\n");
                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .blank => {
                        //if (!self.lastRenderedBlockIsBlank) {

                        _ = try w.write("\n<p");
                        if (blockInfo.attributes) |as| {
                            _ = try writeID(w, as.common.id);
                        }
                        _ = try w.write("></p>\n");

                        //    self.lastRenderedBlockIsBlank = true;
                        //}

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .code => |code| {
                        const r = code.startPlayloadRange();
                        const playload = self.doc.data[r.start..r.end];
                        const attrs = parser.parse_code_block_open_playload(playload);
                        if (attrs.commentedOut) {
                            _ = try w.write("\n<div");
                            if (blockInfo.attributes) |as| {
                                _ = try writeID(w, as.common.id);
                            }
                            _ = try w.write("></div>\n");
                        } else {
                            try self.writeCodeBlockLines(w, blockInfo, attrs);
                        }

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .custom => |custom| {
                        const r = custom.startPlayloadRange();
                        const playload = self.doc.data[r.start..r.end];
                        const attrs = parser.parse_custom_block_open_playload(playload);
                        if (attrs.commentedOut) {
                            _ = try w.write("\n<div");
                            if (blockInfo.attributes) |as| {
                                _ = try writeID(w, as.common.id);
                            }
                            _ = try w.write("></div>\n");
                        } else {
                            try self.writeCustomBlock(w, blockInfo, attrs);
                        }

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                }
            }
        }

        return &self.nullBlockInfoElement;
    }

    const MarkCount = tmd.SpanMarkType.MarkCount;
    const MarkStatus = struct {
        mark: ?*tmd.SpanMark = null,
    };
    const MarkStatusesTracker = struct {
        markStatusElements: [MarkCount]list.Element(MarkStatus) = .{.{}} ** MarkCount,
        marksStack: list.List(MarkStatus) = .{},

        activeLinkInfo: ?*tmd.LinkInfo = null,
        // These are only valid when activeLinkInfo != null.
        firstPlainTextInLink: bool = undefined,
        linkFootnote: *Footnote = undefined,

        fn onLinkInfo(self: *@This(), linkInfo: *tmd.LinkInfo) void {
            self.activeLinkInfo = linkInfo;
            self.firstPlainTextInLink = true;
        }
    };

    fn writeCustomBlock(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo, attrs: tmd.CustomBlockAttibutes) !void {
        // Not a good idea to wrapping the content.
        //_ = try w.write("<div");
        //try writeBlockAttributes(w, "tmd-custom", blockInfo.attributes);
        //_ = try w.write("\">");

        if (attrs.app.len == 0) {
            _ = try w.write("[...]");
        } else if (std.ascii.eqlIgnoreCase(attrs.app, "html")) {
            const endLine = blockInfo.getEndLine();
            const startLine = blockInfo.getStartLine();
            std.debug.assert(startLine.lineType == .customStart);

            var lineInfoElement = startLine.ownerListElement();
            if (startLine != endLine) {
                lineInfoElement = lineInfoElement.next.?;
                while (true) {
                    const lineInfo = &lineInfoElement.value;
                    switch (lineInfo.lineType) {
                        .customEnd => break,
                        .data => {
                            const r = lineInfo.range;
                            _ = try w.write(self.doc.data[r.start..r.end]);
                        },
                        else => unreachable,
                    }

                    std.debug.assert(!lineInfo.treatEndAsSpace);
                    if (lineInfo == endLine) break;
                    _ = try w.write("\n");
                    if (lineInfoElement.next) |next| {
                        lineInfoElement = next;
                    } else unreachable;
                }
            }
        } else {
            _ = try w.print("[{s} ...]", .{attrs.app}); // ToDo

            // Common MIME types:
            //    https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
        }

        // Not a good idea to wrapping the content.
        //_ = try w.write("</div>\n");
    }

    fn writeCodeBlockLines(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo, attrs: tmd.CodeBlockAttibutes) !void {
        std.debug.assert(blockInfo.blockType == .code);

        //std.debug.print("\n==========\n", .{});
        //std.debug.print("commentedOut: {}\n", .{attrs.commentedOut});
        //std.debug.print("language: {s}\n", .{@tagName(attrs.language)});
        //std.debug.print("==========\n", .{});

        _ = try w.write("<pre");
        try writeBlockAttributes(w, "tmd-code", blockInfo.attributes);
        if (attrs.language.len > 0) {
            _ = try w.write("\"><code class=\"language-");
            try writeHtmlAttributeValue(w, attrs.language);
        }
        _ = try w.write("\">");

        const endLine = blockInfo.getEndLine();
        const startLine = blockInfo.getStartLine();
        std.debug.assert(startLine.lineType == .codeBlockStart);

        var lineInfoElement = startLine.ownerListElement();
        if (startLine != endLine) {
            lineInfoElement = lineInfoElement.next.?;
            while (true) {
                const lineInfo = &lineInfoElement.value;
                switch (lineInfo.lineType) {
                    .codeBlockEnd => break,
                    .code => {
                        const r = lineInfo.range;
                        try writeHtmlContentText(w, self.doc.data[r.start..r.end]);
                    },
                    else => unreachable,
                }

                std.debug.assert(!lineInfo.treatEndAsSpace);
                if (lineInfo == endLine) break;
                _ = try w.write("\n");
                if (lineInfoElement.next) |next| {
                    lineInfoElement = next;
                } else unreachable;
            }
        }

        blk: {
            const r = blockInfo.blockType.code.endPlayloadRange() orelse break :blk;
            const closePlayload = self.doc.data[r.start..r.end];
            const streamAttrs = parser.parse_block_close_playload(closePlayload);
            const content = streamAttrs.content;
            if (content.len == 0) break :blk;
            if (std.mem.startsWith(u8, content, "./") or std.mem.startsWith(u8, content, "../")) {
                // ToDo: ...
            } else if (std.mem.startsWith(u8, content, "#")) {
                const id = content[1..];
                const b = if (self.doc.getBlockByID(id)) |b| b else break :blk;
                const be: *list.Element(tmd.BlockInfo) = @alignCast(@fieldParentPtr("value", b));
                _ = try self.renderTmdCode(w, be);
            } else break :blk;
        }

        if (attrs.language.len > 0) {
            _ = try w.write("</code>");
        }
        _ = try w.write("</pre>\n");
    }

    fn writeUsualContentBlockLines(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo, writeBlank: bool) !void {
        if (writeBlank) _ = try w.write("<p></p>\n");

        const inHeader = blockInfo.blockType == .header;
        var tracker: MarkStatusesTracker = .{};

        const endLine = blockInfo.getEndLine();
        var lineInfoElement = blockInfo.getStartLine().ownerListElement();
        while (true) {
            const lineInfo = &lineInfoElement.value;

            // Just to check all possible types. Don't remove.
            switch (lineInfo.lineType) {
                .blank, .usual, .header, .line, .directive, .baseBlockOpen, .baseBlockClose, .codeBlockStart, .codeBlockEnd, .code, .customStart, .customEnd, .data => {},
            }

            {
                var element = lineInfo.tokens().?.head();
                while (element) |tokenInfoElement| {
                    const token = &tokenInfoElement.value;
                    switch (token.tokenType) {
                        .commentText => {},
                        .plainText => blk: {
                            if (tracker.activeLinkInfo) |linkInfo| {
                                if (!tracker.firstPlainTextInLink) {
                                    std.debug.assert(!linkInfo.isFootnote());

                                    switch (linkInfo.info) {
                                        .urlSourceText => |sourceText| {
                                            if (sourceText == token) break :blk;
                                        },
                                        else => {},
                                    }
                                } else {
                                    tracker.firstPlainTextInLink = false;

                                    if (linkInfo.isFootnote()) {
                                        if (tracker.linkFootnote.block) |_| {
                                            _ = try w.print("[{}]", .{tracker.linkFootnote.orderIndex});
                                        } else {
                                            _ = try w.print("[{}]?", .{tracker.linkFootnote.orderIndex});
                                        }
                                        break :blk;
                                    }
                                }
                            }
                            const text = self.doc.data[token.start()..token.end()];
                            _ = try writeHtmlContentText(w, text);
                        },
                        .linkInfo => |*l| {
                            tracker.onLinkInfo(l);
                        },
                        .evenBackticks => |m| {
                            if (m.secondary) {
                                //_ = try w.write("&ZeroWidthSpace;"); // ToDo: write the code utf value instead

                                for (0..m.pairCount) |_| {
                                    _ = try w.write("`");
                                }
                            }
                        },
                        .spanMark => |*m| {
                            if (m.blankSpan) {
                                // skipped
                            } else if (m.open) {
                                const markElement = &tracker.markStatusElements[m.markType.asInt()];
                                std.debug.assert(markElement.value.mark == null);

                                markElement.value.mark = m;
                                if (m.markType == .link and !m.secondary) {
                                    std.debug.assert(tracker.activeLinkInfo != null);

                                    tracker.marksStack.pushHead(markElement);
                                    try writeCloseMarks(w, markElement);

                                    var linkURL: []const u8 = undefined;

                                    const linkInfo = tracker.activeLinkInfo orelse unreachable;
                                    blk: {
                                        if (linkInfo.urlConfirmed()) {
                                            std.debug.assert(linkInfo.urlConfirmed());
                                            std.debug.assert(linkInfo.info.urlSourceText != null);

                                            const t = linkInfo.info.urlSourceText.?;
                                            linkURL = parser.trim_blanks(self.doc.data[t.start()..t.end()]);

                                            if (linkInfo.isFootnote()) {
                                                const footnote_id = linkURL[1..];
                                                const footnote = try self.onFootnoteReference(footnote_id);
                                                tracker.linkFootnote = footnote;

                                                _ = try w.print("<sup><a id=\"fn:{s}:ref-{}\" href=\"#fn:{s}\"", .{ footnote_id, footnote.refCount, footnote_id });
                                                break :blk;
                                            }
                                        } else {
                                            std.debug.assert(!linkInfo.urlConfirmed());
                                            std.debug.assert(!linkInfo.isFootnote());

                                            // ToDo: call custom callback to try to generate a url.

                                            _ = try w.write("<span class=\"tmd-broken-link\"");

                                            break :blk;
                                        }

                                        _ = try w.write("<a");
                                        _ = try w.write(" href=\"");
                                        _ = try w.write(linkURL);
                                        _ = try w.write("\"");
                                    }

                                    if (tracker.activeLinkInfo.?.attrs) |attrs| {
                                        std.debug.assert(!linkInfo.isFootnote());
                                        try writeElementAttributes(w, "", attrs);
                                    }
                                    _ = try w.write(">");

                                    try writeOpenMarks(w, markElement);
                                } else {
                                    tracker.marksStack.push(markElement);
                                    try writeOpenMark(w, markElement.value.mark.?);
                                }
                            } else try closeMark(w, m, &tracker);
                        },
                        .leadingMark => |m| {
                            switch (m.markType) {
                                .lineBreak => {
                                    _ = try w.write("<br/>");
                                },
                                .comment => {},
                                .media => blk: {
                                    if (tracker.activeLinkInfo) |_| {
                                        tracker.firstPlainTextInLink = false;
                                    }
                                    if (m.isBare) {
                                        _ = try w.write(" ");
                                        break :blk;
                                    }

                                    const mediaInfoElement = tokenInfoElement.next.?;
                                    const isInline = inHeader or blockInfo.hasNonMediaTokens;

                                    writeMedia: {
                                        const mediaInfoToken = mediaInfoElement.value;
                                        std.debug.assert(mediaInfoToken.tokenType == .plainText);

                                        const mediaInfo = self.doc.data[mediaInfoToken.start()..mediaInfoToken.end()];
                                        var it = mem.splitAny(u8, mediaInfo, " \t");
                                        const src = it.first();
                                        if (!std.mem.startsWith(u8, src, "./") and !std.mem.startsWith(u8, src, "../") and !std.mem.startsWith(u8, src, "https://") and !std.mem.startsWith(u8, src, "http://")) break :writeMedia;
                                        if (!std.mem.endsWith(u8, src, ".png") and !std.mem.endsWith(u8, src, ".gif") and !std.mem.endsWith(u8, src, ".jpg") and !std.mem.endsWith(u8, src, ".jpeg")) break :writeMedia;

                                        // ToDo: read more arguments.

                                        // ToDo: need do more for url validation.

                                        _ = try w.write("<img src=\"");
                                        try writeHtmlAttributeValue(w, src);
                                        if (isInline) {
                                            _ = try w.write("\" class=\"tmd-inline-media\"/>");
                                        } else {
                                            _ = try w.write("\"/>");
                                        }
                                    }

                                    element = mediaInfoElement.next;
                                    continue;
                                },
                            }
                        },
                    }

                    element = tokenInfoElement.next;
                }
            }

            if (lineInfo.treatEndAsSpace) _ = try w.write(" ");
            if (lineInfo == endLine) break;
            if (lineInfoElement.next) |next| {
                lineInfoElement = next;
            } else unreachable;
        }

        if (tracker.marksStack.tail()) |element| {
            var markElement = element;
            while (true) {
                if (markElement.value.mark) |m| {
                    try closeMark(w, m, &tracker);
                } else unreachable;

                if (markElement.prev) |prev| {
                    markElement = prev;
                } else break;
            }
        }
    }

    // Genreally, m is a close mark. But for missing close marks in the end,
    // their open counterparts are passed in here.
    fn closeMark(w: anytype, m: *tmd.SpanMark, tracker: *MarkStatusesTracker) !void {
        const markElement = &tracker.markStatusElements[m.markType.asInt()];
        std.debug.assert(markElement.value.mark != null);

        done: {
            switch (m.markType) {
                .link => blk: {
                    //if (m.secondary) break :blk;
                    const linkInfo = tracker.activeLinkInfo orelse break :blk;
                    tracker.activeLinkInfo = null;

                    try writeCloseMarks(w, markElement);

                    if (linkInfo.urlConfirmed()) {
                        _ = try w.write("</a></sup>");
                    } else {
                        _ = try w.write("</span></sup>");
                    }

                    try writeOpenMarks(w, markElement);

                    if (tracker.marksStack.popHead()) |head| {
                        std.debug.assert(head == markElement);
                    } else unreachable;

                    break :done;
                },
                .code, .escaped => {
                    if (tracker.marksStack.pop()) |tail| {
                        std.debug.assert(tail == markElement);
                    } else unreachable;

                    try writeCloseMark(w, markElement.value.mark.?);

                    break :done;
                },
                else => {},
            }

            // else ...

            try writeCloseMarks(w, markElement);
            try writeCloseMark(w, markElement.value.mark.?);
            try writeOpenMarks(w, markElement);

            tracker.marksStack.delete(markElement);
        }

        markElement.value.mark = null;
    }

    fn writeOpenMarks(w: anytype, bottomElement: *list.Element(MarkStatus)) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeOpenMark(w, element.value.mark.?);
            next = element.next;
        }
    }

    fn writeCloseMarks(w: anytype, bottomElement: *list.Element(MarkStatus)) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeCloseMark(w, element.value.mark.?);
            next = element.next;
        }
    }

    // ToDo: to optimize by using a table.
    fn writeOpenMark(w: anytype, spanMark: *tmd.SpanMark) !void {
        switch (spanMark.markType) {
            .link => {
                std.debug.assert(spanMark.secondary);
                _ = try w.write("<span class=\"tmd-underlined\">");
            },
            .fontWeight => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-dimmed\">");
                } else {
                    _ = try w.write("<span class=\"tmd-bold\">");
                }
            },
            .fontStyle => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-revert-italic\">");
                } else {
                    _ = try w.write("<span class=\"tmd-italic\">");
                }
            },
            .fontSize => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-larger-size\">");
                } else {
                    _ = try w.write("<span class=\"tmd-smaller-size\">");
                }
            },
            .spoiler => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-secure-spoiler\">");
                } else {
                    _ = try w.write("<span class=\"tmd-spoiler\">");
                }
            },
            .deleted => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-invisible\">");
                } else {
                    _ = try w.write("<span class=\"tmd-deleted\">");
                }
            },
            .marked => {
                if (spanMark.secondary) {
                    _ = try w.write("<mark class=\"tmd-marked-2\">");
                } else {
                    _ = try w.write("<mark class=\"tmd-marked\">");
                }
            },
            .supsub => {
                if (spanMark.secondary) {
                    _ = try w.write("<sup>");
                } else {
                    _ = try w.write("<sub>");
                }
            },
            .code => {
                if (spanMark.secondary) {
                    _ = try w.write("<code class=\"tmd-mono-font\">");
                } else {
                    _ = try w.write("<code class=\"tmd-code-span\">");
                }
            },
            .escaped => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class=\"tmd-keep-whitespaces\">");
                }
            },
        }
    }

    // ToDo: to optimize
    fn writeCloseMark(w: anytype, spanMark: *tmd.SpanMark) !void {
        switch (spanMark.markType) {
            .link, .fontWeight, .fontStyle, .fontSize, .spoiler, .deleted => {
                _ = try w.write("</span>");
            },
            .marked => {
                _ = try w.write("</mark>");
            },
            .supsub => {
                if (spanMark.secondary) {
                    _ = try w.write("</sup>");
                } else {
                    _ = try w.write("</sub>");
                }
            },
            .code => {
                _ = try w.write("</code>");
            },
            .escaped => {
                if (spanMark.secondary) {
                    _ = try w.write("</span>");
                }
            },
        }
    }

    fn writeHtmlContentText(w: anytype, text: []const u8) !void {
        var last: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '&' => {
                    _ = try w.write(text[last..i]);
                    _ = try w.write("&amp;");
                    last = i + 1;
                },
                '<' => {
                    _ = try w.write(text[last..i]);
                    _ = try w.write("&lt;");
                    last = i + 1;
                },
                '>' => {
                    _ = try w.write(text[last..i]);
                    _ = try w.write("&gt;");
                    last = i + 1;
                },
                //'"' => {
                //    _ = try w.write(text[last..i]);
                //    _ = try w.write("&quot;");
                //    last = i + 1;
                //},
                //'\'' => {
                //    _ = try w.write(text[last..i]);
                //    _ = try w.write("&apos;");
                //    last = i + 1;
                //},
                else => {},
            }
        }
        _ = try w.write(text[last..i]);
    }

    fn tmdHeaderClass(level: u8) []const u8 {
        return switch (level) {
            1 => "tmd-header-1",
            2 => "tmd-header-2",
            3 => "tmd-header-3",
            4 => "tmd-header-4",
            else => unreachable,
        };
    }

    fn writeBlockAttributes(w: anytype, classesSeperatedBySpace: []const u8, attributes: ?*tmd.BlockAttibutes) !void {
        if (attributes) |as| {
            try writeElementAttributes(w, classesSeperatedBySpace, &as.common);
        } else {
            try writeClasses(w, classesSeperatedBySpace, "");
        }
    }

    fn writeElementAttributes(w: anytype, classesSeperatedBySpace: []const u8, attributes: *tmd.ElementAttibutes) !void {
        _ = try writeID(w, attributes.id);
        try writeClasses(w, classesSeperatedBySpace, attributes.classes);
    }

    fn writeID(w: anytype, id: []const u8) !bool {
        if (id.len == 0) return false;

        _ = try w.write(" id=\"");
        _ = try w.write(id);
        _ = try w.write("\"");
        return true;
    }

    fn writeClasses(w: anytype, classesSeperatedBySpace: []const u8, classesSeperatedBySemicolon: []const u8) !void {
        if (classesSeperatedBySpace.len == 0 and classesSeperatedBySemicolon.len == 0) return;

        _ = try w.write(" class=\"");
        var needSpace = classesSeperatedBySpace.len > 0;
        if (needSpace) _ = try w.write(classesSeperatedBySpace);
        if (classesSeperatedBySemicolon.len > 0) {
            var it = mem.splitAny(u8, classesSeperatedBySemicolon, ";");
            var item = it.first();
            while (true) {
                if (item.len != 0) {
                    if (needSpace) _ = try w.write(" ") else needSpace = true;
                    _ = try w.write(item);
                }

                if (it.next()) |next| {
                    item = next;
                } else break;
            }
        }
        _ = try w.write("\"");
    }

    fn writeHtmlAttributeValue(w: anytype, text: []const u8) !void {
        var last: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '"' => {
                    _ = try w.write(text[last..i]);
                    _ = try w.write("&quot;");
                    last = i + 1;
                },
                '\'' => {
                    _ = try w.write(text[last..i]);
                    _ = try w.write("&apos;");
                    last = i + 1;
                },
                else => {},
            }
        }
        _ = try w.write(text[last..i]);
    }

    fn writeMultiHtmlAttributeValues(w: anytype, values: []const u8, writeFirstSpace: bool) !void {
        var it = mem.splitAny(u8, values, ",");
        var item = it.first();
        var writeSpace = writeFirstSpace;
        while (true) {
            if (item.len != 0) {
                if (writeSpace) _ = try w.write(" ") else writeSpace = true;

                try writeHtmlAttributeValue(w, item);
            }

            if (it.next()) |next| {
                item = next;
            } else break;
        }
    }

    fn renderTmdCode(self: *TmdRender, w: anytype, element: *BlockInfoElement) !void {
        if (element.value.isAtom()) {
            try self.renderTmdCodeForAtomBlock(w, &element.value, true);
        } else {
            _ = try self.renderTmdCodeForBlockChildren(w, element);
        }
    }

    fn renderTmdCodeForBlockChildren(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement) !*BlockInfoElement {
        const parentNestingDepth = parentElement.value.nestingDepth;

        if (parentElement.next) |nextElement| {
            var element = nextElement;
            while (true) {
                const blockInfo = &element.value;
                if (blockInfo.nestingDepth <= parentNestingDepth) {
                    return element;
                }
                switch (blockInfo.blockType) {
                    .root => unreachable,
                    .base => |base| {
                        try self.renderTmdCodeOfLine(w, base.openLine, false);
                        element = try self.renderTmdCodeForBlockChildren(w, element);
                        if (base.closeLine) |closeLine| try self.renderTmdCodeOfLine(w, closeLine, false); // or trimContainerMark, no matter
                    },

                    // containers

                    .list, .bullet, .table, .quotation, .note, .reveal, .unstyled => {
                        element = try self.renderTmdCodeForBlockChildren(w, element);
                    },

                    // atom

                    .line, .header, .usual, .directive, .blank, .code, .custom => {
                        try self.renderTmdCodeForAtomBlock(w, blockInfo, false);

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                }
            }
        }

        return &self.nullBlockInfoElement;
    }

    fn renderTmdCodeForAtomBlock(self: *TmdRender, w: anytype, atomBlock: *tmd.BlockInfo, trimContainerMark: bool) !void {
        var lineInfo = atomBlock.getStartLine();
        try self.renderTmdCodeOfLine(w, lineInfo, trimContainerMark);

        const endLine = atomBlock.getEndLine();
        while (lineInfo != endLine) {
            const lineElement: *list.Element(tmd.LineInfo) = @alignCast(@fieldParentPtr("value", lineInfo));
            if (lineElement.next) |next| {
                lineInfo = &next.value;
            } else break;

            try self.renderTmdCodeOfLine(w, lineInfo, false);
        }
    }

    fn renderTmdCodeOfLine(self: *TmdRender, w: anytype, lineInfo: *tmd.LineInfo, trimContainerMark: bool) !void {
        const start = lineInfo.start(trimContainerMark, false);
        const end = lineInfo.end(false);
        try writeHtmlContentText(w, self.doc.data[start..end]);
        _ = try w.write("\n");
    }
};

const css_style = @embedFile("example.css");

fn writeHead(w: anytype) !void {
    _ = try w.write(
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>Tapir's Markdown Format</title>
        \\<style>
    );
    _ = try w.write(css_style);
    _ = try w.write(
        \\</style>
        \\</head>
        \\<body>
        \\
    );
}

fn writeFoot(w: anytype) !void {
    _ = try w.write(
        \\
        \\</body>
        \\</html>
    );
}
