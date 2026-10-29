//! The app registry in memory, and its file `apps.krkde` (Kuroko records,
//! see txcore/src/types.zig). txdesk is its only writer.
//!
//! Strings live in the store's arena. A scan changes few strings, so the
//! arena grows slowly; a long-running txdesk reloads the file to start a
//! fresh one.
//!
//! Pure: encodes to and decodes from bytes; scan.zig does the file I/O.

const std = @import("std");
const core = @import("txcore");
const types = core.types;
const format = core.format;

pub const Stat = struct {
    size: u64 = 0,
    mtime_ns: i64 = 0,
    inode: u64 = 0,

    pub fn eql(a: Stat, b: Stat) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and a.inode == b.inode;
    }
};

pub const App = struct {
    status: types.AppStatus = .installed,
    display: types.AppDisplay = .unknown,
    manager: types.PackageManager = .manual,
    binary_stat: Stat = .{},
    missing_since_s: i64 = 0,
    first_seen_s: i64 = 0,
    id: []const u8 = "",
    name: []const u8 = "",
    binary: []const u8 = "",
    exec: []const []const u8 = &.{},
    icon: []const u8 = "",
    desktop_entry: []const u8 = "",
    groups: []const []const u8 = &.{},
    evidence: []const []const u8 = &.{},
    package: []const u8 = "",
    version: []const u8 = "",
    available_version: []const u8 = "",
};

pub const Scanned = struct {
    kind: types.ScanKind,
    verdict: types.ScanVerdict,
    override: types.ScanOverride = .none,
    stat: Stat,
};

