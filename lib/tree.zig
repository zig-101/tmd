const std = @import("std");
const builtin = @import("builtin");

// Ported from https://raw.githubusercontent.com/HuKeping/rbtree/master/rbtree.go,
// which might be ported from https://www.eecs.umich.edu/courses/eecs380/ALG/niemann/s_rbt.txt.

// CompareNamespace must have a
//
//      pub fn compare(Value, Value) isize
//
// function.
//
pub fn RedBlack(comptime Value: type, comptime CompareNamespace: type) type {
    return struct {
        pub const Color = enum { red, black };

        pub const Node = struct {
            parent: *Node = undefined,
            left: *Node = undefined,
            right: *Node = undefined,
            color: Color = .red,

            value: Value,

            pub fn fillNodeWithoutValue(self: *const @This(), node: *Node) void {
                node.parent = self.parent;
                node.left = self.left;
                node.right = self.right;
                node.color = self.color;
            }

            pub fn resetWithoutValue(self: *@This()) void {
                self.color = .red;
            }
        };

        const NodeWithoutValue = struct {
            parent: *Node = undefined,
            left: *Node = undefined,
            right: *Node = undefined,
            color: Color = .red,

            fn fillNode(self: *const @This(), node: *Node) void {
                node.parent = self.parent;
                node.left = self.left;
                node.right = self.right;
                node.color = self.color;
            }

            fn fillNodeWithoutColor(self: *const @This(), node: *Node) void {
                node.parent = self.parent;
                node.left = self.left;
                node.right = self.right;
            }
        };

        pub fn MakeNilNode() Node {
            return .{
                .color = .black,
                .value = undefined,
            };
        }

        pub const Tree = struct {
            root: *Node = undefined,
            count: usize = 0,

            _nilNodePtr: *Node = undefined, // ToDo: use true null instead
            _redNode: NodeWithoutValue = undefined,

            // The lifetime of the tree must be within nilNode.
            // To make operations between different trees concurrently
            // safe, each tree should be provided a unique nilNode.
            // Note: concurrent operations on a specified tree are
            //       always not safe.
            // The color of the provided nilNode must be black.
            pub fn init(t: *Tree, nilNode: *Node) void {
                std.debug.assert(nilNode.color == .black);
                t._nilNodePtr = nilNode;
                t._redNode = .{
                    .parent = t._nilNodePtr,
                    .left = t._nilNodePtr,
                    .right = t._nilNodePtr,
                    .color = .red,
                };
                t.reset();
            }

            pub fn reset(t: *Tree) void {
                t.root = t._nilNodePtr;
                t.count = 0;
            }

            pub fn checkNilNode(t: *const Tree, n: *Node) bool {
                return n == t._nilNodePtr;
            }

            pub fn traverseNodes(t: *const Tree, nodeHandler: anytype) void {
                var current = t.root;
                while (current != t._nilNodePtr) {
                    if (current.left == t._nilNodePtr) {
                        nodeHandler.onNode(current);
                        current = current.right;
                    } else {
                        var pre = current.left;
                        while (pre.right != t._nilNodePtr and pre.right != current) {
                            pre = pre.right;
                        }
                        if (pre.right == t._nilNodePtr) {
                            pre.right = current;
                            current = current.left;
                        } else {
                            pre.right = t._nilNodePtr;
                            const right = current.right; // the next line might modify/destroy current!
                            nodeHandler.onNode(current);
                            current = right;
                        }
                    }
                }
            }

            pub fn search(t: *const Tree, v: Value) ?*Node {
                var p = t.root;
                while (p != t._nilNodePtr) {
                    const c = CompareNamespace.compare(p.value, v);
                    if (c == 0) {
                        return p;
                    }
                    if (c < 0) {
                        p = p.right;
                    } else {
                        p = p.left;
                    }
                }

                return null;
            }

            // Please make sure that the node z is not in tree t now, and
            // the life time of the tree is within the lifetime of the node,
            // If the return Node is z, then it means insertion succeeds;
            // otherwise it means duplication is found (so the insertion is not made).
            pub fn insert(t: *Tree, z: *Node) *Node {
                // Done in the following while loop.
                // if (builtin.mode == .Debug) {
                //   std.debug.assert(t.search(z.value) != z);
                // }

                t._redNode.fillNode(z);

                var x = t.root;
                var y = t._nilNodePtr;

                var less: bool = undefined;
                while (x != t._nilNodePtr) {
                    const c = CompareNamespace.compare(z.value, x.value);
                    if (c == 0) {
                        std.debug.assert(z != x);
                        return x;
                    }
                    y = x;
                    less = c < 0;
                    if (less) {
                        x = x.left;
                    } else {
                        x = x.right;
                    }
                }

                z.parent = y;
                if (y == t._nilNodePtr) { // x == t._nilNodePtr
                    t.root = z;
                } else {
                    if (less) {
                        y.left = z;
                    } else {
                        y.right = z;
                    }
                }

                t.count += 1;
                t.insertFixup(z);
                return z;
            }

            pub fn delete(t: *Tree, v: Value) ?*Node {
                const n = t.search(v);
                if (n) |node| {
                    t.deleteNode(node);
                }
                return n;
            }

            // Note: use this method with caution. Please make sure that
            // z is in t now. We can call the search method to ensure this.
            // If this can't be ensured, please use the delete method instead.
            pub fn deleteNode(t: *Tree, z: *Node) void {
                if (builtin.mode == .Debug) {
                    std.debug.assert(t.search(z.value) == z);
                }

                // y will be put at the position of z.
                var y = if (z.left == t._nilNodePtr or z.right == t._nilNodePtr) z else blk: {
                    var node = z.right;
                    while (node.left != t._nilNodePtr) {
                        node = node.left;
                    }
                    // node is the smallest which is larger than z.
                    break :blk node;
                };

                // x is y's only child .
                std.debug.assert(y.left == t._nilNodePtr or y.right == t._nilNodePtr);
                var x = if (y.left != t._nilNodePtr) y.left else y.right;

                // remove y from top-down.
                // NOTE: x might be t._nilNodePtr (just another reason why t can't be used concurrently?).
                x.parent = y.parent;

                const needToFix = y.color == .black;

                if (y.parent == t._nilNodePtr) {
                    //std.debug.assert(y == z);
                    t.root = x;
                } else {
                    if (y == y.parent.left) {
                        y.parent.left = x;
                    } else {
                        y.parent.right = x;
                    }

                    if (y != z) {
                        z.fillNodeWithoutValue(y);
                    }
                }

                if (needToFix) {
                    t.deleteFixup(x);
                }

                t.count -= 1;

                t._redNode.fillNodeWithoutColor(z);
            }

            fn leftRotate(t: *Tree, x: *Node) void {
                if (x.right == t._nilNodePtr) {
                    return;
                }

                var y = x.right;
                x.right = y.left;
                if (y.left != t._nilNodePtr) {
                    y.left.parent = x;
                }
                y.parent = x.parent;

                if (x.parent == t._nilNodePtr) {
                    t.root = y;
                } else if (x == x.parent.left) {
                    x.parent.left = y;
                } else {
                    x.parent.right = y;
                }

                y.left = x;
                x.parent = y;
            }

            fn rightRotate(t: *Tree, x: *Node) void {
                if (x.left == t._nilNodePtr) {
                    return;
                }

                var y = x.left;
                x.left = y.right;
                if (y.right != t._nilNodePtr) {
                    y.right.parent = x;
                }
                y.parent = x.parent;

                if (x.parent == t._nilNodePtr) {
                    t.root = y;
                } else if (x == x.parent.left) {
                    x.parent.left = y;
                } else {
                    x.parent.right = y;
                }

                y.right = x;
                x.parent = y;
            }

            fn insertFixup(t: *Tree, n: *Node) void {
                var z = n;
                while (z.parent.color == .red) {
                    //
                    // Howerver, we do not need the assertion of non-nil grandparent
                    // because
                    //
                    //  2) The root is black
                    //
                    // Since the color of the parent is .red, so the parent is not root
                    // and the grandparent must be exist.
                    //
                    if (z.parent == z.parent.parent.left) {
                        // Take y as the uncle, although it can be NIL, in that case
                        // its color is .black
                        var y = z.parent.parent.right;
                        if (y.color == .red) {
                            //
                            // Case 1:
                            // parent and uncle are both .red, the grandparent must be .black
                            // due to
                            //
                            //  4) Both children of every red node are black
                            //
                            // Since the current node and its parent are all .red, we still
                            // in violation of 4), So repaint both the parent and the uncle
                            // to .black and grandparent to .red(to maintain 5)
                            //
                            //  5) Every simple path from root to leaves contains the same
                            //     number of black nodes.
                            //
                            z.parent.color = .black;
                            y.color = .black;
                            z.parent.parent.color = .red;
                            z = z.parent.parent;
                        } else {
                            if (z == z.parent.right) {
                                //
                                // Case 2:
                                // parent is .red and uncle is .black and the current node
                                // is right child
                                //
                                // A left rotation on the parent of the current node will
                                // switch the roles of each other. This still leaves us in
                                // violation of 4).
                                // The continuation into Case 3 will fix that.
                                //
                                z = z.parent;
                                t.leftRotate(z);
                            }
                            //
                            // Case 3:
                            // parent is .red and uncle is .black and the current node is
                            // left child
                            //
                            // At the very beginning of Case 3, current node and parent are
                            // both .red, thus we violate 4).
                            // Repaint parent to .black will fix it, but 5) does not allow
                            // this because all paths that go through the parent will get
                            // 1 more black node. Then repaint grandparent to .red (as we
                            // discussed before, the grandparent is .black) and do a right
                            // rotation will fix that.
                            //
                            z.parent.color = .black;
                            z.parent.parent.color = .red;
                            t.rightRotate(z.parent.parent);
                        }
                    } else { // same as then clause with "right" and "left" exchanged
                        var y = z.parent.parent.left;
                        if (y.color == .red) {
                            z.parent.color = .black;
                            y.color = .black;
                            z.parent.parent.color = .red;
                            z = z.parent.parent;
                        } else {
                            if (z == z.parent.left) {
                                z = z.parent;
                                t.rightRotate(z);
                            }
                            z.parent.color = .black;
                            z.parent.parent.color = .red;
                            t.leftRotate(z.parent.parent);
                        }
                    }
                }
                t.root.color = .black;
            }

            fn deleteFixup(t: *Tree, n: *Node) void {
                var x = n;
                while (x != t.root and x.color == .black) {
                    if (x == x.parent.left) {
                        var w = x.parent.right;
                        if (w.color == .red) {
                            w.color = .black;
                            x.parent.color = .red;
                            t.leftRotate(x.parent);
                            w = x.parent.right;
                        }
                        if (w.left.color == .black and w.right.color == .black) {
                            w.color = .red;
                            x = x.parent;
                        } else {
                            if (w.right.color == .black) {
                                w.left.color = .black;
                                w.color = .red;
                                t.rightRotate(w);
                                w = x.parent.right;
                            }
                            w.color = x.parent.color;
                            x.parent.color = .black;
                            w.right.color = .black;
                            t.leftRotate(x.parent);
                            // this is to exit while loop
                            x = t.root;
                        }
                    } else { // the code below is has left and right switched from above
                        var w = x.parent.left;
                        if (w.color == .red) {
                            w.color = .black;
                            x.parent.color = .red;
                            t.rightRotate(x.parent);
                            w = x.parent.left;
                        }
                        if (w.left.color == .black and w.right.color == .black) {
                            w.color = .red;
                            x = x.parent;
                        } else {
                            if (w.left.color == .black) {
                                w.right.color = .black;
                                w.color = .red;
                                t.leftRotate(w);
                                w = x.parent.left;
                            }
                            w.color = x.parent.color;
                            x.parent.color = .black;
                            w.left.color = .black;
                            t.rightRotate(x.parent);
                            x = t.root;
                        }
                    }
                }
                x.color = .black;
            }

            pub fn debugPrint(t: *Tree, comptime printValue: fn (Value) void) void {
                if (builtin.mode != .Debug) return;

                _debugPrint(t, t.root, 0, printValue);
            }

            fn _debugPrint(t: *Tree, n: *Node, level: usize, comptime printValue: fn (Value) void) void {
                if (n != t._nilNodePtr) {
                    for (0..level) |_| {
                        std.debug.print("  ", .{});
                    }
                    printValue(n.value);
                    std.debug.print("\n", .{});
                    _debugPrint(t, n.left, level + 1, printValue);
                    _debugPrint(t, n.right, level + 1, printValue);
                }
            }
        };
    };
}

