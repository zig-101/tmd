const std = @import("std");

const tmd = @import("tmd.zig");

// tmd_to_tmd is the inverse of parsing tmd docs.
pub fn tmd_to_tmd(tmdDoc: *const tmd.Doc, writer: anytype) !void {
    _ = tmdDoc;
    _ = writer;
}
