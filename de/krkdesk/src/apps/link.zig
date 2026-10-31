//! What krkdesk tells the compositor about apps (types.DeskApp records): a
//! snapshot when it connects or is asked, then after every save the apps
//! whose shown fields changed and a `saved` marker. Only the fields the
//! compositor uses travel; a digest per app tells what changed.
//!
//! Pure: writes records into a byte list.

const std = @import("std");
const core = @import("krkcore");
const types = core.types;
const format = core.format;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const App = store_mod.App;

pub const Link = struct {
    gpa: std.mem.Allocator,
    /// Key → digest of what the compositor has.
    sent: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn init(gpa: std.mem.Allocator) Link {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Link) void {
        self.forget();
        self.sent.deinit(self.gpa);
    }

    fn forget(self: *Link) void {
        var it = self.sent.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.sent.clearRetainingCapacity();
    }

    fn remember(self: *Link, a: *const App) !void {
        const gop = try self.sent.getOrPut(self.gpa, a.binary);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, a.binary);
        gop.value_ptr.* = digest(a);
    }

    /// Every app, between snapshot markers.
    pub fn snapshot(self: *Link, out: *std.ArrayList(u8), store: *const Store) !void {
        self.forget();
        try marker(self.gpa, out, .snapshot_begin, store.save_count);
        for (store.apps.items) |*a| {
            try appRecord(self.gpa, out, a, store.save_count);
            try self.remember(a);
        }
        try marker(self.gpa, out, .snapshot_end, store.save_count);
    }

    /// After a save: the apps that changed, those that left, and `saved`.
    pub fn changes(self: *Link, out: *std.ArrayList(u8), store: *const Store) !void {
        for (store.apps.items) |*a| {
            if (self.sent.get(a.binary)) |d| if (d == digest(a)) continue;
            try appRecord(self.gpa, out, a, store.save_count);
            try self.remember(a);
        }
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(self.gpa);
        var it = self.sent.keyIterator();
        while (it.next()) |k| {
            if (@constCast(store).findByBinary(k.*) == null) try gone.append(self.gpa, k.*);
        }
        for (gone.items) |k| {
            var extra: std.ArrayList(u8) = .empty;
            defer extra.deinit(self.gpa);
            try format.appendString(self.gpa, &extra, k);
            try format.appendStruct(self.gpa, out, types.desk_app, 1, types.DeskApp{
                .kind = .removed,
                .status = .missing,
                .flags = 0,
                .string_count = 1,
                .save_count = store.save_count,
            }, extra.items);
            const kv = self.sent.fetchRemove(k).?;
            self.gpa.free(kv.key);
        }
        try marker(self.gpa, out, .saved, store.save_count);
    }
};

fn marker(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: types.DeskAppKind, save_count: u64) !void {
    try format.appendStruct(gpa, out, types.desk_app, 1, types.DeskApp{
        .kind = kind,
        .status = .installed,
        .flags = 0,
        .string_count = 0,
        .save_count = save_count,
    }, "");
}

fn appRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), a: *const App, save_count: u64) !void {
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    // In types.DeskAppString order.
    try format.appendString(gpa, &extra, a.binary);
    try format.appendString(gpa, &extra, a.id);
    try format.appendString(gpa, &extra, a.name);
    try format.appendString(gpa, &extra, a.icon);
    try format.appendStringList(gpa, &extra, a.exec);
    try format.appendString(gpa, &extra, a.version);
    try format.appendString(gpa, &extra, a.available_version);
    try format.appendStruct(gpa, out, types.desk_app, 1, types.DeskApp{
        .kind = .app,
        .status = a.status,
        .flags = if (a.available_version.len > 0) types.desk_app_update else 0,
        .string_count = @typeInfo(types.DeskAppString).@"enum".fields.len,
        .save_count = save_count,
    }, extra.items);
}

/// The fields the compositor shows.
fn digest(a: *const App) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&.{@intFromEnum(a.status)});
    for ([_][]const u8{ a.id, a.name, a.icon, a.version, a.available_version }) |s| {
        h.update(s);
        h.update(&.{0});
    }
    for (a.exec) |s| {
        h.update(s);
        h.update(&.{1});
    }
    return h.final();
}

test "snapshot, then only what changed, then removed" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    try store.apps.append(store.allocator(), .{ .id = "a", .name = "A", .binary = "/usr/bin/a", .exec = &.{"/usr/bin/a"} });
    try store.apps.append(store.allocator(), .{ .id = "b", .name = "B", .binary = "/usr/bin/b", .exec = &.{"/usr/bin/b"} });
    store.save_count = 7;
    var link = Link.init(gpa);
    defer link.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try link.snapshot(&out, &store);
    try std.testing.expectEqual(@as(usize, 4), countRecords(out.items));

    // Nothing changed: only the saved marker.
    out.clearRetainingCapacity();
    store.save_count = 8;
    try link.changes(&out, &store);
    try std.testing.expectEqual(@as(usize, 1), countRecords(out.items));

    // B gets an update, A leaves.
    out.clearRetainingCapacity();
    store.save_count = 9;
    store.apps.items[1].available_version = "2.0";
    _ = store.apps.orderedRemove(0);
    try link.changes(&out, &store);
    var reader = format.Reader.init(out.items, &types.known);
    const r1 = format.readStruct(types.DeskApp, reader.next().?);
    try std.testing.expectEqual(types.DeskAppKind.app, r1.kind);
    try std.testing.expectEqual(types.desk_app_update, r1.flags);
    const r2 = reader.next().?;
    try std.testing.expectEqual(types.DeskAppKind.removed, format.readStruct(types.DeskApp, r2).kind);
    var sr: format.StringReader = .{ .bytes = format.trailing(types.DeskApp, r2), .left = 1 };
    try std.testing.expectEqualStrings("/usr/bin/a", sr.next());
    const r3 = format.readStruct(types.DeskApp, reader.next().?);
    try std.testing.expectEqual(types.DeskAppKind.saved, r3.kind);
    try std.testing.expectEqual(@as(u64, 9), r3.save_count);
}

fn countRecords(bytes: []const u8) usize {
    var reader = format.Reader.init(bytes, &types.known);
    var n: usize = 0;
    while (reader.next()) |_| n += 1;
    return n;
}
