const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const parser = @import("tmd_parser.zig");
const list = @import("list.zig");

pub fn tmd_to_html(tmdDoc: tmd.Doc, writer: anytype, completeHTML: bool) !void {
    var r = TmdRender{
        .doc = tmdDoc,
    };
    if (completeHTML) {
        try writeHead(writer);
        try r.render(writer, true);
        try writeFoot(writer);
    } else {
        try r.render(writer, false);
    }
}

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

    fn render(self: *TmdRender, w: anytype, renderRoot: bool) !void {
        const element = self.doc.blocks.head();

        if (element) |blockInfoElement| {
            std.debug.assert(blockInfoElement.value.blockType == .root);
            if (renderRoot) _ = try w.write("\n<div class='tmd-doc'>\n");
            std.debug.assert((try self.renderBlockChildren(w, blockInfoElement, 0)) == &self.nullBlockInfoElement);
            if (renderRoot) _ = try w.write("\n</div>\n");
        } else unreachable;
    }

    fn renderBlockChildren(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        return self.renderNextBlocks(w, parentElement.value.nestingDepth, parentElement, atMostCount);
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

    fn renderBlockChildrenForIndented(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockID(w, blockInfo.attributes);
            _ = try w.write(" class='tmd-indented-header'>");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        _ = try w.write("\n<div class='tmd-note_box-content'>\n");

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div>\n");
        return element;
    }

    fn renderBlockChildrenForLargeBlockQuote(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockID(w, blockInfo.attributes);
            _ = try w.write(" class='tmd-usual'>");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        return element;
    }

    fn renderBlockChildrenForNoteBox(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<div");
            try writeBlockID(w, blockInfo.attributes);
            _ = try w.write(" class='tmd-note_box-header'>");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</div>");

            break :blk headerElement;
        } else parentElement;

        _ = try w.write("\n<div class='tmd-note_box-content'>\n");

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div>\n");
        return element;
    }

    fn renderBlockChildrenForDisclosure(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        _ = try w.write("\n<details>\n");

        const afterElement = if (self.getFollowingLevel1HeaderBlockElement(parentElement)) |headerElement| blk: {
            const blockInfo = &headerElement.value;

            _ = try w.write("<summary");
            try writeBlockID(w, blockInfo.attributes);
            _ = try w.write(">\n");
            try self.writeUsualContentBlockLines(w, blockInfo, false);
            _ = try w.write("</summary>\n");

            break :blk headerElement;
        } else blk: {
            _ = try w.write("<summary></summary>\n");

            break :blk parentElement;
        };

        _ = try w.write("<div class='tmd-disclosure_box-content'>");
        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div></details>\n");
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

                        try writeBlockID(w, blockInfo.attributes);

                        if (attrs.isFooter) _ = try w.write(" class='tmd-base tmd-footer'") else _ = try w.write(" class='tmd-base'");

                        switch (attrs.horizontalAlign) {
                            .none => {},
                            .left => _ = try w.write(" style='text-align: left;'"),
                            .center => _ = try w.write(" style='text-align: center;'"),
                            .justify => _ = try w.write(" style='text-align: justify;'"),
                            .right => _ = try w.write(" style='text-align: right;'"),
                        }
                        _ = try w.write(">");
                        element = try self.renderBlockChildren(w, element, 0);
                        if (attrs.isFooter) _ = try w.write("\n</footer>\n") else _ = try w.write("\n</div>\n");
                    },

                    // containers

                    .list_item => |listItem| {
                        if (listItem.isTabItem()) {
                            const tabInfo = if (listItem.isFirst) blk: {
                                _ = try w.write("\n<div");
                                _ = try w.write(" class='tmd-tab'>\n");

                                const orderId = self.nextTabListOrderId;
                                self.nextTabListOrderId += 1;

                                std.debug.assert(self.currentTabListDepth >= -1 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                self.currentTabListDepth += 1;
                                self.tabListInfos[@intCast(self.currentTabListDepth)] = TabListInfo{
                                    .orderId = orderId,
                                };

                                break :blk self.tabListInfos[@intCast(self.currentTabListDepth)];
                            } else blk: {
                                std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                self.tabListInfos[@intCast(self.currentTabListDepth)].nextItemOrderId += 1;
                                break :blk self.tabListInfos[@intCast(self.currentTabListDepth)];
                            };

                            _ = try w.print("<input type='radio' class='tmd-tab-radio' name='tmd-tab-{d}' id='tmd-tab-{d}-input-{d}'", .{
                                tabInfo.orderId, tabInfo.orderId, tabInfo.nextItemOrderId,
                            });
                            if (listItem.isFirst) {
                                _ = try w.write(" checked");
                            }
                            _ = try w.write(">\n");
                            _ = try w.print("<label for='tmd-tab-{d}-input-{d}' class='tmd-tab-label'", .{
                                tabInfo.orderId, tabInfo.nextItemOrderId,
                            });

                            const afterElement2 = if (self.getFollowingLevel1HeaderBlockElement(element)) |headerElement| blk: {
                                const headerBlockInfo = &headerElement.value;

                                try writeBlockID(w, headerBlockInfo.attributes);
                                _ = try w.write(">\n");

                                try self.writeUsualContentBlockLines(w, headerBlockInfo, false);

                                break :blk headerElement;
                            } else blk: {
                                _ = try w.write(">\n");
                                break :blk element;
                            };

                            _ = try w.write("</label>\n");

                            _ = try w.write("\n<div");
                            try writeBlockID(w, blockInfo.attributes);
                            _ = try w.write(" class='tmd-tab-content'>\n");
                            element = try self.renderNextBlocks(w, element.value.nestingDepth, afterElement2, 0);
                            _ = try w.write("\n</div>\n");

                            if (listItem.isLast) {
                                _ = try w.write("\n</div>\n");

                                std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                                self.currentTabListDepth -= 1;
                            }
                        } else {
                            if (listItem.isFirst) {
                                switch (listItem.bulletType()) {
                                    .unordered => _ = try w.write("\n<ul"),
                                    .ordered => _ = try w.write("\n<ol"),
                                }
                                _ = try w.write(" class='tmd-list'>\n");
                            }
                            _ = try w.write("\n<li");
                            try writeBlockID(w, blockInfo.attributes);
                            _ = try w.write(">\n");
                            element = try self.renderBlockChildren(w, element, 0);
                            _ = try w.write("\n</li>\n");
                            if (listItem.isLast) {
                                switch (listItem.bulletType()) {
                                    .unordered => _ = try w.write("\n</ul>\n"),
                                    .ordered => _ = try w.write("\n</ol>\n"),
                                }
                            }
                        }
                    },
                    .indented => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write(" class='tmd-indented'>\n");
                        element = try self.renderBlockChildrenForIndented(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .block_quote => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        if (self.getFollowingLevel1HeaderBlockElement(element)) |_| {
                            _ = try w.write(" class='tmd-block_quote-large'>\n");
                            element = try self.renderBlockChildrenForLargeBlockQuote(w, element, 0);
                        } else {
                            _ = try w.write(" class='tmd-block_quote'>\n");
                            element = try self.renderBlockChildren(w, element, 0);
                        }
                        _ = try w.write("\n</div>\n");
                    },
                    .note_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write(" class='tmd-note_box'>\n");
                        element = try self.renderBlockChildrenForNoteBox(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .disclosure_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write(" class='tmd-disclosure_box'>\n");

                        element = try self.renderBlockChildrenForDisclosure(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .unstyled_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write(" class='tmd-unstyled_box'>\n");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },

                    // atom

                    .header => |header| {
                        element = element.next orelse &self.nullBlockInfoElement;

                        const level = header.level(self.doc.data);

                        if (level == 1 and element.value.blockType == .code_snippet) {
                            _ = try w.print("\n<div", .{});
                            try writeBlockID(w, blockInfo.attributes);
                            _ = try w.print(" class='tmd-code_snippet-header'>", .{});

                            try self.writeUsualContentBlockLines(w, blockInfo, false);

                            _ = try w.print("</div>\n", .{});
                        } else {
                            _ = try w.print("\n<h{}", .{level});
                            try writeBlockID(w, blockInfo.attributes);
                            _ = try w.print(" class='tmd-header-{}'>", .{level});

                            try self.writeUsualContentBlockLines(w, blockInfo, false);

                            _ = try w.print("</h{}>\n", .{level});
                        }
                    },
                    //.footer => {
                    //    _ = try w.write("\n<footer");
                    //    try writeBlockID(w, blockInfo.attributes);
                    //    _ = try w.write(" class='tmd-footer'>\n");
                    //    try self.writeUsualContentBlockLines(w, blockInfo, false);
                    //    _ = try w.write("\n</footer>\n");
                    //
                    //    element = element.next orelse &self.nullBlockInfoElement;
                    //},
                    .usual => |usual| {
                        const usualLine = usual.startLine.lineType.usual;
                        const writeBlank = usualLine.markLen > 0 and usualLine.tokens.empty();

                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write(" class='tmd-usual'>\n");
                        try self.writeUsualContentBlockLines(w, blockInfo, writeBlank);
                        _ = try w.write("\n</div>\n");

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .blank => {
                        //if (!self.lastRenderedBlockIsBlank) {

                        _ = try w.write("\n<p");
                        try writeBlockID(w, blockInfo.attributes);
                        _ = try w.write("></p>\n");

                        //    self.lastRenderedBlockIsBlank = true;
                        //}

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .code_snippet => |code_snippet| {
                        const r = code_snippet.startPlayloadRange();
                        const playload = self.doc.data[r.start..r.end];
                        const attrs = parser.parse_code_block_open_playload(playload);
                        if (attrs.commentedOut) {
                            _ = try w.write("\n<div");
                            try writeBlockID(w, blockInfo.attributes);
                            _ = try w.write("></div>\n");
                        } else {
                            try self.writeCodeBlockLines(w, blockInfo, attrs);
                        }

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .directive => {
                        _ = try w.write("\n<div></div>\n");
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
        firstPlainTextInLink: bool = true,
        urlConfirmedFinally: bool = false,

        fn onLinkInfo(self: *@This(), linkInfo: *tmd.LinkInfo) void {
            self.activeLinkInfo = linkInfo;
            self.firstPlainTextInLink = true;
            self.urlConfirmedFinally = linkInfo.urlConfirmed();
        }
    };

    fn writeCodeBlockLines(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo, attrs: tmd.CodeBlockAttibutes) !void {
        std.debug.assert(blockInfo.blockType == .code_snippet);

        const endLine = blockInfo.getEndLine();
        const startLine = blockInfo.getStartLine();
        std.debug.assert(startLine.lineType == .codeSnippetStart);

        //std.debug.print("\n==========\n", .{});
        //std.debug.print("commentedOut: {}\n", .{attrs.commentedOut});
        //std.debug.print("language: {s}\n", .{@tagName(attrs.language)});
        //std.debug.print("==========\n", .{});

        // ToDo: support customApp on codeSnippetBlock or customAppBlock?

        _ = try w.write("<pre");
        try writeBlockID(w, blockInfo.attributes);
        _ = try w.write(" class='tmd-code_snippet");
        if (attrs.language.len > 0) {
            _ = try w.write("'><code class='language-");
            try writeHtmlAttributeValue(w, attrs.language);
        }
        _ = try w.write("'>");

        var lineInfoElement = startLine.ownerListElement();
        if (startLine != endLine) {
            lineInfoElement = lineInfoElement.next.?;
            while (true) {
                const lineInfo = &lineInfoElement.value;
                switch (lineInfo.lineType) {
                    .codeSnippetEnd => break,
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
            const r = blockInfo.blockType.code_snippet.endPlayloadRange() orelse break :blk;
            const closePlayload = self.doc.data[r.start..r.end];
            const streamAttrs = parser.parse_block_close_playload(closePlayload);
            const content = streamAttrs.content;
            if (content.len == 0) break :blk;
            if (std.ascii.startsWithIgnoreCase(content, "./") or std.ascii.startsWithIgnoreCase(content, "../")) {
                // ToDo: ...
            } else if (std.ascii.startsWithIgnoreCase(content, "#")) {
                const id = content[1..];
                const b = if (self.doc.getBlockByID(id)) |b| b else break :blk;
                const be: *list.Element(tmd.BlockInfo) = @alignCast(@fieldParentPtr("value", b));
                _ = try self.renderCodeForBlockChildren(w, be);
            } else break :blk;
        }

        if (attrs.language.len > 0) {
            _ = try w.write("</code>");
        }
        _ = try w.write("</pre>\n");
    }

    fn writeUsualContentBlockLines(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo, writeBlank: bool) !void {
        if (writeBlank) _ = try w.write("<p></p>\n");

        var tracker: MarkStatusesTracker = .{};

        const endLine = blockInfo.getEndLine();
        var lineInfoElement = blockInfo.getStartLine().ownerListElement();
        while (true) {
            const lineInfo = &lineInfoElement.value;

            {
                var element = lineInfo.tokens().?.head();
                while (element) |tokenInfoElement| {
                    const token = &tokenInfoElement.value;
                    switch (token.tokenType) {
                        .commentText => {},
                        .plainText => blk: {
                            if (tracker.activeLinkInfo) |linkInfo| {
                                if (!tracker.firstPlainTextInLink) {
                                    switch (linkInfo.info) {
                                        .urlSourceText => |sourceText| {
                                            if (sourceText == token) break :blk;
                                        },
                                        else => {},
                                    }
                                }
                                tracker.firstPlainTextInLink = false;
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
                                    if (tracker.urlConfirmedFinally) {
                                        std.debug.assert(tracker.activeLinkInfo.?.info.urlSourceText != null);
                                        const t = tracker.activeLinkInfo.?.info.urlSourceText.?;
                                        linkURL = parser.trim_blanks(self.doc.data[t.start()..t.end()]);
                                    } else {
                                        // ToDo: call custom callback to try to generate a url.
                                    }
                                    if (tracker.urlConfirmedFinally) {
                                        _ = try w.write("<a href='");
                                        _ = try w.write(linkURL);
                                        _ = try w.write("'>");
                                    } else {
                                        _ = try w.write("<span class='tmd-broken-link'>");
                                    }

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
                                    const isInline = blockInfo.hasNonMediaTokens;

                                    writeMedia: {
                                        const mediaInfoToken = mediaInfoElement.value;
                                        std.debug.assert(mediaInfoToken.tokenType == .plainText);

                                        const mediaInfo = self.doc.data[mediaInfoToken.start()..mediaInfoToken.end()];
                                        var it = mem.splitAny(u8, mediaInfo, " \t");
                                        const src = it.first();
                                        if (!std.ascii.startsWithIgnoreCase(src, "./") and !std.ascii.startsWithIgnoreCase(src, "../") and !std.ascii.startsWithIgnoreCase(src, "https://") and !std.ascii.startsWithIgnoreCase(src, "http://")) break :writeMedia;
                                        if (!std.ascii.endsWithIgnoreCase(src, ".png") and !std.ascii.endsWithIgnoreCase(src, ".gif") and !std.ascii.endsWithIgnoreCase(src, ".jpg") and !std.ascii.endsWithIgnoreCase(src, ".jpeg")) break :writeMedia;

                                        // ToDo: read more arguments.

                                        // ToDo: need do more for url validation.

                                        _ = try w.write("<img src=\"");
                                        try writeHtmlAttributeValue(w, src);
                                        if (isInline) {
                                            _ = try w.write("\" class='tmd-inline-media'/>");
                                        } else {
                                            _ = try w.write("\"/>");
                                        }
                                    }

                                    element = mediaInfoElement.next;
                                    continue;
                                },
                                //else => {},
                                //.blockAttributes => blk: {
                                //    if (m.isBare) {
                                //        break :blk;
                                //    }
                                //
                                //    const anchorInfoElement = tokenInfoElement.next.?;
                                //
                                //    {
                                //        const anchorInfoToken = anchorInfoElement.value;
                                //        std.debug.assert(anchorInfoToken.tokenType == .commentText);
                                //
                                //        const anchorInfo = self.doc.data[anchorInfoToken.start()..anchorInfoToken.end()];
                                //        const id = parser.parse_anchor_id(anchorInfo);
                                //        if (id.len > 0) {
                                //            _ = try w.write("<span id=\"");
                                //            try writeHtmlAttributeValue(w, anchorInfo);
                                //            _ = try w.write("\"/>");
                                //        }
                                //    }
                                //
                                //    element = tokenInfoElement.next;
                                //    continue;
                                //},
                            }
                        },
                    }

                    element = tokenInfoElement.next;
                }
            }

            if (lineInfo.treatEndAsSpace) _ = try w.write(" ");
            if (lineInfo == endLine) break;
            if (lineInfoElement.next) |next|
                lineInfoElement = next
            else
                unreachable;
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
                    if (tracker.activeLinkInfo == null) break :blk;

                    try writeCloseMarks(w, markElement);

                    {
                        tracker.activeLinkInfo = null;
                        if (tracker.urlConfirmedFinally) {
                            _ = try w.write("</a>");
                        } else {
                            _ = try w.write("</span>");
                        }
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
                _ = try w.write("<span class='tmd-underlined'>");
            },
            .fontWeight => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-pale'>");
                } else {
                    _ = try w.write("<span class='tmd-bold'>");
                }
            },
            .fontStyle => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-revert-italic'>");
                } else {
                    _ = try w.write("<span class='tmd-italic'>");
                }
            },
            .fontSize => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-larger-size'>");
                } else {
                    _ = try w.write("<span class='tmd-smaller-size'>");
                }
            },
            .spoiler => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-secure-spoiler'>");
                } else {
                    _ = try w.write("<span class='tmd-spoiler'>");
                }
            },
            .deleted => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-invisible'>");
                } else {
                    _ = try w.write("<span class='tmd-deleted'>");
                }
            },
            .marked => {
                if (spanMark.secondary) {
                    _ = try w.write("<mark class='tmd-marked-2'>");
                } else {
                    _ = try w.write("<mark class='tmd-marked'>");
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
                    _ = try w.write("<code class='tmd-mono-font'>");
                } else {
                    _ = try w.write("<code class='tmd-code-span'>");
                }
            },
            .escaped => {
                if (spanMark.secondary) {
                    _ = try w.write("<span class='tmd-keep-whitespaces'>");
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

    fn writeBlockID(w: anytype, attributes: ?*tmd.BlockAttibutes) !void {
        if (attributes) |attrs| {
            const id = if (attrs.id.len > 0) attrs.id else return;
            _ = try w.write(" id='");
            _ = try w.write(id);
            _ = try w.write("'");
        }
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

    fn renderCodeForBlockChildren(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement) !*BlockInfoElement {
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
                        try self.renderCodeOfLine(w, base.openLine);
                        element = try self.renderCodeForBlockChildren(w, element);
                        if (base.closeLine) |closeLine| try self.renderCodeOfLine(w, closeLine);
                    },

                    // containers

                    .list_item, .indented, .block_quote, .note_box, .disclosure_box, .unstyled_box => {
                        element = try self.renderCodeForBlockChildren(w, element);
                    },

                    // atom

                    .header, .usual, .blank, .code_snippet, .directive => {
                        const endLine = blockInfo.getEndLine();
                        var lineInfo = blockInfo.getStartLine();
                        while (true) {
                            try self.renderCodeOfLine(w, lineInfo);
                            if (lineInfo == endLine) break;

                            const lineElement: *list.Element(tmd.LineInfo) = @alignCast(@fieldParentPtr("value", lineInfo));
                            if (lineElement.next) |next| {
                                lineInfo = &next.value;
                            } else break;
                        }

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                }
            }
        }

        return &self.nullBlockInfoElement;
    }

    fn renderCodeOfLine(self: *TmdRender, w: anytype, lineInfo: *tmd.LineInfo) !void {
        const r = lineInfo.range;
        try writeHtmlContentText(w, self.doc.data[r.start..r.end]);
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
    );
    _ = try w.write(css_style);
    _ = try w.write(
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
