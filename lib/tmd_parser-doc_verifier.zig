const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");

fn verifyNextSibling(block: *const tmd.Block, nextSibling: ?*const tmd.Block) void {
    switch (block.blockType) {
        .list => {
            std.debug.assert(nextSibling.?.blockType == .item);
        },
        .item => |item| {
            if (nextSibling) |sibling| {
                if (sibling.blockType == .item)
                    std.debug.assert(block.nextSibling() == sibling)
                else
                    std.debug.assert(item.list.nextSibling() == sibling);
            } else {
                std.debug.assert(block.nextSibling() == null);
                std.debug.assert(item.list.nextSibling() == null);
            }
        },
        else => {
            std.debug.assert(block.nextSibling() == nextSibling);
        },
    }
}

fn verifyBlockSiblings(tmdDoc: *const tmd.Doc) void {
    var lastBlocksAtDepths = [1]*const tmd.Block{undefined} ** tmd.MaxBlockNestingDepth;
    var currentDepthIndex: u32 = 0;
    var block = tmdDoc.rootBlock();
    std.debug.assert(block.nextSibling() == null);
    lastBlocksAtDepths[currentDepthIndex] = block;
    while (block.next()) |nextBlock| {
        std.debug.assert(nextBlock.nestingDepth > 0);
        if (nextBlock.nestingDepth > currentDepthIndex) {
            std.debug.assert(nextBlock.nestingDepth - 1 == currentDepthIndex);
            std.debug.assert(nextBlock.nestingDepth <= tmd.MaxBlockNestingDepth);
        } else if (nextBlock.nestingDepth < currentDepthIndex) {
            for (nextBlock.nestingDepth + 1..currentDepthIndex + 1) |depth| {
                verifyNextSibling(lastBlocksAtDepths[depth], null);
            }
        } else {
            verifyNextSibling(lastBlocksAtDepths[nextBlock.nestingDepth], nextBlock);
        }

        block = nextBlock;
        currentDepthIndex = nextBlock.nestingDepth;
        lastBlocksAtDepths[currentDepthIndex] = block;
    }

    for (0..currentDepthIndex + 1) |depth| {
        verifyNextSibling(lastBlocksAtDepths[depth], null);
    }
}

pub fn verifyTmdDoc(tmdDoc: *const tmd.Doc) void {
    if (builtin.mode != .Debug) return;

    verifyBlockSiblings(tmdDoc);
}
