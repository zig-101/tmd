const std = @import("std");
const mem = std.mem;

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");

const AttributeParser = @import("tmd_parser-attribute_parser.zig");
const LineScanner = @import("tmd_parser-line_scanner.zig");
const DocParser = @import("tmd_parser-doc_parser.zig");

const LinkMatcher = @This();

tmdData: []const u8,
links: *list.List(tmd.Link),
allocator: mem.Allocator,

// Match link definitions.

fn tokenAsString(self: *const LinkMatcher, plainTextTokenInfo: *const tmd.TokenInfo) []const u8 {
    return self.tmdData[plainTextTokenInfo.start()..plainTextTokenInfo.end()];
}

fn copyLinkText(dst: anytype, from: u32, src: []const u8) u32 {
    var n: u32 = from;
    for (src) |r| {
        std.debug.assert(r != '\n');
        if (dst.set(n, r)) n += 1;
    }
    return n;
}

const DummyLinkText = struct {
    //lastIsSpace: bool = false,
    pub fn set(_: *DummyLinkText, _: u32, r: u8) bool {
        if (LineScanner.bytesKindTable[r].isBlank()) {
            //if (!self.lastIsSpace and LineScanner.bytesKindTable[r].isSpace()) {
            //    self.lastIsSpace = true;
            //    return true;
            //}
            return false;
        }
        //self.lastIsSpace = false;
        return true;
    }
};

const RealLinkText = struct {
    text: [*]u8,
    dummy: DummyLinkText = .{},
    pub fn set(self: *RealLinkText, n: u32, r: u8) bool {
        if (self.dummy.set(n, r)) {
            self.text[n] = r;
            return true;
        }
        return false;
    }
};

const RevisedLinkText = struct {
    len: u32 = 0,
    text: [*]const u8 = "".ptr,

    pub fn get(self: *const RevisedLinkText, n: u32) u8 {
        std.debug.assert(n < self.len);
        return self.text[n];
    }

    pub fn suffix(self: *const RevisedLinkText, from: u32) RevisedLinkText {
        std.debug.assert(from < self.len); // deliborately not <=
        return RevisedLinkText{
            .len = self.len - from,
            .text = self.text + from,
        };
    }

    pub fn prefix(self: *const RevisedLinkText, to: u32) RevisedLinkText {
        std.debug.assert(to < self.len); // deliborately not <=
        return RevisedLinkText{
            .len = to,
            .text = self.text,
        };
    }

    pub fn unprefix(self: *const RevisedLinkText, unLen: u32) RevisedLinkText {
        return RevisedLinkText{
            .len = self.len + unLen,
            .text = self.text - unLen,
        };
    }

    pub fn asString(self: *const RevisedLinkText) []const u8 {
        return self.text[0..self.len];
    }

    pub fn invert(t: *const RevisedLinkText) InvertedRevisedLinkText {
        return InvertedRevisedLinkText{
            .len = t.len,
            .text = t.text + t.len - 1, // -1 is to make some conveniences
        };
    }
};

// ToDo: this and the above types should not be public.
//       Merge this file with the parser file?
const InvertedRevisedLinkText = struct {
    len: u32 = 0,
    text: [*]const u8 = "".ptr,

    pub fn get(self: *const InvertedRevisedLinkText, n: u32) u8 {
        std.debug.assert(n < self.len);
        return (self.text - n)[0];
    }

    pub fn suffix(self: *const InvertedRevisedLinkText, from: u32) InvertedRevisedLinkText {
        std.debug.assert(from < self.len);
        return InvertedRevisedLinkText{
            .len = self.len - from,
            .text = self.text - from,
        };
    }

    pub fn prefix(self: *const InvertedRevisedLinkText, to: u32) InvertedRevisedLinkText {
        std.debug.assert(to < self.len);
        return InvertedRevisedLinkText{
            .len = to,
            .text = self.text,
        };
    }

    pub fn unprefix(self: *const InvertedRevisedLinkText, unLen: u32) InvertedRevisedLinkText {
        return InvertedRevisedLinkText{
            .len = self.len + unLen,
            .text = self.text + unLen,
        };
    }

    pub fn asString(self: *const InvertedRevisedLinkText) []const u8 {
        return (self.text - self.len + 1)[0..self.len];
    }
};

