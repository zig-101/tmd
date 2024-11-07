const list = @import("list.zig");
const std = @import("std");

fn dump(_: u8) void {}

test "list" {
    var l = list.List(u8){};
    var e1 = list.Element(u8){ .value = @intCast(1) };
    var e2 = list.Element(u8){ .value = @intCast(2) };
    var e3 = list.Element(u8){ .value = @intCast(3) };
    l.push(&e1);
    l.push(&e2);
    l.push(&e3);
    l.iterate(dump);

    _ = l.pop();
    l.iterate(dump);
}
