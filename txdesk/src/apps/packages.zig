//! Which package manager installed a file, and the installed version.
//!
//! apt: dpkg's own records, read directly (no process is started):
//! `info/<package>.list` lists every file a package installed, and `status`
//! holds the versions. The index is built once per scan, and only when a
//! scan has something to look up. Snap, Flatpak and AppImage are known by
//! their paths. Everything else is manual.

const std = @import("std");
const types = @import("txcore").types;

pub const Owner = struct {
    manager: types.PackageManager = .manual,
    /// Package, snap or Flatpak id; "" for AppImage and manual.
    package: []const u8 = "",
    version: []const u8 = "",
};

/// Snap, Flatpak and AppImage, from where the file lives. `.manual` when
/// the path says nothing.
pub fn fromPath(path: []const u8) Owner {
    const flatpak = [_][]const u8{ "/flatpak/app/", "/flatpak/exports/bin/" };
    for (flatpak) |marker| {
        if (std.mem.indexOf(u8, path, marker)) |i| {
            const rest = path[i + marker.len ..];
            return .{ .manager = .flatpak, .package = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len] };
        }
    }
    for ([_][]const u8{ "/snap/bin/", "/snap/" }) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            const name = rest[0 .. std.mem.indexOfAny(u8, rest, "/.") orelse rest.len];
            return .{ .manager = .snap, .package = name };
        }
    }
    if (std.ascii.endsWithIgnoreCase(path, ".appimage")) return .{ .manager = .appimage };
    return .{};
}

/// The other spelling of a path on merged-/usr systems (/bin/ls is
/// /usr/bin/ls); dpkg may list either.
pub fn mergedUsrTwin(buf: []u8, path: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "/usr/bin/", "/bin/" },   .{ "/bin/", "/usr/bin/" },
        .{ "/usr/sbin/", "/sbin/" }, .{ "/sbin/", "/usr/sbin/" },
        .{ "/usr/lib/", "/lib/" },   .{ "/lib/", "/usr/lib/" },
    };
    for (pairs) |p| {
        if (std.mem.startsWith(u8, path, p[0])) {
            return std.fmt.bufPrint(buf, "{s}{s}", .{ p[1], path[p[0].len..] }) catch null;
        }
    }
    return null;
}

/// dpkg's file → package map and package → version map.
pub const Dpkg = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    versions: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Dpkg {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Dpkg) void {
        self.arena.deinit();
    }

    /// Adds one `<package>[:arch].list` file's contents.
    pub fn addList(self: *Dpkg, list_name: []const u8, text: []const u8) !void {
        const a = self.arena.allocator();
        var pkg = list_name[0 .. list_name.len - ".list".len];
        if (std.mem.indexOfScalar(u8, pkg, ':')) |c| pkg = pkg[0..c];
        const owned_pkg = try a.dupe(u8, pkg);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len < 2 or line[0] != '/') continue;
            const gop = try self.files.getOrPut(a, line);
            if (!gop.found_existing) {
                gop.key_ptr.* = try a.dupe(u8, line);
                gop.value_ptr.* = owned_pkg;
            }
        }
    }

    /// Reads dpkg's `status` file: installed packages and their versions.
    pub fn addStatus(self: *Dpkg, text: []const u8) !void {
        const a = self.arena.allocator();
        var pkg: []const u8 = "";
        var version: []const u8 = "";
        var installed = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (true) {
            const next = lines.next();
            const line = next orelse "";
            if (line.len == 0) {
                // End of a paragraph.
                if (installed and pkg.len > 0 and version.len > 0) {
                    try self.versions.put(a, try a.dupe(u8, pkg), try a.dupe(u8, version));
                }
                pkg = "";
                version = "";
                installed = false;
                if (next == null) break;
                continue;
            }
            if (std.mem.startsWith(u8, line, "Package: ")) pkg = line["Package: ".len..];
            if (std.mem.startsWith(u8, line, "Version: ")) version = line["Version: ".len..];
            if (std.mem.startsWith(u8, line, "Status: ")) installed = std.mem.endsWith(u8, line, " installed");
        }
    }

    pub fn owner(self: *const Dpkg, path: []const u8) ?Owner {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const pkg = self.files.get(path) orelse
            self.files.get(mergedUsrTwin(&buf, path) orelse return null) orelse return null;
        return .{ .manager = .apt, .package = pkg, .version = self.versions.get(pkg) orelse "" };
    }
};

/// A snap's version: the `version:` line of its `meta/snap.yaml`.
pub fn snapVersion(snap_yaml: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, snap_yaml, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "version:")) {
            return std.mem.trim(u8, line["version:".len..], " \t'\"\r");
        }
    }
    return "";
}

test "managers from paths" {
    const fp = fromPath("/var/lib/flatpak/app/org.gimp.GIMP/aarch64/stable/active/files/bin/gimp");
    try std.testing.expectEqual(types.PackageManager.flatpak, fp.manager);
    try std.testing.expectEqualStrings("org.gimp.GIMP", fp.package);
    try std.testing.expectEqualStrings("org.gimp.GIMP", fromPath("/var/lib/flatpak/exports/bin/org.gimp.GIMP").package);
    try std.testing.expectEqualStrings("chromium", fromPath("/snap/bin/chromium").package);
    try std.testing.expectEqualStrings("chromium", fromPath("/snap/bin/chromium.chromedriver").package);
    try std.testing.expectEqualStrings("chromium", fromPath("/snap/chromium/3564/usr/lib/chromium-browser/chrome").package);
    try std.testing.expectEqual(types.PackageManager.appimage, fromPath("/home/t/Applications/Krita.AppImage").manager);
    try std.testing.expectEqual(types.PackageManager.manual, fromPath("/home/t/.cache/kuroko/bin/txsim").manager);
}

test "dpkg: owner and version, merged /usr" {
    var d = Dpkg.init(std.testing.allocator);
    defer d.deinit();
    try d.addList("google-chrome-stable.list", "/.\n/opt\n/opt/google/chrome/chrome\n/usr/bin/google-chrome-stable\n");
    try d.addList("coreutils:arm64.list", "/bin\n/bin/ls\n");
    try d.addStatus(
        \\Package: google-chrome-stable
        \\Status: install ok installed
        \\Version: 156.0.8078.47-1
        \\
        \\Package: coreutils
        \\Status: deinstall ok config-files
        \\Version: 9.4-1
        \\
    );
    const chrome = d.owner("/opt/google/chrome/chrome").?;
    try std.testing.expectEqualStrings("google-chrome-stable", chrome.package);
    try std.testing.expectEqualStrings("156.0.8078.47-1", chrome.version);
    const ls = d.owner("/usr/bin/ls").?;
    try std.testing.expectEqualStrings("coreutils", ls.package);
    try std.testing.expectEqualStrings("", ls.version); // not installed
    try std.testing.expect(d.owner("/home/t/bin/mine") == null);
}

test "snap version" {
    try std.testing.expectEqualStrings("155.0.8059.84", snapVersion("name: chromium\nversion: '155.0.8059.84'\nsummary: x\n"));
}
