test {
    _ = @import("line_end_spacing.zig");
    _ = @import("line_end_types.zig");
    _ = @import("block_types.zig");
    _ = @import("block_nesting.zig");
    _ = @import("span_contents.zig");
    _ = @import("span_marks.zig");
    _ = @import("block_properties.zig");
    _ = @import("link_matching.zig");
}

const std = @import("std");
const tmd = @import("tmd");

pub fn Buffer(comptime N: usize) type {
    return struct {
        _buffer: [N]u8 = undefined,
        _len: usize = 0,

        pub fn used(self: *const @This()) []const u8 {
            return self._buffer[0..self._len];
        }

        pub fn append(self: *@This(), data: []const u8) !void {
            if (data.len > N - self._len) {
                std.mem.copyForwards(u8, self._buffer[self._len..N], data[0 .. N - self._len]);
                self._len = N;
                return error.BufferOverflow;
            }

            const newLen = self._len + data.len;
            std.mem.copyForwards(u8, self._buffer[self._len..newLen], data);
            self._len = newLen;
        }
    };
}

test "Buffer" {
    const BufLen = 123;
    var buf: Buffer(BufLen) = .{};
    try std.testing.expect(buf.used().len == 0);
    buf = .{};
    try std.testing.expect(buf.used().len == 0);
    try buf.append("");
    try std.testing.expect(buf.used().len == 0);
    buf = .{};
    try std.testing.expect(buf.used().len == 0);

    const text = "abcdefghijklmnopqrstuvwxyz";
    try buf.append(text);
    try std.testing.expect(buf.used().len == text.len);
    try buf.append(text);
    try buf.append(text);
    try buf.append(text);
    try std.testing.expect(buf.used().len == text.len * 4);
    blk: {
        buf.append(text) catch |err| {
            try std.testing.expect(buf.used().len == BufLen);
            try std.testing.expect(err == error.BufferOverflow);
            const n = BufLen - text.len * 4;
            try std.testing.expectEqualStrings(buf.used()[text.len * 4 ..], text[0..n]);
            break :blk;
        };
        unreachable;
    }
    buf = .{};
    try std.testing.expect(buf.used().len == 0);
}

pub const DocChecker = struct {
    pub fn check(data: []const u8, checkFn: fn (*const tmd.Doc) anyerror!bool) !bool {
        var doc = try tmd.Doc.parse(data, std.testing.allocator);
        defer doc.destroy();

        return checkFn(&doc);
    }
};

test "DocChecker" {
    try std.testing.expect(try DocChecker.check("", struct {
        fn check(_: *const tmd.Doc) !bool {
            return true;
        }
    }.check));

    try std.testing.expect(try DocChecker.check("", struct {
        fn check(_: *const tmd.Doc) !bool {
            return false;
        }
    }.check) == false);

    try std.testing.expect(DocChecker.check("", struct {
        fn check(_: *const tmd.Doc) !bool {
            return error.Nothing;
        }
    }.check) == error.Nothing);
}

pub const RenderChecker = struct {
    pub fn check(data: []const u8, completeHTML: bool, v: anytype) !bool {
        var doc = try tmd.Doc.parse(data, std.testing.allocator);
        defer doc.destroy();

        var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 1 << 20);
        defer buf.deinit();

        try doc.toHTML(buf.writer(), completeHTML, true, "", std.testing.allocator);
        const html = buf.items;

        return v.checkFn(html);
    }
};

test "RenderChecker" {
    try std.testing.expect(try RenderChecker.check("", true, struct {
        fn checkFn(_: []const u8) !bool {
            return true;
        }
    }));

    try std.testing.expect(try RenderChecker.check("", true, struct {
        fn checkFn(_: []const u8) !bool {
            return false;
        }
    }) == false);

    try std.testing.expect(RenderChecker.check("", true, struct {
        fn checkFn(_: []const u8) !bool {
            return error.Nothing;
        }
    }) == error.Nothing);
}