pub const SearchPath = struct {
    kind: types.SearchKind,
    path: []const u8,
    depth: u8 = 1,
    enabled: bool = true,
    origin: types.SearchOrigin = .default,
};

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    save_count: u64 = 0,
    last_scan_s: i64 = 0,
    apps: std.ArrayList(App) = .empty,
    /// Path → what the scanner found there.
    scanned: std.StringArrayHashMapUnmanaged(Scanned) = .empty,
    paths: std.ArrayList(SearchPath) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Store) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn dupe(self: *Store, s: []const u8) ![]const u8 {
        return self.allocator().dupe(u8, s);
    }

    pub fn dupeList(self: *Store, items: []const []const u8) ![]const []const u8 {
        const out = try self.allocator().alloc([]const u8, items.len);
        for (items, out) |s, *o| o.* = try self.dupe(s);
        return out;
    }

    pub fn findByBinary(self: *Store, binary: []const u8) ?*App {
        for (self.apps.items) |*a| {
            if (std.mem.eql(u8, a.binary, binary)) return a;
        }
        return null;
    }

    pub fn findById(self: *Store, id: []const u8) ?*App {
        for (self.apps.items) |*a| {
            if (std.mem.eql(u8, a.id, id)) return a;
        }
        return null;
    }

    pub fn setScanned(self: *Store, path: []const u8, s: Scanned) !void {
        const gop = try self.scanned.getOrPut(self.allocator(), path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.dupe(path);
            gop.value_ptr.* = s;
        } else {
            // The user's override stays.
            const keep = gop.value_ptr.override;
            gop.value_ptr.* = s;
            gop.value_ptr.override = keep;
        }
    }

    // ---------------------------------------------------------- encoding

    pub fn encode(self: *const Store, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(gpa);

        try format.appendStruct(gpa, &out, types.apps_header, 1, types.AppsHeader{
            .save_count = self.save_count,
            .last_scan_s = self.last_scan_s,
        }, "");

        for (self.apps.items) |a| {
            extra.clearRetainingCapacity();
            // In types.AppString order.
            try format.appendString(gpa, &extra, a.id);
            try format.appendString(gpa, &extra, a.name);
            try format.appendString(gpa, &extra, a.binary);
            try format.appendStringList(gpa, &extra, a.exec);
            try format.appendString(gpa, &extra, a.icon);
            try format.appendString(gpa, &extra, a.desktop_entry);
            try format.appendStringList(gpa, &extra, a.groups);
            try format.appendStringList(gpa, &extra, a.evidence);
            try format.appendString(gpa, &extra, a.package);
            try format.appendString(gpa, &extra, a.version);
            try format.appendString(gpa, &extra, a.available_version);
            const string_count = @typeInfo(types.AppString).@"enum".fields.len;
            try format.appendStruct(gpa, &out, types.app_entry, 1, types.AppEntry{
                .status = a.status,
                .display = a.display,
                .manager = a.manager,
                .string_count = string_count,
                .binary_size = a.binary_stat.size,
                .binary_mtime_ns = a.binary_stat.mtime_ns,
                .binary_inode = a.binary_stat.inode,
                .missing_since_s = a.missing_since_s,
                .first_seen_s = a.first_seen_s,
            }, extra.items);
        }

        var it = self.scanned.iterator();
        while (it.next()) |e| {
            const s = e.value_ptr.*;
            try format.appendStruct(gpa, &out, types.scan_entry, 1, types.ScanEntry{
                .kind = s.kind,
                .verdict = s.verdict,
                .override = s.override,
                .path_len = @intCast(e.key_ptr.len),
                .size = s.stat.size,
                .mtime_ns = s.stat.mtime_ns,
                .inode = s.stat.inode,
            }, e.key_ptr.*);
        }

        for (self.paths.items) |p| {
            try format.appendStruct(gpa, &out, types.search_path, 1, types.SearchPath{
                .kind = p.kind,
                .depth = p.depth,
                .enabled = @intFromBool(p.enabled),
                .origin = p.origin,
                .path_len = @intCast(p.path.len),
            }, p.path);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Reads a file's bytes into an empty store. Damaged records are
    /// skipped (counted in `log`); a damaged app record drops that app only.
    pub fn decode(self: *Store, bytes: []const u8, log: *format.RepairLog) !void {
        var reader = format.Reader.init(bytes, &types.known);
        while (reader.next()) |rec| {
            if (rec.swapped) continue; // never written by Kuroko on Linux
            switch (rec.type_id) {
                types.apps_header => {
                    const h = format.readStruct(types.AppsHeader, rec);
                    self.save_count = h.save_count;
                    self.last_scan_s = h.last_scan_s;
                },
                types.app_entry => {
                    const e = format.readStruct(types.AppEntry, rec);
                    var r: format.StringReader = .{ .bytes = format.trailing(types.AppEntry, rec), .left = e.string_count };
                    const a: App = .{
                        .status = e.status,
                        .display = e.display,
                        .manager = e.manager,
                        .binary_stat = .{ .size = e.binary_size, .mtime_ns = e.binary_mtime_ns, .inode = e.binary_inode },
                        .missing_since_s = e.missing_since_s,
                        .first_seen_s = e.first_seen_s,
                        .id = try self.dupe(r.next()),
                        .name = try self.dupe(r.next()),
                        .binary = try self.dupe(r.next()),
                        .exec = try self.splitList(r.next()),
                        .icon = try self.dupe(r.next()),
                        .desktop_entry = try self.dupe(r.next()),
                        .groups = try self.splitList(r.next()),
                        .evidence = try self.splitList(r.next()),
                        .package = try self.dupe(r.next()),
                        .version = try self.dupe(r.next()),
                        .available_version = try self.dupe(r.next()),
                    };
                    if (r.bad or a.binary.len == 0) {
                        log.note(.truncated);
                        continue;
                    }
                    try self.apps.append(self.allocator(), a);
                },
                types.scan_entry => {
                    const e = format.readStruct(types.ScanEntry, rec);
                    const path = format.trailing(types.ScanEntry, rec);
                    if (e.path_len != path.len or path.len == 0) {
                        log.note(.truncated);
                        continue;
                    }
                    try self.setScanned(path, .{
                        .kind = e.kind,
                        .verdict = e.verdict,
                        .stat = .{ .size = e.size, .mtime_ns = e.mtime_ns, .inode = e.inode },
                    });
                    self.scanned.getPtr(path).?.override = e.override;
                },
                types.search_path => {
                    const e = format.readStruct(types.SearchPath, rec);
                    const path = format.trailing(types.SearchPath, rec);
                    if (e.path_len != path.len or path.len == 0) {
                        log.note(.truncated);
                        continue;
                    }
                    try self.paths.append(self.allocator(), .{
                        .kind = e.kind,
                        .path = try self.dupe(path),
                        .depth = e.depth,
                        .enabled = e.enabled != 0,
                        .origin = e.origin,
                    });
                },
                else => {},
            }
        }
        reader.finish();
        for (std.enums.values(format.Repair)) |rp| {
            if (rp != .none) log.counts.getPtr(rp).* += reader.log.counts.get(rp);
        }
    }

    fn splitList(self: *Store, joined: []const u8) ![]const []const u8 {
        if (joined.len == 0) return &.{};
        var items: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, joined, 0);
        while (it.next()) |s| try items.append(self.allocator(), try self.dupe(s));
        return items.toOwnedSlice(self.allocator());
    }
};

