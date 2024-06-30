const std = @import("std");

pub fn List(comptime Value: type) type {
    return struct {
        info: ?struct {
            head: *Element(Value),
            tail: *Element(Value),
        } = null,

        const Self = @This();

        pub fn empty(self: *const Self) bool {
            return self.info == null;
        }

        pub fn head(self: *const Self) ?*Element(Value) {
            return if (self.info) |info| info.head else null;
        }

        pub fn tail(self: *const Self) ?*Element(Value) {
            return if (self.info) |info| info.tail else null;
        }

        // e must not be in any list.
        pub fn push(self: *Self, e: *Element(Value)) void {
            if (self.info) |*info| {
                info.tail.next = e;
                e.prev = info.tail;
                info.tail = e;
            } else {
                self.info = .{
                    .head = e,
                    .tail = e,
                };
                e.prev = null;
            }
            e.next = null;
        }

        // ToDo: renamed tp popTail/pushTail
        pub fn pop(self: *Self) ?*Element(Value) {
            if (self.info) |*info| {
                const e = info.tail;
                if (e.prev) |prev| {
                    prev.next = null;
                    info.tail = prev;
                } else {
                    self.info = null;
                }
                return e;
            }

            return null;
        }

        // e must not be in any list.
        pub fn pushHead(self: *Self, e: *Element(Value)) void {
            if (self.info) |*info| {
                info.head.prev = e;
                e.next = info.head;
                info.head = e;
            } else {
                self.info = .{
                    .head = e,
                    .tail = e,
                };
                e.next = null;
            }
            e.prev = null;
        }

        pub fn popHead(self: *Self) ?*Element(Value) {
            if (self.info) |*info| {
                const e = info.head;
                if (e.next) |next| {
                    next.prev = null;
                    info.head = next;
                } else {
                    self.info = null;
                }
                return e;
            }

            return null;
        }

        pub fn delete(self: *Self, e: *Element(Value)) void {
            if (self.info) |*info| {
                if (e == info.head) {
                    _ = self.popHead();
                    return;
                }
                if (e == info.tail) {
                    _ = self.pop();
                    return;
                }
                e.prev.?.next = e.next;
                e.next.?.prev = e.prev;
            } else unreachable;
        }

        pub fn iterate(self: *Self, comptime f: fn (Value) void) void {
            if (self.info) |info| {
                var element = info.head;
                while (element) |e| {
                    const next = e.next;
                    f(e.value);
                    element = next;
                }
            }
        }
    };
}

pub fn Element(comptime Value: type) type {
    return struct {
        value: Value = undefined,
        prev: ?*Element(Value) = null,
        next: ?*Element(Value) = null,
    };
}
