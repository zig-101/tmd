const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const LineScanner = @import("tmd_parser-line_scanner.zig");
const fns = @import("tmd_to_html-fns.zig");

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

const TabListInfo = struct {
    orderId: u32,
    nextItemOrderId: u32 = 0,
};

pub const TmdRender = struct {
    doc: tmd.Doc,

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

    pub fn render(self: *TmdRender, w: anytype, renderRoot: bool) !void {
        defer self.cleanup();

        var nilFootnoteTreeNode = FootnoteRedBlack.Node{
            .color = .black,
            .value = undefined,
        };
        self.footnotesByID.init(&nilFootnoteTreeNode);

        if (self.doc.blocks.head()) |blockInfoElement| {
            const rootBlock = &blockInfoElement.value;
            std.debug.assert(rootBlock.blockType == .root);

            if (renderRoot) {
                try self.renderBlock(w, rootBlock); // will call writeFootnotes
            } else {
                try self.renderBlockChildren(w, rootBlock.firstChild());
                try self.writeFootnotes(w);
            }
        } else unreachable;
    }

    fn renderBlock(self: *TmdRender, w: anytype, blockInfo: *const tmd.BlockInfo) anyerror!void {
        const footerTag = if (blockInfo.getFooterSibling()) |footer| blk: {
            const tag = "footer";
            const classes = "tmd-footer";

            try fns.writeOpenTag(w, tag, classes, footer.attributes, true);
            break :blk tag;
        } else "";

        handle: switch (blockInfo.blockType) {
            // base blocks

            .root => {
                const tag = "div";
                const classes = "tmd-doc";

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);
                try self.renderBlockChildren(w, blockInfo.firstChild());
                try self.writeFootnotes(w);
                try fns.writeCloseTag(w, tag, true);
            },
            .base => |*base| {
                const attrs = base.attributes();
                if (attrs.commentedOut) break :handle;

                const tag = "div";
                const classes = switch (attrs.horizontalAlign) {
                    .none => "tmd-base",
                    .left => "tmd-base tmd-align-left",
                    .center => "tmd-base tmd-align-center",
                    .justify => "tmd-base tmd-align-justify",
                    .right => "tmd-base tmd-align-right",
                };

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);
                try self.renderBlockChildren(w, blockInfo.firstChild());
                try fns.writeCloseTag(w, tag, true);
            },

            // built-in blocks

            .list => |*itemList| {
                switch (itemList.listType) {
                    .bullets => {
                        const tag = if (itemList.secondMode) "ol" else "ul";
                        const classes = "tmd-list";

                        try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);
                        try self.renderBlockChildren(w, blockInfo.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .definitions => {
                        const tag = "dl";
                        const classes = if (itemList.secondMode) "tmd-list tmd-defs-oneline" else "tmd-list tmd-defs";

                        try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);
                        try self.renderBlockChildren(w, blockInfo.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .tabs => {
                        const tag = "div";
                        const classes = "tmd-tab";

                        try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                        {
                            const orderId = self.nextTabListOrderId;
                            self.nextTabListOrderId += 1;

                            std.debug.assert(self.currentTabListDepth >= -1 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                            self.currentTabListDepth += 1;
                            self.tabListInfos[@intCast(self.currentTabListDepth)] = TabListInfo{
                                .orderId = orderId,
                            };
                        }

                        try self.renderBlockChildren(w, blockInfo.firstChild());
                        try fns.writeCloseTag(w, tag, true);

                        {
                            std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                            self.currentTabListDepth -= 1;
                        }
                    },
                }
            },

            // NOTE: can't be |listItem|, which makes @fieldParentPtr return wrong pointer.
            .item => |*listItem| {
                std.debug.assert(blockInfo.attributes == null); // ToDo: support item attributes?

                switch (listItem.list.blockType.list.listType) {
                    .bullets => {
                        const tag = "li";
                        const classes = "tmd-list-item";

                        try fns.writeOpenTag(w, tag, classes, null, true);
                        try self.renderBlockChildren(w, blockInfo.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .definitions => {
                        const forDdBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                            const tag = "dt";
                            const classes = "";

                            try fns.writeOpenTag(w, tag, classes, headerBlock.attributes, true);
                            try self.writeUsualContentBlockLines(w, headerBlock);
                            try fns.writeCloseTag(w, tag, true);

                            break :blk headerBlock.nextSibling();
                        } else blockInfo.firstChild();

                        const tag = "dd";
                        const classes = "";

                        try fns.writeOpenTag(w, tag, classes, null, true);
                        try self.renderBlockChildren(w, forDdBlock);
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .tabs => {
                        std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                        //self.tabListInfos[@intCast(self.currentTabListDepth)].nextItemOrderId += 1;
                        const tabInfo = &self.tabListInfos[@intCast(self.currentTabListDepth)];
                        tabInfo.nextItemOrderId += 1;

                        _ = try w.print(
                            \\<input type="radio" class="tmd-tab-radio" name="tmd-tab-{d}" id="tmd-tab-{d}-input-{d}"
                        ,
                            .{ tabInfo.orderId, tabInfo.orderId, tabInfo.nextItemOrderId },
                        );

                        if (listItem.isFirst()) _ = try w.write(" checked");
                        _ = try w.write(">\n");

                        const headerTag = "label";
                        const headerClasses = "tmd-tab-header";
                        _ = try w.print(
                            \\<{s} for="tmd-tab-{d}-input-{d}" class="tmd-tab-label"
                        ,
                            .{ headerTag, tabInfo.orderId, tabInfo.nextItemOrderId },
                        );
                        const firstContentBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                            try fns.writeBlockAttributes(w, headerClasses, headerBlock.attributes);
                            _ = try w.write(">");

                            if (listItem.list.blockType.list.secondMode) {
                                _ = try w.print("{d}. ", .{tabInfo.nextItemOrderId});
                            }
                            try self.writeUsualContentBlockLines(w, headerBlock);

                            break :blk headerBlock.nextSibling();
                        } else blk: {
                            try fns.writeBlockAttributes(w, headerClasses, null);
                            _ = try w.write(">");

                            if (listItem.list.blockType.list.secondMode) {
                                _ = try w.print("{d}. ", .{tabInfo.nextItemOrderId});
                            }

                            break :blk blockInfo.firstChild();
                        };
                        try fns.writeCloseTag(w, headerTag, true);

                        const tag = "div";
                        const classes = "tmd-tab-content";

                        try fns.writeOpenTag(w, tag, classes, null, true);
                        try self.renderBlockChildren(w, firstContentBlock);
                        try fns.writeCloseTag(w, tag, true);
                    },
                }
            },
            .table => {
                try self.renderTableBlock(w, blockInfo);
            },
            .quotation => {
                const tag = "div";

                const firstContentBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    const classes = "tmd-quotation-large";
                    try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-usual";

                        try fns.writeOpenTag(w, tag, headerClasses, headerBlock.attributes, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else blk: {
                    const classes = "tmd-quotation";
                    try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                    break :blk blockInfo.firstChild();
                };

                try self.renderBlockChildren(w, firstContentBlock);
                try fns.writeCloseTag(w, tag, true);
            },
            .notice => {
                const tag = "div";
                const classes = "tmd-notice";

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                const firstContentBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-notice-header";

                        try fns.writeOpenTag(w, tag, headerClasses, headerBlock.attributes, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else blockInfo.firstChild();

                {
                    const contentTag = "div";
                    const contentClasses = "tmd-notice-content";

                    try fns.writeOpenTag(w, contentTag, contentClasses, null, true);
                    try self.renderBlockChildren(w, firstContentBlock);
                    try fns.writeCloseTag(w, contentTag, true);
                }

                try fns.writeCloseTag(w, tag, true);
            },
            .reveal => {
                const tag = "details";
                const classes = "tmd-reveal";

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                const headerTag = "summary";
                const headerClasses = "tmd-reveal-header tmd-usual";
                const firstContentBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    try fns.writeOpenTag(w, headerTag, headerClasses, headerBlock.attributes, true);
                    try self.writeUsualContentBlockLines(w, headerBlock);

                    break :blk headerBlock.nextSibling();
                } else blk: {
                    try fns.writeOpenTag(w, headerTag, headerClasses, null, true);

                    break :blk blockInfo.firstChild();
                };
                try fns.writeCloseTag(w, headerTag, true);

                {
                    const contentTag = "div";
                    const contentClasses = "tmd-reveal-content";

                    try fns.writeOpenTag(w, contentTag, contentClasses, null, true);
                    try self.renderBlockChildren(w, firstContentBlock);
                    try fns.writeCloseTag(w, contentTag, true);
                }

                try fns.writeCloseTag(w, tag, true);
            },
            .unstyled => {
                const tag = "div";
                const classes = "tmd-unstyled";

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

                const firstContentBlock = if (blockInfo.getSpecialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-unstyled-header";

                        try fns.writeOpenTag(w, headerTag, headerClasses, headerBlock.attributes, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else blockInfo.firstChild();

                try self.renderBlockChildren(w, firstContentBlock);
                try fns.writeCloseTag(w, tag, true);
            },

            // atom

            .blank => {
                const tag = "p";
                const classes = "";

                try fns.writeBareTag(w, tag, classes, blockInfo.attributes, true);
            },
            .attributes => {},
            .seperator => {
                const tag = "hr";
                const classes = "tmd-line";

                try fns.writeBareTag(w, tag, classes, blockInfo.attributes, true);
            },
            .header => |*header| {
                const level = header.level(self.doc.data);
                if (header.isBare()) {
                    try self.writeTableOfContents(w, level);
                } else {
                    const realLevel = if (blockInfo != self.doc.titleHeader and self.doc.headerLevelNeedAdjusted(level)) level + 1 else level;
                    _ = try w.print("\n<h{}", .{realLevel});
                    try fns.writeBlockAttributes(w, tmdHeaderClass(realLevel), blockInfo.attributes);
                    _ = try w.write(">");

                    try self.writeUsualContentBlockLines(w, blockInfo);

                    _ = try w.print("</h{}>\n", .{realLevel});
                }
            },
            .usual => |usual| {
                const usualLine = usual.startLine.lineType.usual;
                const writeBlank = usualLine.markLen > 0 and usualLine.tokens.empty();
                if (writeBlank) {
                    const blankTag = "p";
                    const blankClasses = "";

                    try fns.writeBareTag(w, blankTag, blankClasses, null, true);
                }

                const tag = "div";
                const classes = "tmd-usual";

                try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);
                try self.writeUsualContentBlockLines(w, blockInfo);
                try fns.writeCloseTag(w, tag, true);
            },
            .code => |*code| {
                const attrs = code.attributes();
                if (!attrs.commentedOut) {
                    try self.writeCodeBlockLines(w, blockInfo, attrs);
                }
            },
            .custom => |*custom| {
                const attrs = custom.attributes();
                if (!attrs.commentedOut) {
                    try self.writeCustomBlock(w, blockInfo, attrs);
                }
            },
        }

        if (footerTag.len > 0) {
            try fns.writeCloseTag(w, footerTag, true);
        }
    }

    fn renderBlockChildren(self: *TmdRender, w: anytype, firstChild: ?*const tmd.BlockInfo) !void {
        var child = firstChild orelse return;
        while (true) {
            try self.renderBlock(w, child);
            child = if (child.nextSibling()) |sibling| sibling else break;
        }
    }

    //======================== table

    const TableCell = struct {
        row: u32,
        col: u32,
        endRow: u32,
        endCol: u32,
        block: *tmd.BlockInfo,
        next: ?*TableCell = null,

        // Used to sort column-oriented table cells.
        fn compare(_: void, x: @This(), y: @This()) bool {
            if (x.col < y.col) return true;
            if (x.col > y.col) return false;
            if (x.row < y.row) return true;
            if (x.row > y.row) return false;
            unreachable;
        }

        const Spans = struct {
            rowSpan: u32,
            colSpan: u32,
        };

        fn spans_RowOriented(
            self: *const @This(),
        ) Spans {
            return .{ .rowSpan = self.endRow - self.row, .colSpan = self.endCol - self.col };
        }

        fn spans_ColumnOriented(
            self: *const @This(),
        ) Spans {
            return .{ .rowSpan = self.endCol - self.col, .colSpan = self.endRow - self.row };
        }
    };

    fn collectTableCells(self: *TmdRender, firstTableChild: *tmd.BlockInfo) ![]TableCell {
        var numCells: usize = 0;
        var firstNonLineChild: ?*tmd.BlockInfo = null;
        var child = firstTableChild;
        while (true) {
            check: {
                switch (child.blockType) {
                    .blank => unreachable,
                    .attributes => break :check,
                    .seperator => break :check,
                    .base => |base| if (base.attributes().commentedOut) break :check,
                    else => std.debug.assert(child.isAtom()),
                }

                numCells += 1;
                if (firstNonLineChild == null) firstNonLineChild = child;
            }

            if (child.nextSibling()) |sibling| {
                child = sibling;
                std.debug.assert(child.nestingDepth == firstTableChild.nestingDepth);
            } else break;
        }

        if (numCells == 0) return &.{};

        const cells = try self.allocator.alloc(TableCell, numCells);
        var row: u32 = 0;
        var col: u32 = 0;
        var index: usize = 0;

        var toChangeRow = false;
        var lastMinEndRow: u32 = 0;
        var activeOldCells: ?*TableCell = null;
        var lastActiveOldCell: ?*TableCell = null;
        var uncheckedCells: ?*TableCell = null;

        child = firstNonLineChild orelse unreachable;
        while (true) {
            handle: {
                const rowSpan: u32, const colSpan: u32 = switch (child.blockType) {
                    .attributes => break :handle,
                    .seperator => {
                        toChangeRow = true;
                        break :handle;
                    },
                    .base => |base| blk: {
                        const attrs = base.attributes();
                        if (attrs.commentedOut) break :handle;
                        break :blk .{ attrs.cellSpans.crossSpan, attrs.cellSpans.axisSpan };
                    },
                    else => .{ 1, 1 },
                };

                if (toChangeRow) {
                    var cell = activeOldCells;
                    uncheckedCells = while (cell) |c| {
                        std.debug.assert(c.endRow >= lastMinEndRow);
                        if (c.endRow > lastMinEndRow) {
                            activeOldCells = c;
                            var last = c;
                            while (last.next) |next| {
                                std.debug.assert(next.endRow >= lastMinEndRow);
                                if (next.endRow > lastMinEndRow) {
                                    last.next = next;
                                    last = next;
                                }
                            }
                            last.next = null;
                            break c;
                        }
                        cell = c.next;
                    } else null;

                    activeOldCells = null;
                    lastActiveOldCell = null;

                    row = lastMinEndRow;
                    col = 0;
                    lastMinEndRow = 0;

                    toChangeRow = false;
                }
                defer index += 1;

                var cell = uncheckedCells;
                while (cell) |c| {
                    if (c.col <= col) {
                        col = c.endCol;
                        cell = c.next;

                        if (c.endRow - row > 1) {
                            if (activeOldCells == null) {
                                activeOldCells = c;
                            } else {
                                lastActiveOldCell.?.next = c;
                            }
                            lastActiveOldCell = c;
                            c.next = null;
                        }
                    } else {
                        uncheckedCells = c;
                        break;
                    }
                } else uncheckedCells = null;

                const endRow = row +| rowSpan;
                const endCol = col +| colSpan;
                defer col = endCol;

                cells[index] = .{
                    .row = row,
                    .col = col,
                    .endRow = endRow,
                    .endCol = endCol,
                    .block = child,
                };

                if (lastMinEndRow == 0 or endRow < lastMinEndRow) lastMinEndRow = endRow;
                if (rowSpan > 1) {
                    const c = &cells[index];
                    if (activeOldCells == null) {
                        activeOldCells = c;
                    } else {
                        lastActiveOldCell.?.next = c;
                    }
                    lastActiveOldCell = c;
                    c.next = null;
                }
            }

            child = child.nextSibling() orelse break;
        }
        std.debug.assert(index == cells.len);

        return cells;
    }

    fn writeTableCellSpans(w: anytype, spans: TableCell.Spans) !void {
        std.debug.assert(spans.rowSpan > 0);
        if (spans.rowSpan != 1) {
            _ = try w.print(
                \\ rowspan="{}"
            , .{spans.rowSpan});
        }
        std.debug.assert(spans.colSpan > 0);
        if (spans.colSpan != 1) _ = try w.print(
            \\ colspan="{}"
        , .{spans.colSpan});
    }

    // ToDo: write align
    fn renderTableHeaderCellBlock(self: *TmdRender, w: anytype, tableHeaderCellBlock: *const tmd.BlockInfo, spans: TableCell.Spans) !void {
        _ = try w.write("<th");
        try writeTableCellSpans(w, spans);
        _ = try w.write(">\n");
        try self.writeUsualContentBlockLines(w, tableHeaderCellBlock);
        _ = try w.write("</th>\n");
    }

    // ToDo: write align
    fn renderTableCellBlock(self: *TmdRender, w: anytype, tableCellBlock: *const tmd.BlockInfo, spans: TableCell.Spans) !void {
        switch (tableCellBlock.blockType) {
            .header => |header| {
                if (header.level(self.doc.data) == 1)
                    return try self.renderTableHeaderCellBlock(w, tableCellBlock, spans);
            },
            .base => |_| { // some headers might need different text aligns.
                if (tableCellBlock.getSpecialHeaderChild(self.doc.data)) |headerBlock| {
                    if (headerBlock.nextSibling() == null)
                        return try self.renderTableHeaderCellBlock(w, headerBlock, spans);
                }
            },
            else => {},
        }

        _ = try w.write("<td");
        try writeTableCellSpans(w, spans);
        _ = try w.write(">\n");
        try self.renderBlock(w, tableCellBlock);
        _ = try w.write("</td>\n");
    }

    fn renderTableBlock_RowOriented(self: *TmdRender, w: anytype, tableBlockInfo: *const tmd.BlockInfo, firstChild: *tmd.BlockInfo) !void {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) {
            try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
            return;
        }
        defer self.allocator.free(cells);

        const tag = "table";
        const classes = "tmd-table";

        try fns.writeOpenTag(w, tag, classes, tableBlockInfo.attributes, true);

        _ = try w.write("<tr>\n");
        var lastRow: u32 = 0;
        for (cells) |cell| {
            if (cell.row != lastRow) {
                lastRow = cell.row;

                _ = try w.write("</tr>\n");
                _ = try w.write("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block, cell.spans_RowOriented());
        }
        _ = try w.write("</tr>\n");

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock_ColumnOriented(self: *TmdRender, w: anytype, tableBlockInfo: *const tmd.BlockInfo, firstChild: *tmd.BlockInfo) !void {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) {
            try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
            return;
        }
        defer self.allocator.free(cells);

        std.sort.pdq(TableCell, cells, {}, TableCell.compare);

        const tag = "table";
        const classes = "tmd-table";

        try fns.writeOpenTag(w, tag, classes, tableBlockInfo.attributes, true);

        _ = try w.write("<tr>\n");
        var lastCol: u32 = 0;
        for (cells) |cell| {
            if (cell.col != lastCol) {
                lastCol = cell.col;

                _ = try w.write("</tr>\n");
                _ = try w.write("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block, cell.spans_ColumnOriented());
        }
        _ = try w.write("</tr>\n");

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlocks_WithoutCells(_: *TmdRender, w: anytype, tableBlockInfo: *const tmd.BlockInfo) !void {
        const tag = "div";
        const classes = "tmd-table-no-cells";

        try fns.writeOpenTag(w, tag, classes, tableBlockInfo.attributes, true);
        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock(self: *TmdRender, w: anytype, tableBlockInfo: *const tmd.BlockInfo) !void {
        const child = tableBlockInfo.next() orelse unreachable;
        const columnOriented = switch (child.blockType) {
            .usual => |usual| blk: {
                if (usual.startLine != usual.endLine) break :blk false;
                break :blk if (usual.startLine.tokens()) |tokens| tokens.empty() else false;
            },
            else => false,
        };

        if (columnOriented) {
            if (child.nextSibling()) |sibling|
                try self.renderTableBlock_ColumnOriented(w, tableBlockInfo, sibling)
            else
                try self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
        } else try self.renderTableBlock_RowOriented(w, tableBlockInfo, child);

        if (false and builtin.mode == .Debug) {
            if (columnOriented) {
                if (child.nextSibling()) |sibling|
                    try self.renderTableBlock_RowOriented(w, tableBlockInfo, sibling)
                else
                    self.renderTableBlocks_WithoutCells(w, tableBlockInfo);
            } else try self.renderTableBlock_ColumnOriented(w, tableBlockInfo, child);
        }
    }

    //======================== custom

    fn writeCustomBlock(self: *TmdRender, w: anytype, blockInfo: *const tmd.BlockInfo, attrs: tmd.CustomBlockAttibutes) !void {
        // Not a good idea to wrapping the content.
        //_ = try w.write("<div");
        //try writeBlockAttributes(w, "tmd-custom", blockInfo.attributes);
        //_ = try w.write("\">");

        if (attrs.app.len == 0) {
            _ = try w.write("[...]");
        } else if (std.ascii.eqlIgnoreCase(attrs.app, "html")) blk: {
            const endLine = blockInfo.getEndLine();
            const startLine = blockInfo.getStartLine();
            std.debug.assert(startLine.lineType == .customBlockStart);

            var lineInfo = startLine.next() orelse break :blk;
            while (true) {
                switch (lineInfo.lineType) {
                    .customBlockEnd => break,
                    .data => _ = try w.write(self.doc.rangeData(lineInfo.range)),
                    else => unreachable,
                }

                // ToDo: should handle line-end spacing?
                std.debug.assert(!lineInfo.treatEndAsSpace);
                _ = try w.write("\n");

                if (lineInfo == endLine) break;

                lineInfo = lineInfo.next() orelse unreachable;
            }
        } else {
            _ = try w.print("[{s} ...]", .{attrs.app}); // ToDo

            // Common MIME types:
            //    https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
        }

        // Not a good idea to wrapping the content.
        //_ = try w.write("</div>\n");
    }

    //============================== code

    fn writeCodeBlockLines(self: *TmdRender, w: anytype, blockInfo: *const tmd.BlockInfo, attrs: tmd.CodeBlockAttibutes) !void {
        std.debug.assert(blockInfo.blockType == .code);

        //std.debug.print("\n==========\n", .{});
        //std.debug.print("commentedOut: {}\n", .{attrs.commentedOut});
        //std.debug.print("language: {s}\n", .{@tagName(attrs.language)});
        //std.debug.print("==========\n", .{});

        const tag = "pre";
        const classes = "tmd-code";

        try fns.writeOpenTag(w, tag, classes, blockInfo.attributes, true);

        if (attrs.language.len > 0) {
            _ = try w.write("<code class=\"language-");
            try fns.writeHtmlAttributeValue(w, attrs.language);
            _ = try w.write("\"");
            _ = try w.write(">");
        }

        const endLine = blockInfo.getEndLine();
        const startLine = blockInfo.getStartLine();
        std.debug.assert(startLine.lineType == .codeBlockStart);

        if (startLine.next()) |firstLine| {
            var lineInfo = firstLine;
            while (true) {
                switch (lineInfo.lineType) {
                    .codeBlockEnd => break,
                    .code => try fns.writeHtmlContentText(w, self.doc.rangeData(lineInfo.range)),
                    else => unreachable,
                }

                std.debug.assert(!lineInfo.treatEndAsSpace);
                _ = try w.write("\n");

                if (lineInfo == endLine) break;

                lineInfo = lineInfo.next() orelse unreachable;
            }
        }

        blk: {
            const streamAttrs = blockInfo.blockType.code.contentStreamAttributes();
            const content = streamAttrs.content;
            if (content.len == 0) break :blk;
            if (std.mem.startsWith(u8, content, "./") or std.mem.startsWith(u8, content, "../")) {
                // ToDo: ...
            } else if (std.mem.startsWith(u8, content, "#")) {
                const id = content[1..];
                const b = if (self.doc.getBlockByID(id)) |b| b else break :blk;
                _ = try self.renderTmdCode(w, b, true);
            } else break :blk;
        }

        if (attrs.language.len > 0) {
            _ = try w.write("</code>");
        }

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTmdCode(self: *TmdRender, w: anytype, blockInfo: *const tmd.BlockInfo, trimBoundaryLines: bool) anyerror!void {
        switch (blockInfo.blockType) {
            .root => unreachable,
            .base => |base| {
                try self.renderTmdCodeOfLine(w, base.openLine, trimBoundaryLines);
                try self.renderTmdCodeForBlockChildren(w, blockInfo);
                if (base.closeLine) |closeLine| try self.renderTmdCodeOfLine(w, closeLine, trimBoundaryLines);
            },

            // built-in containers
            .list, .item, .table, .quotation, .notice, .reveal, .unstyled => {
                try self.renderTmdCodeForBlockChildren(w, blockInfo);
            },

            // atom
            .seperator, .header, .usual, .attributes, .blank, .code, .custom => try self.renderTmdCodeForAtomBlock(w, blockInfo, trimBoundaryLines),
        }
    }

    fn renderTmdCodeForBlockChildren(self: *TmdRender, w: anytype, parentBlockInfo: *const tmd.BlockInfo) !void {
        var child = parentBlockInfo.firstChild() orelse return;
        while (true) {
            try self.renderTmdCode(w, child, false);
            child = if (child.nextSibling()) |sibling| sibling else break;
        }
    }

    fn renderTmdCodeForAtomBlock(self: *TmdRender, w: anytype, atomBlock: *const tmd.BlockInfo, trimBoundaryLines: bool) !void {
        var lineInfo = atomBlock.getStartLine();
        const endLine = atomBlock.getEndLine();
        while (true) {
            try self.renderTmdCodeOfLine(w, lineInfo, trimBoundaryLines);

            if (lineInfo == endLine) break;
            lineInfo = lineInfo.next() orelse unreachable;
        }
    }

    fn renderTmdCodeOfLine(self: *TmdRender, w: anytype, lineInfo: *const tmd.LineInfo, trimBoundaryLines: bool) !void {
        if (trimBoundaryLines and lineInfo.isBoundary()) return;

        const start = lineInfo.start(false, false);
        const end = lineInfo.end(false);
        try fns.writeHtmlContentText(w, self.doc.rangeData(.{ .start = start, .end = end }));
        _ = try w.write("\n");
    }

    //======================== usual

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

    fn writeUsualContentBlockLines(self: *TmdRender, w: anytype, blockInfo: *const tmd.BlockInfo) !void {
        const inHeader = blockInfo.blockType == .header;
        var tracker: MarkStatusesTracker = .{};

        const endLine = blockInfo.getEndLine();
        var lineInfo = blockInfo.getStartLine();

        // Just to check all possible types. Don't remove.
        switch (lineInfo.lineType) {
            .blank, .usual, .header, .seperator, .attributes, .baseBlockOpen, .baseBlockClose, .codeBlockStart, .codeBlockEnd, .code, .customBlockStart, .customBlockEnd, .data => {},
        }

        while (true) {
            var element = lineInfo.tokens().?.head();
            var isNonBareSpoilerLine = false;
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
                        const text = self.doc.rangeData(token.range());
                        _ = try fns.writeHtmlContentText(w, text);
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
                        } else for (1..m.pairCount) |_| {
                            _ = try w.write("&nbsp");
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
                                        linkURL = LineScanner.trim_blanks(self.doc.rangeData(t.range()));

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
                                    try fns.writeBlockAttributes(w, "", attrs);
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
                            .escape => {},
                            .spoiler => if (tokenInfoElement.next) |_| {
                                _ = try w.write(
                                    \\<span class="tmd-spoiler">
                                );
                                isNonBareSpoilerLine = true;
                            },
                            .comment => break,
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

                                    const mediaInfo = self.doc.rangeData(mediaInfoToken.range());
                                    var it = mem.splitAny(u8, mediaInfo, " \t");
                                    const src = it.first();
                                    if (!std.mem.startsWith(u8, src, "./") and !std.mem.startsWith(u8, src, "../") and !std.mem.startsWith(u8, src, "https://") and !std.mem.startsWith(u8, src, "http://")) break :writeMedia;
                                    if (!std.mem.endsWith(u8, src, ".png") and !std.mem.endsWith(u8, src, ".gif") and !std.mem.endsWith(u8, src, ".jpg") and !std.mem.endsWith(u8, src, ".jpeg")) break :writeMedia;

                                    // ToDo: read more arguments.

                                    // ToDo: need do more for url validation.

                                    _ = try w.write("<img src=\"");
                                    try fns.writeHtmlAttributeValue(w, src);
                                    if (isInline) {
                                        _ = try w.write("\" class=\"tmd-inline-media\"/>");
                                    } else {
                                        _ = try w.write("\" class=\"tmd-media\"/>");
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

            if (isNonBareSpoilerLine) _ = try w.write("</span>");

            if (lineInfo.treatEndAsSpace) _ = try w.write(" ");

            if (lineInfo != endLine) {
                if (lineInfo.treatEndAsSpace) _ = try w.write(" ");
                lineInfo = lineInfo.next() orelse unreachable;
            } else {
                std.debug.assert(!lineInfo.treatEndAsSpace);
                break;
            }
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

        _ = try w.write("\n");
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
                        _ = try w.write("</a>");
                        if (linkInfo.isFootnote()) {
                            _ = try w.write("</sup>");
                        }
                    } else {
                        _ = try w.write("</span>");
                    }

                    try writeOpenMarks(w, markElement);

                    if (tracker.marksStack.popHead()) |head| {
                        std.debug.assert(head == markElement);
                    } else unreachable;

                    break :done;
                },
                .code => {
                    if (!markElement.value.mark.?.secondary) {
                        if (tracker.marksStack.pop()) |tail| {
                            std.debug.assert(tail == markElement);
                        } else unreachable;

                        try writeCloseMark(w, markElement.value.mark.?);

                        break :done;
                    }
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
                _ = try w.write(
                    \\<span class="tmd-underlined">
                );
            },
            .fontWeight => {
                if (spanMark.secondary) {
                    _ = try w.write(
                        \\<span class="tmd-dimmed">
                    );
                } else {
                    _ = try w.write(
                        \\<span class="tmd-bold">
                    );
                }
            },
            .fontStyle => {
                if (spanMark.secondary) {
                    _ = try w.write(
                        \\<span class="tmd-revert-italic">
                    );
                } else {
                    _ = try w.write(
                        \\<span class="tmd-italic">
                    );
                }
            },
            .fontSize => {
                if (spanMark.secondary) {
                    _ = try w.write(
                        \\<span class="tmd-larger-size">
                    );
                } else {
                    _ = try w.write(
                        \\<span class="tmd-smaller-size">
                    );
                }
            },
            .deleted => {
                if (spanMark.secondary) {
                    _ = try w.write(
                        \\<span class="tmd-invisible">
                    );
                } else {
                    _ = try w.write(
                        \\<span class="tmd-deleted">
                    );
                }
            },
            .marked => {
                if (spanMark.secondary) {
                    _ = try w.write(
                        \\<mark class="tmd-marked-2">
                    );
                } else {
                    _ = try w.write(
                        \\<mark class="tmd-marked">
                    );
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
                    _ = try w.write(
                        \\<code class="tmd-mono-font">
                    );
                } else {
                    _ = try w.write(
                        \\<code class="tmd-code-span">
                    );
                }
            },
        }
    }

    // ToDo: to optimize
    fn writeCloseMark(w: anytype, spanMark: *tmd.SpanMark) !void {
        switch (spanMark.markType) {
            .link, .fontWeight, .fontStyle, .fontSize, .deleted => {
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
        }
    }

    //================================= TOC and footnotes

    fn writeTableOfContents(self: *TmdRender, w: anytype, level: u8) !void {
        if (self.doc.tocHeaders.empty()) return;

        _ = try w.write("\n<ul class=\"tmd-list tmd-toc\">\n");

        var levelOpened: [tmd.MaxHeaderLevel + 1]bool = .{false} ** (tmd.MaxHeaderLevel + 1);
        var lastLevel: u8 = tmd.MaxHeaderLevel + 1;
        var listElement = self.doc.tocHeaders.head();
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

            const id = if (headerBlock.attributes) |as| as.id else "";

            // ToDo:
            //_ = try w.write("hdr:");
            // try self.writeUsualContentAsID(w, headerBlock);
            // Maybe it is better to pre-generate the IDs, to avoid duplications.

            if (id.len == 0) _ = try w.write("<span class=\"tmd-broken-link\"") else {
                _ = try w.write("<a href=\"#");
                _ = try w.write(id);
            }
            _ = try w.write("\">");

            try self.writeUsualContentBlockLines(w, headerBlock);

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
                    // .item can't have ID now.
                    //.item => _ = try self.renderBlockChildren(w, block),
                    .item => unreachable,
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

    //===================================

    fn tmdHeaderClass(level: u8) []const u8 {
        return switch (level) {
            1 => "tmd-header-1",
            2 => "tmd-header-2",
            3 => "tmd-header-3",
            4 => "tmd-header-4",
            5 => "tmd-header-5", // tmd.MaxHeaderLevel + 1
            else => unreachable,
        };
    }
};
