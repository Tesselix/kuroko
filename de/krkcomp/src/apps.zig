//! The compositor's read-only copy of krkdesk's app registry: what the
//! launcher shows of the installed apps (types.DeskApp records).
//!
//! Entries are never removed, only hidden, so the launcher's app indices
//! stay valid while it is open. A `saved` count that skips one means a
//! lost message: the caller asks krkdesk for a snapshot.

const std = @import("std");
const core = @import("krkcore");
const types = core.types;
const format = core.format;

pub const Entry = struct {
    /// Holds the strings below.
    arena: std.heap.ArenaAllocator,
    /// The binary (the registry's key).
    key: []const u8,
    id: []const u8,
    name: []const u8,
    /// Absolute path of the icon file, or "".
    icon: []const u8,
    /// The command, absolute; field codes (%U) kept.
    exec: []const []const u8,
    version: []const u8,
    available_version: []const u8,
    status: types.AppStatus,
    update: bool,
    /// Seen in the current snapshot.
    seen: bool = true,

    fn free(self: *Entry) void {
        self.arena.deinit();
    }

    /// Shown in the launcher: installed (launchable) or a ghost.
    pub fn shown(self: *const Entry) bool {
        return self.status == .installed or self.status == .missing;
    }
};

pub const Result = enum { none, changed, need_snapshot };

pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    last_save: ?u64 = null,
    in_snapshot: bool = false,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*e| e.free();
        self.entries.deinit(self.gpa);
    }

    /// An app that is not in the registry (started some other way): an
    /// entry that names its windows, hidden from the launcher. A later
    /// snapshot with the same key replaces it. Returns its index.
    pub fn addUnlisted(self: *Registry, key: []const u8, name: []const u8) !usize {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        try self.entries.append(self.gpa, .{
            .arena = undefined,
            .key = try a.dupe(u8, if (key.len > 0) key else name),
            .id = try a.dupe(u8, name),
            .name = try a.dupe(u8, name),
            .icon = "",
            .exec = &.{},
            .version = "",
            .available_version = "",
            .status = .hidden,
            .update = false,
        });
        const i = self.entries.items.len - 1;
        self.entries.items[i].arena = arena;
        return i;
    }

    pub fn find(self: *Registry, key: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    /// Applies one record from krkdesk. The record's bytes are copied.
    pub fn apply(self: *Registry, rec: format.Record) !Result {
        if (rec.type_id != types.desk_app or rec.swapped) return .none;
        const m = format.readStruct(types.DeskApp, rec);
        var r: format.StringReader = .{ .bytes = format.trailing(types.DeskApp, rec), .left = m.string_count };
        switch (m.kind) {
            .snapshot_begin => {
                self.in_snapshot = true;
                for (self.entries.items) |*e| e.seen = false;
                return .none;
            },
            .snapshot_end => {
                self.in_snapshot = false;
                self.last_save = m.save_count;
                // Apps no longer in the registry.
                for (self.entries.items) |*e| {
                    if (!e.seen) e.status = .hidden;
                }
                return .changed;
            },
            .app => {
                if (self.last_save == null and !self.in_snapshot) return .need_snapshot;
                try self.upsert(m, &r);
                return .changed;
            },
            .removed => {
                if (self.find(r.next())) |e| e.status = .hidden;
                return .changed;
            },
            .saved => {
                const last = self.last_save orelse return .need_snapshot;
                if (m.save_count != last + 1 and m.save_count != last) {
                    self.last_save = null;
                    return .need_snapshot;
                }
                self.last_save = m.save_count;
                return .none;
            },
            _ => return .none,
        }
    }

    fn upsert(self: *Registry, m: types.DeskApp, r: *format.StringReader) !void {
        const key = r.next();
        const id = r.next();
        const name = r.next();
        const icon = r.next();
        const joined = r.next();
        const version = r.next();
        const available = r.next();
        if (key.len == 0 or r.bad) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var exec: std.ArrayList([]const u8) = .empty;
        if (joined.len > 0) {
            var it = format.listItems(joined);
            while (it.next()) |s| try exec.append(a, try a.dupe(u8, s));
        }
        const e: Entry = .{
            .arena = undefined,
            .key = try a.dupe(u8, key),
            .id = try a.dupe(u8, id),
            .name = try a.dupe(u8, if (name.len > 0) name else id),
            .icon = try a.dupe(u8, icon),
            .exec = try exec.toOwnedSlice(a),
            .version = try a.dupe(u8, version),
            .available_version = try a.dupe(u8, available),
            .status = m.status,
            .update = m.flags & types.desk_app_update != 0,
        };
        if (self.find(key)) |old| {
            old.free();
            old.* = e;
            old.arena = arena;
        } else {
            try self.entries.append(self.gpa, e);
            self.entries.items[self.entries.items.len - 1].arena = arena;
        }
    }
};

