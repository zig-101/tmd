const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");

const BlockArranger = @This();

// BlockArranger determines block nesting depths.
//const BlockArranger = struct {
root: *tmd.BlockInfo,

stackedBlocks: [tmd.MaxBlockNestingDepth]*tmd.BlockInfo = undefined,
count_1: tmd.BlockNestingDepthType = 0,

openingBaseBlocks: [tmd.MaxBlockNestingDepth]BaseContext = undefined,
baseCount_1: tmd.BlockNestingDepthType = 0,

const BaseContext = struct {
    nestingDepth: tmd.BlockNestingDepthType,
    commentedOut: bool,

    // !!! here, u6 must be larger than tmd.ListItemTypeIndex.
    openingListNestingDepths: [tmd.MaxListNestingDepthPerBase]u6 = [_]u6{0} ** tmd.MaxListNestingDepthPerBase,
    openingListCount: tmd.ListNestingDepthType = 0,
};

pub fn start(root: *tmd.BlockInfo, doc: *tmd.Doc) BlockArranger {
    root.* = .{ .nestingDepth = 0, .blockType = .{
        .root = .{ .doc = doc },
    } };

    var s = BlockArranger{
        .root = root,
        .count_1 = 1, // because of the fake first child
        .baseCount_1 = 0,
    };
    s.stackedBlocks[0] = root;
    s.openingBaseBlocks[0] = BaseContext{
        .nestingDepth = 0,
        .commentedOut = false,
    };
    s.stackedBlocks[s.count_1] = root; // fake first child (for implementation convenience)
    return s;
}

// This function should not be callsed deferredly.
pub fn end(self: *BlockArranger) void {
    while (self.tryToCloseCurrentBaseBlock()) |_| {}
}

// ToDo: change method name to foo_bar style?

pub fn canOpenBaseBlock(self: *const BlockArranger) bool {
    if (self.count_1 == tmd.MaxBlockNestingDepth - 1) {
        return false;
    }
    return self.baseCount_1 < tmd.MaxBlockNestingDepth - 1;
}

pub fn canCloseBaseBlock(self: *const BlockArranger) bool {
    return self.baseCount_1 > 0;
}

pub fn openBaseBlock(self: *BlockArranger, newBaseBlock: *tmd.BlockInfo, firstInContainer: bool, commentedOut: bool) !void {
    std.debug.assert(newBaseBlock.blockType == .base);

    if (!self.canOpenBaseBlock()) return error.NestingDepthTooLarge;

    if (firstInContainer) {
        try self.stackAsFirstInContainer(newBaseBlock);
    } else {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);

        if (last.blockType == .blank) {
            try self.stackAsChildOfBase(newBaseBlock);
        } else {
            if (last.blockType == .base) {
                @constCast(last).setNextSibling(newBaseBlock);
            }
            newBaseBlock.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = newBaseBlock;
        }
    }

    const newCommentedOut = commentedOut or self.openingBaseBlocks[self.baseCount_1].commentedOut;
    self.baseCount_1 += 1;
    self.openingBaseBlocks[self.baseCount_1] = BaseContext{
        .nestingDepth = self.count_1,
        .commentedOut = newCommentedOut,
    };

    self.count_1 += 1;
    self.stackedBlocks[self.count_1] = self.root; // fake first child (for implementation convenience)
}

pub fn closeCurrentBaseBlock(self: *BlockArranger) !*tmd.BlockInfo {
    if (!self.canCloseBaseBlock()) return error.NoBaseBlockToClose;

    return self.tryToCloseCurrentBaseBlock() orelse unreachable;
}

pub fn tryToCloseCurrentBaseBlock(self: *BlockArranger) ?*tmd.BlockInfo {
    self.clearListContextInBase(true);

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    const baseBlock = self.stackedBlocks[baseContext.nestingDepth];
    std.debug.assert(baseBlock.blockType == .base or baseBlock.blockType == .root);

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);

    if (last.blockType == .blank) {
        // Ensure the nestingDepth of the blank block.
        last.nestingDepth = baseContext.nestingDepth + 1;
    }

    self.count_1 = baseContext.nestingDepth;
    if (self.baseCount_1 == 0) {
        return null;
    }
    self.baseCount_1 -= 1;
    return baseBlock;
}

pub fn stackAsChildOfBase(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].blockType == .base or self.stackedBlocks[baseContext.nestingDepth].blockType == .root);

    if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
        return error.NestingDepthTooLarge;
    }

    self.clearListContextInBase(false); // here, if the last is a blank, its nestingDepth will be adjusted.

    self.count_1 = baseContext.nestingDepth + 1;

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
    if (last.blockType != .root) last.setNextSibling(blockInfo);

    blockInfo.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = blockInfo;
}

