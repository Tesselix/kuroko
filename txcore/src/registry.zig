//! Object registry, handles and guards (Top-Level Design, "Object registry,
//! handles and guards").
//!
//! Rules: store handles, never raw pointers past the current event; use
//! guards with `defer`. `endEvent` checks that no guard survived the event.

const std = @import("std");

/// Index + generation, 8 bytes. The only thing stored long-term, and usable
/// directly as a Kuroko ID.
pub const Handle = extern struct {
    index: u32,
    generation: u32,

    pub const none: Handle = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn toId(self: Handle) u64 {
        return (@as(u64, self.generation) << 32) | self.index;
    }

    pub fn fromId(id: u64) Handle {
        return .{ .index = @truncate(id), .generation = @truncate(id >> 32) };
    }
};

pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            /// Allocated separately, so its address is stable while guards
            /// hold it, even when `slots` grows.
            value: ?*T,
            generation: u32,
            live: bool,
            guards: u32,
        };

        gpa: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free_list: std.ArrayList(u32) = .empty,
        pending: std.ArrayList(u32) = .empty,
        active_guards: u32 = 0,

        pub const Guard = struct {
            ptr: *T,
            registry: *Self,
            index: u32,

            pub fn release(self: Guard) void {
                const slot = &self.registry.slots.items[self.index];
                slot.guards -= 1;
                self.registry.active_guards -= 1;
            }
        };

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        /// Frees every remaining object. `deinitFn` may be null.
        pub fn deinit(self: *Self, deinitFn: ?*const fn (*T) void) void {
            for (self.slots.items) |*slot| {
                if (slot.value) |v| {
                    if (deinitFn) |f| f(v);
                    self.gpa.destroy(v);
                }
            }
            self.slots.deinit(self.gpa);
            self.free_list.deinit(self.gpa);
            self.pending.deinit(self.gpa);
        }

        pub fn create(self: *Self, value: T) !Handle {
            const ptr = try self.gpa.create(T);
            errdefer self.gpa.destroy(ptr);
            ptr.* = value;
            if (self.free_list.pop()) |index| {
                const slot = &self.slots.items[index];
                slot.value = ptr;
                slot.live = true;
                slot.guards = 0;
                return .{ .index = index, .generation = slot.generation };
            }
            try self.slots.append(self.gpa, .{ .value = ptr, .generation = 1, .live = true, .guards = 0 });
            return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
        }

        /// Returns null when the object is gone, so every caller must handle
        /// that case. Release with `defer guard.release()`.
        pub fn acquire(self: *Self, h: Handle) ?Guard {
            if (h.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.index];
            if (!slot.live or slot.generation != h.generation) return null;
            slot.guards += 1;
            self.active_guards += 1;
            return .{ .ptr = slot.value.?, .registry = self, .index = h.index };
        }

        pub fn isLive(self: *const Self, h: Handle) bool {
            if (h.index >= self.slots.items.len) return false;
            const slot = self.slots.items[h.index];
            return slot.live and slot.generation == h.generation;
        }

        /// Idempotent. Marks the object dead and bumps the generation, so
        /// every later `acquire` with an old handle returns null. The memory
        /// is freed by `collect` once no guard holds it.
        pub fn destroy(self: *Self, h: Handle) void {
            if (!self.isLive(h)) return;
            const slot = &self.slots.items[h.index];
            slot.live = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.pending.append(self.gpa, h.index) catch {
                // Out of memory: keep the slot dead and leak it rather than
                // freeing memory that may still be in use.
            };
        }

        /// Frees dead objects with no guards. Call at the end of a frame.
        pub fn collect(self: *Self, deinitFn: ?*const fn (*T) void) void {
            var i: usize = 0;
            while (i < self.pending.items.len) {
                const index = self.pending.items[i];
                const slot = &self.slots.items[index];
                if (slot.guards == 0) {
                    if (slot.value) |v| {
                        if (deinitFn) |f| f(v);
                        self.gpa.destroy(v);
                    }
                    slot.value = null;
                    self.free_list.append(self.gpa, index) catch {};
                    _ = self.pending.swapRemove(i);
                } else i += 1;
            }
        }

        /// No guard may survive the current event. One integer check, kept
        /// on in ReleaseSafe.
        pub fn endEvent(self: *const Self) void {
            if (self.active_guards != 0) @panic("registry: guard held past the end of an event");
        }

        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots.items) |s| {
                if (s.live) n += 1;
            }
            return n;
        }

        /// Handles of all live objects, in slot order.
        pub fn handles(self: *const Self, out: *std.ArrayList(Handle), gpa: std.mem.Allocator) !void {
            for (self.slots.items, 0..) |s, i| {
                if (s.live) try out.append(gpa, .{ .index = @intCast(i), .generation = s.generation });
            }
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Obj = struct { v: i32, buf: ?[]u8 = null };

fn freeObj(o: *Obj) void {
    if (o.buf) |b| testing.allocator.free(b);
}

test "acquire, destroy, stale handle" {
    var reg = Registry(Obj).init(testing.allocator);
    defer reg.deinit(freeObj);

    const h = try reg.create(.{ .v = 1 });
    {
        const g = reg.acquire(h) orelse return error.Gone;
        defer g.release();
        g.ptr.v = 2;
    }
    reg.endEvent();
    reg.destroy(h);
    reg.destroy(h); // idempotent
    try testing.expect(reg.acquire(h) == null);
    reg.collect(freeObj);

    // The slot is reused with a new generation; the old handle stays dead.
    const h2 = try reg.create(.{ .v = 3 });
    try testing.expectEqual(h.index, h2.index);
    try testing.expect(h.generation != h2.generation);
    try testing.expect(reg.acquire(h) == null);
}

test "an object is not freed while a guard holds it" {
    var reg = Registry(Obj).init(testing.allocator);
    defer reg.deinit(freeObj);
    const h = try reg.create(.{ .v = 1, .buf = try testing.allocator.alloc(u8, 16) });
    const g = reg.acquire(h).?;
    reg.destroy(h);
    reg.collect(freeObj);
    try testing.expectEqual(@as(i32, 1), g.ptr.v); // still valid memory
    g.release();
    reg.collect(freeObj);
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "pointers stay valid when the registry grows" {
    var reg = Registry(Obj).init(testing.allocator);
    defer reg.deinit(null);
    const h = try reg.create(.{ .v = 7 });
    const g = reg.acquire(h).?;
    defer g.release();
    for (0..100) |i| _ = try reg.create(.{ .v = @intCast(i) });
    try testing.expectEqual(@as(i32, 7), g.ptr.v);
}

test "handle id round-trip" {
    const h: Handle = .{ .index = 5, .generation = 9 };
    try testing.expect(Handle.fromId(h.toId()).eql(h));
}