fn Patricia(comptime TextType: type) type {
    return struct {
        allocator: mem.Allocator,

        topTree: Tree = .{},
        nilNode: Node = .{
            .color = .black,
            .value = .{},
        },

        freeNodeList: ?*Node = null,

        const rbtree = tree.RedBlack(NodeValue, NodeValue);
        const Tree = rbtree.Tree;
        const Node = rbtree.Node;

        fn init(self: *@This()) void {
            self.topTree.init(&self.nilNode);
        }

        fn deinit(self: *@This()) void {
            self.clear();

            while (self.tryToGetFreeNode()) |node| {
                self.allocator.destroy(node);
            }
        }

        fn clear(self: *@This()) void {
            const PatriciaTree = @This();

            const NodeHandler = struct {
                t: *PatriciaTree,

                pub fn onNode(h: @This(), node: *Node) void {
                    //node.value = .{};
                    h.t.freeNode(node);
                }
            };

            const handler = NodeHandler{ .t = self };
            self.topTree.traverseNodes(handler);
            self.topTree.reset();
        }

        fn tryToGetFreeNode(self: *@This()) ?*Node {
            if (self.freeNodeList) |node| {
                if (node.value.deeperTree.count == 0) {
                    self.freeNodeList = null;
                } else {
                    std.debug.assert(node.value.deeperTree.count == 1);
                    self.freeNodeList = node.value.deeperTree.root;
                    node.value.deeperTree.count = 0;
                }
                return node;
            }
            return null;
        }

        fn getFreeNode(self: *@This()) !*Node {
            const n = self.tryToGetFreeNode() orelse try self.allocator.create(Node);

            n.* = .{
                .value = .{},
            };
            n.value.init(&self.nilNode);

            //n.value.textSegment is undefined (deliborately).
            //std.debug.assert(n.value.textSegment.len == 0);
            std.debug.assert(n.value.deeperTree.count == 0);
            std.debug.assert(n.value.linkInfos.empty());

            return n;
        }

        fn freeNode(self: *@This(), node: *Node) void {
            //std.debug.assert(node.value.linkInfos.empty());

            node.value.textSegment.len = 0;
            if (self.freeNodeList) |old| {
                node.value.deeperTree.root = old;
                node.value.deeperTree.count = 1;
            } else {
                node.value.deeperTree.count = 0;
            }
            self.freeNodeList = node;
        }

        const NodeValue = struct {
            textSegment: TextType = undefined,
            linkInfos: list.List(*tmd.LinkInfo) = .{},
            deeperTree: Tree = .{},

            fn init(self: *@This(), nilNodePtr: *Node) void {
                self.deeperTree.init(nilNodePtr);
            }

            // ToDo: For https://github.com/ziglang/zig/issues/18478,
            //       this must be marked as public.
            pub fn compare(x: @This(), y: @This()) isize {
                if (x.textSegment.len == 0 and y.textSegment.len == 0) return 0;
                if (x.textSegment.len == 0) return -1;
                if (y.textSegment.len == 0) return 1;
                return @as(isize, x.textSegment.get(0)) - @as(isize, y.textSegment.get(0));
            }

            fn commonPrefixLen(x: *const @This(), y: *const @This()) u32 {
                const lx = x.textSegment.len;
                const ly = y.textSegment.len;
                const n = if (lx < ly) lx else ly;
                for (0..n) |i| {
                    const k: u32 = @intCast(i);
                    if (x.textSegment.get(k) != y.textSegment.get(k)) {
                        return k;
                    }
                }
                return n;
            }
        };

        fn putLinkInfo(self: *@This(), text: TextType, linkInfoElement: *list.Element(*tmd.LinkInfo)) !void {
            var node = try self.getFreeNode();
            node.value.textSegment = text;

            var n = try self.putNodeIntoTree(&self.topTree, node);
            if (n != node) self.freeNode(node);

            // ToDo: also free text ... ?

            //var element = try self.getFreeLinkInfoElement();
            //element.value = linkInfo;
            n.value.linkInfos.push(linkInfoElement);
        }

        fn putNodeIntoTree(self: *@This(), theTree: *Tree, node: *Node) !*Node {
            const n = theTree.insert(node);
            //std.debug.print("   111, theTree.root.text={s}\n", .{theTree.root.value.textSegment.asString()});
            //std.debug.print("   111, n.value.textSegment={s}, {}\n", .{ n.value.textSegment.asString(), n.value.textSegment.len });
            //std.debug.print("   111, node.value.textSegment={s}, {}\n", .{ node.value.textSegment.asString(), node.value.textSegment.len });
            if (n == node) { // node is added successfully
                return n;
            }

            // n is an old already existing node.

            const k = NodeValue.commonPrefixLen(&n.value, &node.value);
            std.debug.assert(k <= n.value.textSegment.len);
            std.debug.assert(k <= node.value.textSegment.len);

            //std.debug.print("   222 k={}\n", .{k});

            if (k == n.value.textSegment.len) {
                //std.debug.print("   333 k={}\n", .{k});
                if (k == node.value.textSegment.len) {
                    return n;
                }

                //std.debug.print("   444 k={}\n", .{k});
                // k < node.value.textSegment.len

                node.value.textSegment = node.value.textSegment.suffix(k);
                return self.putNodeIntoTree(&n.value.deeperTree, node);
            }

            //std.debug.print("   555 k={}\n", .{k});
            // k < n.value.textSegment.len

            if (k == node.value.textSegment.len) {
                //std.debug.print("   666 k={}\n", .{k});

                n.fillNodeWithoutValue(node);

                if (!theTree.checkNilNode(n.parent)) {
                    if (n == n.parent.left) n.parent.left = node else n.parent.right = node;
                }
                if (!theTree.checkNilNode(n.left)) n.left.parent = node;
                if (!theTree.checkNilNode(n.right)) n.right.parent = node;
                if (n == theTree.root) theTree.root = node;

                n.value.textSegment = n.value.textSegment.suffix(k);
                _ = try self.putNodeIntoTree(&node.value.deeperTree, n);
                std.debug.assert(node.value.deeperTree.count == 1);

                return node;
            }
            // k < node.value.textSegment.len

            var newNode = try self.getFreeNode();
            newNode.value.textSegment = node.value.textSegment.prefix(k);
            n.fillNodeWithoutValue(newNode);

            //std.debug.print("   777 k={}, newNode.text={s}\n", .{ k, newNode.value.textSegment.asString() });

            if (!theTree.checkNilNode(n.parent)) {
                if (n == n.parent.left) n.parent.left = newNode else n.parent.right = newNode;
            }
            if (!theTree.checkNilNode(n.left)) n.left.parent = newNode;
            if (!theTree.checkNilNode(n.right)) n.right.parent = newNode;
            if (n == theTree.root) theTree.root = newNode;

            n.value.textSegment = n.value.textSegment.suffix(k);
            _ = try self.putNodeIntoTree(&newNode.value.deeperTree, n);

            //std.debug.print("   888 count={}\n", .{newNode.value.deeperTree.count});
            std.debug.assert(newNode.value.deeperTree.count == 1);
            defer std.debug.assert(newNode.value.deeperTree.count == 2);
            //defer std.debug.print("   999 count={}\n", .{newNode.value.deeperTree.count});

            node.value.textSegment = node.value.textSegment.suffix(k);
            return self.putNodeIntoTree(&newNode.value.deeperTree, node);
        }

        fn searchLinkInfo(self: *const @This(), text: TextType, prefixMatching: bool) ?*Node {
            var theText = text;
            var theTree = &self.topTree;
            while (true) {
                //std.debug.print(" aaa, text={s}\n", .{theText.asString()});
                //std.debug.print(" aaa 111, root={s}\n", .{theTree.root.value.textSegment.asString()});

                const nodeValue = NodeValue{ .textSegment = theText };
                if (theTree.search(nodeValue)) |n| {
                    const k = NodeValue.commonPrefixLen(&n.value, &nodeValue);
                    //std.debug.print("  bbb. {}, {}, {s}\n", .{ k, n.value.textSegment.len, n.value.textSegment.asString() });
                    if (n.value.textSegment.len < theText.len) {
                        //std.debug.print("    ccc 111\n", .{});
                        if (k < n.value.textSegment.len) break;
                        std.debug.assert(k == n.value.textSegment.len);
                        theTree = &n.value.deeperTree;
                        theText = theText.suffix(k);
                        //std.debug.print("    ccc 222, {}, k={}, text={s}\n", .{ theTree.count, k, theText.asString() });
                        //std.debug.print("    ccc 222, root={s}\n", .{theTree.root.value.textSegment.asString()});
                        continue;
                    } else {
                        //std.debug.print("    ddd 111\n", .{});
                        if (k < theText.len) break;
                        //std.debug.print("    ddd 222\n", .{});
                        std.debug.assert(k == theText.len);
                        if (prefixMatching) return n;
                        //std.debug.print("    ddd 333\n", .{});
                        if (n.value.textSegment.len == theText.len) return n;
                        //std.debug.print("    ddd 444\n", .{});
                        break;
                    }
                } else break;
            }
            return null;
        }

        fn setUrlSourceForNode(node: *Node, urlSource: ?*tmd.TokenInfo, confirmed: bool, attrs: ?*tmd.ElementAttibutes) void {
            var le = node.value.linkInfos.head();
            while (le) |linkInfoElement| {
                if (linkInfoElement.value.info != .urlSourceText) {
                    //std.debug.print("    333 aaa exact match, found and setSourceOfURL.\n", .{});
                    linkInfoElement.value.setSourceOfURL(urlSource, confirmed);
                    linkInfoElement.value.attrs = attrs;
                } else {
                    //std.debug.print("    333 aaa exact match, found but sourceURL has set.\n", .{});
                }
                le = linkInfoElement.next;
            }

            if (node.value.deeperTree.count == 0) {
                // ToDo: delete the node (not necessary).
            }
        }

        fn setUrlSourceForTreeNodes(theTree: *Tree, urlSource: ?*tmd.TokenInfo, confirmed: bool, attrs: ?*tmd.ElementAttibutes) void {
            const NodeHandler = struct {
                urlSource: ?*tmd.TokenInfo,
                confirmed: bool,
                attrs: ?*tmd.ElementAttibutes,

                pub fn onNode(h: @This(), node: *Node) void {
                    setUrlSourceForTreeNodes(&node.value.deeperTree, h.urlSource, h.confirmed, h.attrs);
                    setUrlSourceForNode(node, h.urlSource, h.confirmed, h.attrs);
                }
            };

            const handler = NodeHandler{ .urlSource = urlSource, .confirmed = confirmed, .attrs = attrs };
            theTree.traverseNodes(handler);
        }
    };
}

