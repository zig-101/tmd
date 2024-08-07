const std = @import("std");
const mem = std.mem;

pub fn isValidURL(text: []const u8) bool {
    // ToDo: ...
    return mem.startsWith(u8, text, "http") or mem.endsWith(u8, text, ".htm") or mem.endsWith(u8, text, ".html");
}
