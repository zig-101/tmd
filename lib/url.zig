const std = @import("std");
const mem = std.mem;

pub fn isValidURL(text: []const u8) bool {
    return mem.startsWith(u8, text, "http"); // ToDo: ...
}
