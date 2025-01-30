const std = @import("std");

const tmd = @import("tmd.zig");

// For "tmd fmt" command.
//
// ToDo:
// * test 1: the output HTML contents should be identical
//           from the doc and formatted doc.
// * test 2: format a formatted doc is a no-op.

pub fn tmd_format(tmdDoc: *const tmd.Doc) !void {
    _ = tmdDoc;
}