test "tree" {
    const T = struct {
        v: usize,

        pub fn compare(a: @This(), b: @This()) isize {
            if (a.v < b.v) return -1;
            if (a.v > b.v) return 1;
            return 0;
        }
    };

    const T2 = struct {
        pub fn compare(a: T, b: T) isize {
            if (a.v > b.v) return -1;
            if (a.v < b.v) return 1;
            return 0;
        }
    };

    const N = 10;

    const Test = struct {
        var x: usize = 1;

        fn t(CompareNS: type) type {
            return struct {
                test {
                    const _RedBlack = RedBlack(T, CompareNS);
                    const _Tree = _RedBlack.Tree;
                    const _Node = _RedBlack.Node;

                    var traverser: struct {
                        v: usize = 0,
                        goodCount: usize = 0,

                        pub fn onNode(self: *@This(), node: *_Node) void {
                            if (CompareNS == T) {
                                if (self.v == node.value.v) self.goodCount += 1;
                            }
                            if (CompareNS == T2) {
                                if (N - self.v == node.value.v + 1) self.goodCount += 1;
                            }
                            self.v += 1;
                        }
                    } = .{};

                    var _nilNode = _RedBlack.MakeNilNode();
                    var _tree = _Tree{};
                    _tree.init(&_nilNode);

                    var _nodes: [N]_Node = undefined;
                    for (&_nodes, 0..) |*n, i| {
                        n.value = .{ .v = i };
                        try std.testing.expect(_tree.insert(n) == n);
                    }
                    try std.testing.expect(_tree.count == N);

                    _tree.traverseNodes(&traverser);
                    try std.testing.expect(traverser.goodCount == N);

                    for (0..N) |i| {
                        const n = &_nodes[i];
                        const value: T = .{ .v = i };
                        try std.testing.expect(_tree.search(value) == n);
                    }
                    try std.testing.expect(_tree.count == N);

                    var tempNode = _Node{ .value = undefined };
                    for (&_nodes, 0..) |*n, i| {
                        tempNode.value = .{ .v = i };
                        try std.testing.expect(_tree.insert(&tempNode) == n);
                    }
                    try std.testing.expect(_tree.count == N);

                    for (&_nodes, 0..) |*n, i| {
                        const value: T = .{ .v = i };
                        try std.testing.expect(_tree.delete(value) == n);
                    }
                    try std.testing.expect(_tree.count == 0);

                    traverser = .{};
                    _tree.traverseNodes(&traverser);
                    try std.testing.expect(traverser.goodCount == 0);
                }
            };
        }
    };

    _ = Test.t(T);
    _ = Test.t(T2);
}
