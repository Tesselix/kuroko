//! Trust rules, shared by krkdesk (which keeps the marks) and the compositor
//! (which decides each window's trust and enforces it). One copy of the
//! rules, so the two can never disagree.
//!
//! Trust is the app and the object open in its window together
//! (docs/user-signals.md):
//!   - An app: the user's mark on its binary, else trusted when it is an
//!     installed app (in the app registry), else untrusted. Provisional:
//!     how installed apps earn trust is still to be designed.
//!   - An object (file): the user's mark on the file, else on the nearest
//!     marked folder above it, else unknown.
//!   - Together: an unknown object leaves the app's level; otherwise the
//!     lower of the two.
//!
//! Pure: no I/O. Paths are absolute and already resolved by the caller.

const std = @import("std");
const types = @import("types.zig");

pub const Trust = types.Trust;
pub const Subject = types.TrustSubject;

pub const Mark = struct {
    subject: Subject,
    level: Trust,
    path: []const u8,
    set_s: i64 = 0,
    digest: [32]u8 = @splat(0),
};

/// The user's marks. Paths are owned.
pub const Marks = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Mark) = .empty,

    pub fn init(gpa: std.mem.Allocator) Marks {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Marks) void {
        self.clearAll();
        self.list.deinit(self.gpa);
    }

    pub fn clearAll(self: *Marks) void {
        for (self.list.items) |m| self.gpa.free(m.path);
        self.list.clearRetainingCapacity();
    }

    pub fn find(self: *const Marks, subject: Subject, path: []const u8) ?*Mark {
        for (self.list.items) |*m| {
            if (m.subject == subject and std.mem.eql(u8, m.path, path)) return m;
        }
        return null;
    }

    /// Sets (or replaces) a mark. Returns true when anything changed.
    pub fn set(self: *Marks, mark: Mark) !bool {
        const path = trimSlash(mark.path);
        if (self.find(mark.subject, path)) |m| {
            if (m.level == mark.level and std.mem.eql(u8, &m.digest, &mark.digest)) return false;
            m.level = mark.level;
            m.set_s = mark.set_s;
            m.digest = mark.digest;
            return true;
        }
        var m = mark;
        m.path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(m.path);
        try self.list.append(self.gpa, m);
        return true;
    }

    /// Takes a mark back. Returns true when there was one.
    pub fn clear(self: *Marks, subject: Subject, path: []const u8) bool {
        const p = trimSlash(path);
        for (self.list.items, 0..) |m, i| {
            if (m.subject == subject and std.mem.eql(u8, m.path, p)) {
                self.gpa.free(m.path);
                _ = self.list.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// An app's trust. `exe` is its binary ("" when unknown); `installed`
    /// says whether the app registry lists it as installed.
    pub fn appLevel(self: *const Marks, exe: []const u8, installed: bool) Trust {
        if (exe.len > 0) {
            if (self.find(.app, exe)) |m| return m.level;
        }
        return if (installed) .trusted else .untrusted;
    }

    /// A file's trust: its own mark, else the nearest marked folder above.
    pub fn objectLevel(self: *const Marks, path: []const u8) Trust {
        if (path.len == 0) return .unknown;
        if (self.find(.file, path)) |m| return m.level;
        var best: ?*const Mark = null;
        for (self.list.items) |*m| {
            if (m.subject != .folder or !inFolder(path, m.path)) continue;
            if (best == null or m.path.len > best.?.path.len) best = m;
        }
        return if (best) |m| m.level else .unknown;
    }
};

/// The trust of an app with an object open in it.
pub fn combine(app: Trust, object: Trust) Trust {
    if (object == .unknown) return app;
    if (app == .unknown) return object;
    return if (rank(object) < rank(app)) object else app;
}

/// Order for comparing levels; unknown values count as untrusted.
pub fn rank(t: Trust) u8 {
    return switch (t) {
        .trusted => 2,
        else => 1,
    };
}

pub fn name(t: Trust) []const u8 {
    return switch (t) {
        .unknown => "unknown",
        .untrusted => "untrusted",
        .trusted => "trusted",
        _ => "?",
    };
}

/// `path` is `folder` or inside it.
pub fn inFolder(path: []const u8, folder: []const u8) bool {
    const f = trimSlash(folder);
    if (f.len == 0) return true; // "/"
    if (!std.mem.startsWith(u8, path, f)) return false;
    return path.len == f.len or path[f.len] == '/';
}

fn trimSlash(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "an installed app is trusted unless the user says otherwise" {
    var m = Marks.init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(Trust.trusted, m.appLevel("/usr/bin/gedit", true));
    try testing.expectEqual(Trust.untrusted, m.appLevel("/home/u/bin/tool", false));
    _ = try m.set(.{ .subject = .app, .level = .trusted, .path = "/home/u/bin/tool" });
    _ = try m.set(.{ .subject = .app, .level = .untrusted, .path = "/usr/bin/gedit" });
    try testing.expectEqual(Trust.trusted, m.appLevel("/home/u/bin/tool", false));
    try testing.expectEqual(Trust.untrusted, m.appLevel("/usr/bin/gedit", true));
    try testing.expect(m.clear(.app, "/usr/bin/gedit"));
    try testing.expectEqual(Trust.trusted, m.appLevel("/usr/bin/gedit", true));
    try testing.expectEqual(Trust.untrusted, m.appLevel("", false));
}

test "a file takes its own mark, else the nearest folder's" {
    var m = Marks.init(testing.allocator);
    defer m.deinit();
    _ = try m.set(.{ .subject = .folder, .level = .trusted, .path = "/home/u/work/" });
    _ = try m.set(.{ .subject = .folder, .level = .untrusted, .path = "/home/u/work/inbox" });
    _ = try m.set(.{ .subject = .file, .level = .trusted, .path = "/home/u/work/inbox/ok.pdf" });
    try testing.expectEqual(Trust.trusted, m.objectLevel("/home/u/work/report.odt"));
    try testing.expectEqual(Trust.untrusted, m.objectLevel("/home/u/work/inbox/x.pdf"));
    try testing.expectEqual(Trust.trusted, m.objectLevel("/home/u/work/inbox/ok.pdf"));
    // A name that only starts like the folder is not inside it.
    try testing.expectEqual(Trust.unknown, m.objectLevel("/home/u/workshop/a.txt"));
    try testing.expectEqual(Trust.unknown, m.objectLevel(""));
}

test "setting the same mark twice changes nothing" {
    var m = Marks.init(testing.allocator);
    defer m.deinit();
    try testing.expect(try m.set(.{ .subject = .file, .level = .trusted, .path = "/a" }));
    try testing.expect(!try m.set(.{ .subject = .file, .level = .trusted, .path = "/a" }));
    try testing.expect(try m.set(.{ .subject = .file, .level = .untrusted, .path = "/a" }));
    try testing.expectEqual(@as(usize, 1), m.list.items.len);
}

test "app and object together: the lower, an unknown object leaves the app's" {
    try testing.expectEqual(Trust.trusted, combine(.trusted, .unknown));
    try testing.expectEqual(Trust.untrusted, combine(.trusted, .untrusted));
    try testing.expectEqual(Trust.untrusted, combine(.untrusted, .trusted));
    try testing.expectEqual(Trust.trusted, combine(.trusted, .trusted));
    try testing.expectEqual(Trust.trusted, combine(.unknown, .trusted));
}