const LinkForTree = struct {
    linkInfoElementNormal: list.Element(*tmd.LinkInfo),
    linkInfoElementInverted: list.Element(*tmd.LinkInfo),
    revisedLinkText: RevisedLinkText,

    fn setInfoAndText(self: *@This(), linkInfo: *tmd.LinkInfo, text: RevisedLinkText) void {
        self.linkInfoElementNormal.value = linkInfo;
        self.linkInfoElementInverted.value = linkInfo;
        self.revisedLinkText = text;
    }

    fn info(self: *const @This()) *tmd.LinkInfo {
        std.debug.assert(self.linkInfoElementNormal.value == self.linkInfoElementInverted.value);
        return self.linkInfoElementNormal.value;
    }
};

fn destroyRevisedLinkText(link: *LinkForTree, a: mem.Allocator) void {
    a.free(link.revisedLinkText.asString());
}

const NormalPatricia = Patricia(RevisedLinkText);
const InvertedPatricia = Patricia(InvertedRevisedLinkText);

const Matcher = struct {
    normalPatricia: *NormalPatricia,
    invertedPatricia: *InvertedPatricia,

    fn doForLinkDefinition(self: @This(), linkDef: *LinkForTree) void {
        const linkInfo = linkDef.info();
        std.debug.assert(linkInfo.inComment());

        const urlSource = linkInfo.info.urlSourceText.?;
        const confirmed = linkInfo.urlConfirmed();
        const attrs = linkInfo.attrs;

        const linkText = linkDef.revisedLinkText.asString();

        //std.debug.print("    333 linkText = {s}\n", .{linkText});

        // ToDo: require that the ending "..." must be amtomic?
        const ddd = "...";
        if (mem.endsWith(u8, linkText, ddd)) {
            if (linkText.len == ddd.len) {
                //std.debug.print("    333 all match.\n", .{});
                // all match

                NormalPatricia.setUrlSourceForTreeNodes(&self.normalPatricia.topTree, urlSource, confirmed, attrs);
                //InvertedPatricia.setUrlSourceForTreeNodes(&self.invertedPatricia.topTree, urlSource, confirmed, attrs);

                self.normalPatricia.clear();
                self.invertedPatricia.clear();
            } else {
                //std.debug.print("    333 leading match.\n", .{});
                // leading match

                const revisedLinkText = linkDef.revisedLinkText.prefix(linkDef.revisedLinkText.len - @as(u32, ddd.len));
                if (self.normalPatricia.searchLinkInfo(revisedLinkText, true)) |node| {
                    NormalPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed, attrs);
                    NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
                } else {
                    //std.debug.print("    333 leading match. Not found.\n", .{});
                }
            }
        } else {
            if (mem.startsWith(u8, linkText, ddd)) {
                //std.debug.print("    333 trailing match.\n", .{});
                // trailing match

                const revisedLinkText = linkDef.revisedLinkText.suffix(@intCast(ddd.len));
                if (self.invertedPatricia.searchLinkInfo(revisedLinkText.invert(), true)) |node| {
                    InvertedPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed, attrs);
                    InvertedPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
                } else {
                    //std.debug.print("    333 trailing match. Not found.\n", .{});
                }
            } else {
                //std.debug.print("    333 exact match.\n", .{});
                // exact match

                if (self.normalPatricia.searchLinkInfo(linkDef.revisedLinkText, false)) |node| {
                    //std.debug.print("    333 exact match, found.\n", .{});
                    NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed, attrs);
                } else {
                    //std.debug.print("    333 exact match, not found.\n", .{});
                }
            }
        }
    }
};