// --------------------------------------------------------------- tests

fn appRec(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, name: []const u8, status: types.AppStatus, flags: u8, save: u64) !void {
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    for ([_][]const u8{ key, name, name, "" }) |s| try format.appendString(gpa, &extra, s);
    try format.appendStringList(gpa, &extra, &.{ key, "%U" });
    try format.appendString(gpa, &extra, "1.0");
    try format.appendString(gpa, &extra, if (flags != 0) "2.0" else "");
    try format.appendStruct(gpa, out, types.desk_app, 1, types.DeskApp{ .kind = .app, .status = status, .flags = flags, .string_count = 7, .save_count = save }, extra.items);
}

fn markerRec(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: types.DeskAppKind, save: u64) !void {
    try format.appendStruct(gpa, out, types.desk_app, 1, types.DeskApp{ .kind = kind, .status = .installed, .flags = 0, .string_count = 0, .save_count = save }, "");
}

fn feed(reg: *Registry, bytes: []const u8) !Result {
    var reader = format.Reader.init(bytes, &types.known);
    var res: Result = .none;
    while (reader.next()) |rec| {
        const x = try reg.apply(rec);
        if (x == .need_snapshot) return x;
        if (x == .changed) res = .changed;
    }
    return res;
}

test "snapshot, change, gap, and an app that left" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // A change before any snapshot: ask for one.
    try appRec(gpa, &out, "/usr/bin/a", "A", .installed, 0, 1);
    try std.testing.expectEqual(Result.need_snapshot, try feed(&reg, out.items));

    out.clearRetainingCapacity();
    try markerRec(gpa, &out, .snapshot_begin, 5);
    try appRec(gpa, &out, "/usr/bin/a", "A", .installed, 0, 5);
    try appRec(gpa, &out, "/opt/google/chrome/chrome", "Google Chrome", .installed, 0, 5);
    try markerRec(gpa, &out, .snapshot_end, 5);
    try std.testing.expectEqual(Result.changed, try feed(&reg, out.items));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    try std.testing.expectEqualStrings("%U", reg.entries.items[1].exec[1]);

    // Save 6: Chrome has an update; A is a ghost.
    out.clearRetainingCapacity();
    try appRec(gpa, &out, "/opt/google/chrome/chrome", "Google Chrome", .installed, types.desk_app_update, 6);
    try appRec(gpa, &out, "/usr/bin/a", "A", .missing, 0, 6);
    try markerRec(gpa, &out, .saved, 6);
    try std.testing.expectEqual(Result.changed, try feed(&reg, out.items));
    try std.testing.expect(reg.find("/opt/google/chrome/chrome").?.update);
    try std.testing.expectEqualStrings("2.0", reg.find("/opt/google/chrome/chrome").?.available_version);
    try std.testing.expectEqual(types.AppStatus.missing, reg.find("/usr/bin/a").?.status);
    try std.testing.expect(reg.find("/usr/bin/a").?.shown());

    // Save 8 after 6: one was lost.
    out.clearRetainingCapacity();
    try markerRec(gpa, &out, .saved, 8);
    try std.testing.expectEqual(Result.need_snapshot, try feed(&reg, out.items));

    // The new snapshot no longer has A: hidden, but its index stays.
    out.clearRetainingCapacity();
    try markerRec(gpa, &out, .snapshot_begin, 8);
    try appRec(gpa, &out, "/opt/google/chrome/chrome", "Google Chrome", .installed, 0, 8);
    try markerRec(gpa, &out, .snapshot_end, 8);
    _ = try feed(&reg, out.items);
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    try std.testing.expect(!reg.find("/usr/bin/a").?.shown());
}