pub fn shouldHeaderChildBeInTOC(self: *BlockArranger) bool {
    return self.stackedBlocks[self.count_1].nestingDepth - 1 == self.baseCount_1 and !self.openingBaseBlocks[self.baseCount_1].commentedOut;
}

pub fn stackContainerBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
    std.debug.assert(blockInfo.isContainer());
    std.debug.assert(blockInfo.blockType != .item);

    try self.stackAsChildOfBase(blockInfo);
}

pub fn assertBaseOpeningListCount(self: *BlockArranger) void {
    if (builtin.mode == .Debug) {
        var baseContext = &self.openingBaseBlocks[self.baseCount_1];

        var count: @TypeOf(baseContext.openingListCount) = 0;
        for (&baseContext.openingListNestingDepths) |d| {
            if (d != 0) count += 1;
        }
        //std.debug.print("==== {} : {}\n", .{ count, baseContext.openingListCount });
        std.debug.assert(count == baseContext.openingListCount);

        if (baseContext.openingListCount > 0) {
            //std.debug.print("assertBaseOpeningListCount {}, {} + {} + 1\n", .{ self.count_1, baseContext.nestingDepth, baseContext.openingListCount });

            std.debug.assert(self.count_1 == baseContext.nestingDepth + baseContext.openingListCount + 1);
        }
    }
}

// Returns whether or not a new list should be created.
pub fn shouldCreateNewList(self: *BlockArranger, markTypeIndex: tmd.ListItemTypeIndex) bool {
    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);

    return baseContext.openingListCount == 0 or baseContext.openingListNestingDepths[markTypeIndex] == 0;
}

// listBlock != null means this is the first item in list.
pub fn stackListItemBlock(self: *BlockArranger, listItemBlock: *tmd.BlockInfo, markTypeIndex: tmd.ListItemTypeIndex, listBlock: ?*tmd.BlockInfo) !void {
    std.debug.assert(listItemBlock.blockType == .item);

    self.assertBaseOpeningListCount();

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);

    const newListItem = &listItemBlock.blockType.item;

    if (listBlock) |theListBlock| {
        std.debug.assert(theListBlock.blockType.list._itemTypeIndex == markTypeIndex);

        if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
            return error.NestingDepthTooLarge;
        }

        if (baseContext.openingListCount == 0) { // start list context
            const last = self.stackedBlocks[self.count_1];
            self.count_1 = baseContext.nestingDepth + 1;
            const prevSibling = self.stackedBlocks[self.count_1];
            if (last.blockType == .blank and last.nestingDepth != self.count_1) {
                prevSibling.setNextSibling(last);
                // Ensure the nestingDepth of the blank block.
                last.nestingDepth = self.count_1;
                // no need to setNextSibling for atom blocks.
            } else if (prevSibling.blockType != .root) { // ! Yes, it might be .root temporarily
                prevSibling.setNextSibling(theListBlock);
            }
        } else std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] == 0);

        //newListItem.isFirst = true;
        //newListItem.firstItem = listItemBlock;
        newListItem.list = theListBlock;

        theListBlock.nestingDepth = self.count_1; // the depth of the list is the same as its children

        listItemBlock.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = listItemBlock;

        baseContext.openingListNestingDepths[markTypeIndex] = self.count_1;
        baseContext.openingListCount += 1;
    } else {
        std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] != 0);

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
        std.debug.assert(last.blockType != .item);

        var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
        var depth = self.count_1 - 1;
        while (depth > baseContext.nestingDepth) : (depth -= 1) {
            std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
            std.debug.assert(self.stackedBlocks[depth].blockType == .item);
            var itemBlock = self.stackedBlocks[depth];
            var item = &itemBlock.blockType.item;
            if (item.list.blockType.list._itemTypeIndex == markTypeIndex) {
                //newListItem.firstItem = item.firstItem;
                itemBlock.setNextSibling(listItemBlock);
                newListItem.list = item.list;
                break;
            }
            //item.isLast = true;
            item.list.blockType.list.lastBullet = item.ownerBlockInfo();
            item.list.blockType.list._lastItemConfirmed = true;
            baseContext.openingListNestingDepths[item.list.blockType.list._itemTypeIndex] = 0;
            deltaCount += 1;
        }

        std.debug.assert(depth > baseContext.nestingDepth);
        std.debug.assert(baseContext.openingListCount > deltaCount);

        if (deltaCount > 0) {
            baseContext.openingListCount -= deltaCount;

            if (last.blockType == .blank) {
                // Ensure the nestingDepth of the blank block.
                last.nestingDepth = depth + 1;

                const lastBulletOfDeeperList = self.stackedBlocks[last.nestingDepth];
                lastBulletOfDeeperList.setNextSibling(last);
            }
        } else {
            std.debug.assert(last.nestingDepth == depth + 1);
        }

        self.count_1 = depth;
        listItemBlock.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = listItemBlock;
    }
}