pub fn matchLinks(self: *const LinkMatcher) !void {
    const links = self.links;
    if (links.empty()) return;

    var linksForTree: list.List(LinkForTree) = .{};
    defer list.destroyListElements(LinkForTree, linksForTree, destroyRevisedLinkText, self.allocator);

    var normalPatricia = NormalPatricia{ .allocator = self.allocator };
    normalPatricia.init();
    defer normalPatricia.deinit();

    var invertedPatricia = InvertedPatricia{ .allocator = self.allocator };
    invertedPatricia.init();
    defer invertedPatricia.deinit();

    const matcher = Matcher{
        .normalPatricia = &normalPatricia,
        .invertedPatricia = &invertedPatricia,
    };

    // The top-to-bottom pass.
    var linkElement = links.head().?;
    while (true) {
        const linkInfo = linkElement.value.info;
        switch (linkInfo.info) {
            .urlSourceText => unreachable,
            .firstPlainText => |plainTextToken| blk: {
                const firstTextToken = if (plainTextToken) |first| first else {
                    // The link should be ignored in rendering.

                    //std.debug.print("ignored for no plainText tokens\n", .{});
                    linkInfo.setSourceOfURL(null, false);
                    break :blk;
                };

                var linkTextLen: u32 = 0;
                var lastToken = firstTextToken;
                // count sum length without the last text token
                var dummyLinkText = DummyLinkText{};
                while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                    defer lastToken = nextToken;
                    const str = self.tokenAsString(lastToken);
                    linkTextLen = copyLinkText(&dummyLinkText, linkTextLen, str);
                }

                // handle the last text token
                {
                    const str = LineScanner.trim_blanks(self.tokenAsString(lastToken));
                    if (linkInfo.inComment()) {
                        if (copyLinkText(&dummyLinkText, 0, str) == 0) {
                            // This link definition will be ignored.

                            //std.debug.print("ignored for blank link definition\n", .{});
                            linkInfo.setSourceOfURL(null, false);
                            break :blk;
                        }
                    } else if (AttributeParser.isValidURL(str)) {
                        // For built-in cases, no need to call callback to determine the url.

                        //std.debug.print("self defined url: {s}\n", .{str});
                        linkInfo.setSourceOfURL(lastToken, true);

                        if (lastToken == firstTextToken and mem.startsWith(u8, str, "#")) {
                            linkInfo.setFootnote(true);
                        }

                        break :blk;
                    } else {
                        linkTextLen = copyLinkText(&dummyLinkText, linkTextLen, str);
                    }

                    if (linkTextLen == 0) {
                        // The link should be ignored in rendering.

                        //std.debug.print("ignored for blank link text\n", .{});
                        linkInfo.setSourceOfURL(null, false);
                        break :blk;
                    }
                }

                // build RevisedLinkText

                const textPtr: [*]u8 = (try self.allocator.alloc(u8, linkTextLen)).ptr;
                const revisedLinkText = RevisedLinkText{
                    .len = linkTextLen,
                    .text = textPtr,
                };
                //defer std.debug.print("====={}: ||{s}||\n", .{linkInfo.inComment(), revisedLinkText.asString()});

                const theElement = try self.allocator.create(list.Element(LinkForTree));
                linksForTree.push(theElement);
                theElement.value.setInfoAndText(linkInfo, revisedLinkText);
                const linkForTree = &theElement.value;

                const confirmed = while (true) { // ToDo: use a labled non-loop block
                    var realLinkText = RealLinkText{
                        .text = textPtr, // == revisedLinkText.text,
                    };

                    var linkTextLen2: u32 = 0;
                    lastToken = firstTextToken;
                    // build text data without the last text token
                    while (lastToken.tokenType.plainText.nextInLink) |nextToken| {
                        defer lastToken = nextToken;
                        const str = self.tokenAsString(lastToken);
                        linkTextLen2 = copyLinkText(&realLinkText, linkTextLen2, str);
                    }

                    // handle the last text token
                    const str = LineScanner.trim_blanks(self.tokenAsString(lastToken));
                    if (linkInfo.inComment()) {
                        std.debug.assert(linkTextLen2 == linkTextLen);

                        //std.debug.print("    222 linkText = {s}\n", .{revisedLinkText.asString()});

                        //std.debug.print("==== /{s}/, {}\n", .{ str, AttributeParserisValidURL(str) });

                        break AttributeParser.isValidURL(str);
                    } else {
                        std.debug.assert(!AttributeParser.isValidURL(str));

                        // For a link whose url is not built-in determined,
                        // all of its text tokens are used as link texts.

                        linkTextLen2 = copyLinkText(&realLinkText, linkTextLen2, str);
                        std.debug.assert(linkTextLen2 == linkTextLen);

                        //std.debug.print("    111 linkText = {s}\n", .{revisedLinkText.asString()});

                        try normalPatricia.putLinkInfo(revisedLinkText, &linkForTree.linkInfoElementNormal);
                        try invertedPatricia.putLinkInfo(revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
                        break :blk;
                    }
                };

                std.debug.assert(linkInfo.inComment());

                linkInfo.setSourceOfURL(lastToken, confirmed);
                matcher.doForLinkDefinition(linkForTree);
            },
        }

        if (linkElement.next) |next| {
            linkElement = next;
        } else break;
    }

    // The bottom-to-top pass.
    {
        normalPatricia.clear();
        invertedPatricia.clear();

        var element = linksForTree.tail();
        while (element) |theElement| {
            const linkForTree = &theElement.value;
            const theLinkInfo = linkForTree.info();
            if (theLinkInfo.inComment()) {
                std.debug.assert(theLinkInfo.info == .urlSourceText);
                matcher.doForLinkDefinition(linkForTree);
            } else if (theLinkInfo.info != .urlSourceText) {
                try normalPatricia.putLinkInfo(linkForTree.revisedLinkText, &linkForTree.linkInfoElementNormal);
                try invertedPatricia.putLinkInfo(linkForTree.revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
            }
            element = theElement.prev;
        }
    }

    // The final pass (for still unmatched links).
    {
        var element = linksForTree.head();
        while (element) |theElement| {
            const theLinkInfo = theElement.value.info();
            if (theLinkInfo.info != .urlSourceText) {
                theLinkInfo.setSourceOfURL(theLinkInfo.info.firstPlainText, false);
            }
            element = theElement.next;
        }
    }
}
