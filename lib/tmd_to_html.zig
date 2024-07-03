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

const nullBlockInfoElement = &list.Element(tmd.BlockInfo){
    .value = tmd.BlockInfo{
        // only use the nestingDepth field.
        .nestingDepth = 0,
        .blockType = undefined,
    },
};

const TmdRender = struct {
    doc: tmd.Doc,

    lastRenderedBlockIsBlank: bool = true, // ToDo: need this?

    nullBlockInfoElement: list.Element(tmd.BlockInfo) = .{
        .value = .{
            // only use the nestingDepth field.
            .nestingDepth = 0,
            .blockType = .{
                .blank = .{},
            },
        },
    },

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

    fn renderBlockChildrenForNoteBox(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        var afterElement = parentElement;
        if (afterElement.next) |element| {
            const blockInfo = &element.value;
            if (blockInfo.blockType == .header) {
                if (blockInfo.blockType.header.level(self.doc.data) == 1) {
                    _ = try w.write("<div class='tmd-note_box-header'>");
                    try self.writeUsualContentBlockLines(w, blockInfo);
                    _ = try w.write("</div>");
                    afterElement = element.next orelse &self.nullBlockInfoElement;
                }
            }
        }

        _ = try w.write("\n<div class='tmd-note_box-content'>\n");

        const element = self.renderNextBlocks(w, parentElement.value.nestingDepth, afterElement, atMostCount);
        _ = try w.write("\n</div>\n");
        return element;
    }

    fn renderBlockChildrenForDisclosure(self: *TmdRender, w: anytype, parentElement: *BlockInfoElement, atMostCount: u32) !*BlockInfoElement {
        _ = try w.write("\n<details><summary>\n");

        var afterElement = parentElement;
        if (afterElement.next) |element| {
            const blockInfo = &element.value;
            if (blockInfo.blockType == .header) {
                if (blockInfo.blockType.header.level(self.doc.data) == 1) {
                    try self.writeUsualContentBlockLines(w, blockInfo);
                    afterElement = element.next orelse &self.nullBlockInfoElement;
                }
            }
        }

        _ = try w.write("\n</summary>");

        _ = try w.write("\n<div class='tmd-disclosure_box-content'>");
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
                    .base => |base| blk: {
                        _ = try w.write("\n<div");
                        if (base.openPlayloadRange()) |r| {
                            const playload = self.doc.data[r.start..r.end];
                            const attrs = parser.parse_base_block_open_playload(playload);
                            if (attrs.commentedOut) {
                                _ = try w.write("></div>\n");
                                element = try self.renderBlockChildren(std.io.null_writer, element, 0);
                                break :blk;
                            }
                        }

                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-base'>");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },

                    // containers

                    .list_item => |listItem| {
                        if (listItem.isFirst) {
                            switch (listItem.bulletType()) {
                                .unordered => _ = try w.write("\n<ul"),
                                .ordered => _ = try w.write("\n<ol"),
                            }
                            try writeBlockID(w, blockInfo);
                            _ = try w.write(" class='tmd-list'>\n");
                        }
                        _ = try w.write("\n<li>\n");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</li>\n");
                        if (listItem.isLast) {
                            switch (listItem.bulletType()) {
                                .unordered => _ = try w.write("\n</ul>\n"),
                                .ordered => _ = try w.write("\n</ol>\n"),
                            }
                        }
                    },
                    .indented => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-indented'>\n");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .block_quote => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-block_quote'>\n");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .note_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-note_box'>\n");
                        element = try self.renderBlockChildrenForNoteBox(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .disclosure_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-disclosure_box'>\n");

                        element = try self.renderBlockChildrenForDisclosure(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },
                    .unstyled_box => {
                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-unstyled_box'>\n");
                        element = try self.renderBlockChildren(w, element, 0);
                        _ = try w.write("\n</div>\n");
                    },

                    // atomic

                    .header => |header| {
                        const level = header.level(self.doc.data);

                        _ = try w.print("\n<h{}", .{level});
                        try writeBlockID(w, blockInfo);
                        _ = try w.print(" class='tmd-header-{}'>", .{level});

                        self.lastRenderedBlockIsBlank = false;

                        try self.writeUsualContentBlockLines(w, blockInfo);

                        element = element.next orelse &self.nullBlockInfoElement;

                        _ = try w.print("</h{}>\n", .{level});
                    },

                    .usual => {
                        self.lastRenderedBlockIsBlank = false;

                        _ = try w.write("\n<div");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write(" class='tmd-usual'>\n");
                        try self.writeUsualContentBlockLines(w, blockInfo);
                        _ = try w.write("\n</div>\n");

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .blank => {
                        //if (!self.lastRenderedBlockIsBlank) {

                        _ = try w.write("\n<p");
                        try writeBlockID(w, blockInfo);
                        _ = try w.write("></p>\n");

                        //    self.lastRenderedBlockIsBlank = true;
                        //}

                        element = element.next orelse &self.nullBlockInfoElement;
                    },
                    .code_snippet => |code_snippet| {
                        self.lastRenderedBlockIsBlank = false;

                        const r = code_snippet.startPlayloadRange();
                        const playload = self.doc.data[r.start..r.end];
                        const attrs = parser.parse_code_block_open_playload(playload);
                        if (attrs.commentedOut) {
                            _ = try w.write("\n<div");
                            try writeBlockID(w, blockInfo);
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
        try writeBlockID(w, blockInfo);
        _ = try w.write(" class='tmd-code-block");
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
                    .code => _ = try w.write(self.doc.data[lineInfo.range.start..lineInfo.range.end]),
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

        if (attrs.language.len > 0) {
            _ = try w.write("</code>");
        }
        _ = try w.write("</pre>\n");
    }

    fn writeUsualContentBlockLines(self: *TmdRender, w: anytype, blockInfo: *tmd.BlockInfo) !void {
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
                                        _ = try w.write("\"/>");
                                    }

                                    element = mediaInfoElement.next;
                                    continue;
                                },
                                .anchor => blk: {
                                    if (m.isBare) {
                                        break :blk;
                                    }

                                    const anchorInfoElement = tokenInfoElement.next.?;

                                    {
                                        const anchorInfoToken = anchorInfoElement.value;
                                        std.debug.assert(anchorInfoToken.tokenType == .commentText);

                                        const anchorInfo = self.doc.data[anchorInfoToken.start()..anchorInfoToken.end()];
                                        const id = parser.parse_anchor_id(anchorInfo);
                                        if (id.len > 0) {
                                            _ = try w.write("<span id=\"");
                                            try writeHtmlAttributeValue(w, anchorInfo);
                                            _ = try w.write("\"/>");
                                        }
                                    }

                                    element = tokenInfoElement.next;
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
                    _ = try w.write("<span class='tmd-smaller-size'>");
                } else {
                    _ = try w.write("<span class='tmd-larger-size'>");
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

    fn writeBlockID(w: anytype, blockInfo: *tmd.BlockInfo) !void {
        const attrs = blockInfo.attributes orelse return;
        const id = if (attrs.id.len > 0) attrs.id else return;
        _ = try w.write(" id='");
        _ = try w.write(id);
        _ = try w.write("'");
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
};

const css_style =
    \\<style>
    \\
    \\body {
    \\}
    \\
    \\img {
    \\  vertical-align:middle;
    \\}
    \\
    \\.tmd-doc {
    \\  line-height: 1.5;
    \\}
    \\
    \\.tmd-doc, .tmd-base {
    \\  margin-top: 0px;
    \\  margin-bottom: 0px;
    \\  padding-top: 0px;
    \\  padding-bottom: 0px;
    \\}
    \\
    \\.tmd-list {
    \\  margin-top: 0px;
    \\  margin-bottom: 0px;
    \\}
    \\
    \\.tmd-indented {
    \\  margin-left: 32px;
    \\}
    \\
    \\.tmd-block_quote {
    \\  border-left: solid 3px #888;
    \\  color: #666;
    \\  margin-left: 6px;
    \\  padding-left: 6px;
    \\}
    \\
    \\.tmd-note_box {
    \\  border: solid 1px #000;
    \\  margin: 3px 32px;
    \\  padding: 0px;
    \\}
    \\
    \\.tmd-note_box-header {
    \\  background: #ccc;
    \\  padding: 0 5px;
    \\}
    \\
    \\.tmd-note_box-content {
    \\  padding: 5px;
    \\}
    \\
    \\.tmd-disclosure_box {
    \\  padding-left: 6px;
    \\}
    \\
    \\.tmd-disclosure_box-content {
    \\  margin-left: 18px;
    \\}
    \\
    \\.tmd-unstyled_box {
    \\}
    \\
    \\.tmd-code-block {
    \\  margin-top: 0px;
    \\  margin-bottom: 0px;
    \\  background: #ddd;
    \\  padding: 3px 6px;
    \\}
    \\
    \\
    \\.tmd-bold {
    \\  font-weight: bold;
    \\}
    \\
    \\.tmd-pale {
    \\  opacity:0.5;
    \\}
    \\
    \\.tmd-italic {
    \\  font-style: italic;
    \\}
    \\
    \\.tmd-revert-italic {
    \\  transform: scale(1) rotate(0deg) translate(0px, 0px) skew(10deg, 0deg);
    \\  display: inline-block;
    \\}
    \\
    \\.tmd-smaller-size {
    \\  font-size: smaller;
    \\}
    \\
    \\.tmd-larger-size {
    \\  font-size: larger;
    \\}
    \\
    \\.tmd-spoiler {
    \\  background: black;
    \\  color: black;
    \\  border-bottom: 3px black solid;
    \\}
    \\
    \\.tmd-secure-spoiler {
    \\  color: white;
    \\}
    \\
    \\.tmd-secure-spoiler::selection {
    \\  color: rgba(0, 0, 0, 0.0);
    \\  background: #888;
    \\}
    \\
    \\.tmd-deleted {
    \\  text-decoration: 2px line-through;
    \\}
    \\
    \\.tmd-invisible {
    \\  visibility: hidden;
    \\}
    \\
    \\.tmd-marked {
    \\  background: yellow;
    \\}
    \\
    \\.tmd-marked-2 {
    \\  background: #faa;
    \\}
    \\
    \\.tmd-underlined {
    \\  text-decoration: solid underline 1px;
    \\}
    \\
    \\.tmd-broken-link {
    \\  text-decoration: dotted underline 3px;
    \\}
    \\
    \\.tmd-code-span {
    \\  background: #ddd;
    \\  border: solid 1px #666;
    \\  padding: 1px 2px;
    \\  border-radius: 3px;
    \\}
    \\
    \\.tmd-mono-font {
    \\  border: 0px;
    \\  background: inherit;
    \\  color: inherit;
    \\  padding: inherit;
    \\}
    \\
    \\.tmd-keep-whitespaces {
    \\  white-space: break-spaces;
    \\}
    \\
    \\</style>
    \\
;

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
