test {
    _ = @import("line_end_spacing.zig");
    _ = @import("span_contents.zig");
}

const std = @import("std");

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