// --------------------------------------------------------------- tests

fn sample(store: *Store) !void {
    try store.apps.append(store.allocator(), .{
        .display = .wayland,
        .manager = .apt,
        .binary_stat = .{ .size = 250_000_000, .mtime_ns = 1_760_000_000_000_000_000, .inode = 4242 },
        .first_seen_s = 1_760_000_000,
        .id = "com.google.Chrome",
        .name = "Google Chrome",
        .binary = "/opt/google/chrome/chrome",
        .exec = &.{ "/usr/bin/google-chrome-stable", "%U" },
        .icon = "/usr/share/icons/hicolor/256x256/apps/google-chrome.png",
        .desktop_entry = "/usr/share/applications/com.google.Chrome.desktop",
        .groups = &.{ "Network", "WebBrowser" },
        .evidence = &.{ "desktop-entry", "xdg_wm_base", "XCreateWindow" },
        .package = "google-chrome-stable",
        .version = "156.0.8078.47-1",
    });
    try store.setScanned("/usr/bin/xset", .{ .kind = .binary, .verdict = .display_client, .stat = .{ .size = 31234, .mtime_ns = 5, .inode = 7 } });
    try store.setScanned("/usr/bin/gtk-builder-tool", .{ .kind = .binary, .verdict = .app, .override = .always_skip, .stat = .{} });
    try store.paths.append(store.allocator(), .{ .kind = .binaries, .path = "/opt", .depth = 3 });
    store.save_count = 41;
}

test "the store survives a round trip through apps.krkde" {
    const gpa = std.testing.allocator;
    var a = Store.init(gpa);
    defer a.deinit();
    try sample(&a);
    const bytes = try a.encode(gpa);
    defer gpa.free(bytes);

    var b = Store.init(gpa);
    defer b.deinit();
    var log: format.RepairLog = .{};
    try b.decode(bytes, &log);
    try std.testing.expectEqual(@as(u32, 0), log.total());
    try std.testing.expectEqual(@as(u64, 41), b.save_count);
    const chrome = b.findByBinary("/opt/google/chrome/chrome").?;
    try std.testing.expectEqualStrings("Google Chrome", chrome.name);
    try std.testing.expectEqualStrings("%U", chrome.exec[1]);
    try std.testing.expectEqual(@as(usize, 3), chrome.evidence.len);
    try std.testing.expectEqual(types.PackageManager.apt, chrome.manager);
    try std.testing.expectEqual(@as(u64, 4242), chrome.binary_stat.inode);
    try std.testing.expectEqual(types.ScanVerdict.display_client, b.scanned.get("/usr/bin/xset").?.verdict);
    try std.testing.expectEqual(types.ScanOverride.always_skip, b.scanned.get("/usr/bin/gtk-builder-tool").?.override);
    try std.testing.expectEqual(@as(u8, 3), b.paths.items[0].depth);
}

test "a damaged app record drops that app, not the file" {
    const gpa = std.testing.allocator;
    var a = Store.init(gpa);
    defer a.deinit();
    try sample(&a);
    const bytes = try a.encode(gpa);
    defer gpa.free(bytes);
    // Flip a byte inside Chrome's name: its checksum fails.
    const at = std.mem.indexOf(u8, bytes, "Google Chrome").?;
    bytes[at] ^= 0xff;

    var b = Store.init(gpa);
    defer b.deinit();
    var log: format.RepairLog = .{};
    try b.decode(bytes, &log);
    try std.testing.expect(log.total() > 0);
    try std.testing.expectEqual(@as(usize, 0), b.apps.items.len);
    try std.testing.expectEqual(@as(usize, 2), b.scanned.count());
}

test "a user override survives the scanner's update" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try s.setScanned("/usr/bin/x", .{ .kind = .binary, .verdict = .app, .override = .always_skip, .stat = .{} });
    try s.setScanned("/usr/bin/x", .{ .kind = .binary, .verdict = .none, .stat = .{ .size = 9 } });
    try std.testing.expectEqual(types.ScanOverride.always_skip, s.scanned.get("/usr/bin/x").?.override);
    try std.testing.expectEqual(types.ScanVerdict.none, s.scanned.get("/usr/bin/x").?.verdict);
}