// ToDo: remove the forClosingBase parameter?
pub fn clearListContextInBase(self: *BlockArranger, forClosingBase: bool) void {
    _ = forClosingBase; // ToDo: the logic will be a bit simpler but might be unnecessary.

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].blockType == .base or self.stackedBlocks[baseContext.nestingDepth].blockType == .root);

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.blockType == .root or last.nestingDepth == self.count_1);
    std.debug.assert(last.blockType != .item);
    defer {
        self.count_1 = baseContext.nestingDepth + 1;
        if (last.blockType == .blank and last.nestingDepth != self.count_1) {
            // prevOfLast might be the last item in a just closed list.
            const prevOfLast = self.stackedBlocks[self.count_1];
            std.debug.assert(prevOfLast.blockType == .root or prevOfLast.nestingDepth == self.count_1);
            if (prevOfLast.blockType != .root) prevOfLast.setNextSibling(last);

            // Ensure the nestingDepth of the blank block.
            last.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = last;
        }
    }

    if (baseContext.openingListCount == 0) {
        return;
    }

    self.assertBaseOpeningListCount();

    {
        var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
        var depth = self.count_1 - 1;
        while (depth > baseContext.nestingDepth) : (depth -= 1) {
            std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
            std.debug.assert(self.stackedBlocks[depth].blockType == .item);
            var item = &self.stackedBlocks[depth].blockType.item;
            //item.isLast = true;
            item.list.blockType.list.lastBullet = item.ownerBlockInfo();
            item.list.blockType.list._lastItemConfirmed = true;
            baseContext.openingListNestingDepths[item.list.blockType.list._itemTypeIndex] = 0;
            deltaCount += 1;
        }

        std.debug.assert(depth == baseContext.nestingDepth);
        std.debug.assert(baseContext.openingListCount == deltaCount);
        baseContext.openingListCount = 0;
    }
}

pub fn stackAsFirstInContainer(self: *BlockArranger, blockInfo: *tmd.BlockInfo) !void {
    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.isContainer());
    std.debug.assert(last.nestingDepth == self.count_1);

    std.debug.assert(blockInfo.blockType != .blank);

    if (self.count_1 >= tmd.MaxBlockNestingDepth - 1) {
        return error.NestingDepthTooLarge;
    }

    self.count_1 += 1;
    blockInfo.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = blockInfo;
}

pub fn stackAtomBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo, firstInContainer: bool) !void {
    std.debug.assert(blockInfo.isAtom());

    if (firstInContainer) {
        try self.stackAsFirstInContainer(blockInfo);
        return;
    }

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.nestingDepth == self.count_1 or last.blockType == .base or last.blockType == .root);
    std.debug.assert(!last.isContainer());

    if (last.blockType == .blank) {
        std.debug.assert(blockInfo.blockType != .blank);
        try self.stackAsChildOfBase(blockInfo);
        return;
    }

    if (last.blockType == .base) {
        @constCast(last).setNextSibling(blockInfo);
    }

    blockInfo.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = blockInfo;
}

pub fn stackFirstLevelHeaderBlock(self: *BlockArranger, blockInfo: *tmd.BlockInfo, firstInContainer: bool) !void {
    if (firstInContainer) {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.isContainer());
        std.debug.assert(last.nestingDepth == self.count_1);
        switch (last.blockType) {
            .item => |*listItem| {
                // listItem.confirmTabItem();
                //listItem.list.blockType.list.isTab = true;
                if (listItem.list.blockType.list.listType == .bullets)
                    listItem.list.blockType.list.listType = .tabs;
            },
            else => {},
        }
    } else {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.nestingDepth == self.count_1 or last.blockType == .base or last.blockType == .root);
        std.debug.assert(!last.isContainer());
        if (last.blockType == .attributes) {
            const container = self.stackedBlocks[self.count_1 - 1];
            switch (container.blockType) {
                .item => |*listItem| {
                    // listItem.confirmTabItem();
                    //listItem.list.blockType.list.isTab = true;
                    if (listItem.list.blockType.list.listType == .bullets)
                        listItem.list.blockType.list.listType = .tabs;
                },
                else => {},
            }
        }
    }

    try self.stackAtomBlock(blockInfo, firstInContainer);
}
//};
