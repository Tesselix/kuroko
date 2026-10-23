//! Update check for apt apps: `apt-cache policy <packages>` gives each
//! package's installed and candidate version from apt's lists, which
//! Ubuntu's apt-daily timer refreshes. No root and no network here. A
//! candidate that differs from the installed version is an update.
//!
//! Snap updates itself; Flatpak and the others come later.

const std = @import("std");
const store_mod = @import("store.zig");

pub const Policy = struct { package: []const u8, installed: []const u8, candidate: []const u8 };

/// Parses `apt-cache policy` output: a package name line ("name:"), then
/// indented "Installed:" and "Candidate:" lines.
pub fn parsePolicy(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Policy)) !void {
    var cur: ?Policy = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 1 and line[0] != ' ' and line[line.len - 1] == ':') {
            if (cur) |c| try out.append(gpa, c);
            cur = .{ .package = line[0 .. line.len - 1], .installed = "", .candidate = "" };
            continue;
        }
        const t = std.mem.trim(u8, line, " \t");
        if (cur) |*c| {
            if (std.mem.startsWith(u8, t, "Installed: ")) c.installed = t["Installed: ".len..];
            if (std.mem.startsWith(u8, t, "Candidate: ")) c.candidate = t["Candidate: ".len..];
        }
    }
    if (cur) |c| try out.append(gpa, c);
}

/// Sets `available_version` on every installed apt app. Returns how many
/// apps changed.
pub fn check(gpa: std.mem.Allocator, io: std.Io, store: *store_mod.Store) !u32 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/usr/bin/apt-cache", "policy" });
    for (store.apps.items) |a| {
        if (a.manager == .apt and a.status == .installed and a.package.len > 0) try argv.append(gpa, a.package);
    }
    if (argv.items.len == 2) return 0;
    std.Io.Dir.accessAbsolute(io, argv.items[0], .{}) catch return 0;
    const res = try std.process.run(gpa, io, .{ .argv = argv.items, .stdout_limit = .limited(16 * 1024 * 1024) });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    var policies: std.ArrayList(Policy) = .empty;
    defer policies.deinit(gpa);
    try parsePolicy(gpa, res.stdout, &policies);
    return apply(store, policies.items);
}

pub fn apply(store: *store_mod.Store, policies: []const Policy) !u32 {
    var changed: u32 = 0;
    for (store.apps.items) |*a| {
        if (a.manager != .apt or a.package.len == 0) continue;
        const p = for (policies) |p| {
            if (std.mem.eql(u8, p.package, a.package)) break p;
        } else continue;
        const newer = p.candidate.len > 0 and !std.mem.eql(u8, p.candidate, "(none)") and
            !std.mem.eql(u8, p.candidate, p.installed);
        const available = if (newer) p.candidate else "";
        if (!std.mem.eql(u8, available, a.available_version)) {
            a.available_version = try store.dupe(available);
            changed += 1;
        }
    }
    return changed;
}

test "apt-cache policy: an update for one package" {
    const gpa = std.testing.allocator;
    const text =
        \\google-chrome-stable:
        \\  Installed: 156.0.8078.47-1
        \\  Candidate: 157.0.8100.12-1
        \\  Version table:
        \\     157.0.8100.12-1 500
        \\        500 https://dl.google.com/linux/chrome/deb stable/main arm64 Packages
        \\ *** 156.0.8078.47-1 100
        \\        100 /var/lib/dpkg/status
        \\alacritty:
        \\  Installed: 0.16.1-2ubuntu1
        \\  Candidate: 0.16.1-2ubuntu1
        \\  Version table:
        \\ *** 0.16.1-2ubuntu1 500
        \\
    ;
    var ps: std.ArrayList(Policy) = .empty;
    defer ps.deinit(gpa);
    try parsePolicy(gpa, text, &ps);
    try std.testing.expectEqual(@as(usize, 2), ps.items.len);

    var store = store_mod.Store.init(gpa);
    defer store.deinit();
    try store.apps.append(store.allocator(), .{ .binary = "/opt/google/chrome/chrome", .manager = .apt, .package = "google-chrome-stable" });
    try store.apps.append(store.allocator(), .{ .binary = "/usr/bin/alacritty", .manager = .apt, .package = "alacritty" });
    try std.testing.expectEqual(@as(u32, 1), try apply(&store, ps.items));
    try std.testing.expectEqualStrings("157.0.8100.12-1", store.apps.items[0].available_version);
    try std.testing.expectEqualStrings("", store.apps.items[1].available_version);
    // Upgraded: the badge goes away.
    ps.items[0].installed = "157.0.8100.12-1";
    try std.testing.expectEqual(@as(u32, 1), try apply(&store, ps.items));
    try std.testing.expectEqualStrings("", store.apps.items[0].available_version);
}
