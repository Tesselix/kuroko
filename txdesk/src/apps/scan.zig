//! The app scan: finds the installed graphical apps and keeps the registry
//! (store.zig) up to date. Fast when little changed: known files are only
//! `stat`ed, and only new or changed files are read.
//!
//! 1. Known apps: a binary that is gone makes its app a ghost
//!    (`status: missing`); one that changed (an upgrade) gets its version
//!    read again; one that came back is installed again.
//! 2. The binary search paths: known apps and unchanged scanned files are
//!    skipped. A new file is inspected (elf.zig; a shell wrapper is followed
//!    to the binary it starts). A graphical one whose file name matches a
//!    ghost is that app, moved: the ghost is revived with the new path.
//!    Otherwise it becomes a new app. Files that are not apps are kept in
//!    the scan list with the reason, so later scans skip them.
//! 3. The desktop entries not seen before: one for a known app gives it its
//!    real name, icon and groups; one for an unknown app (a script, a snap,
//!    a Flatpak) creates it.
//!
//! All paths stored are absolute. File system work goes through `Env`, so
//! the tests run it on a temporary folder.

const std = @import("std");
const types = @import("txcore").types;
const elf = @import("elf.zig");
const desktop = @import("desktop_entry.zig");
const packages = @import("packages.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const App = store_mod.App;
const Stat = store_mod.Stat;

pub const Env = struct {
    io: std.Io,
    home: []const u8,
    now_s: i64,
    /// Include apps that open windows through X11 only.
    x11: bool = false,
    dpkg_dir: []const u8 = "/var/lib/dpkg",
    /// Icon roots (each holds themes such as hicolor); null: the defaults.
    icon_roots: ?[]const []const u8 = null,
    pixmaps: []const u8 = "/usr/share/pixmaps",
    /// Every decision, one line each (`--verbose`).
    trace: ?*std.Io.Writer = null,
};

pub const ChangeKind = enum { new, revived, ghost, back, upgraded, described };

pub const Change = struct {
    kind: ChangeKind,
    id: []const u8,
    detail: []const u8 = "",
};

pub const Report = struct {
    changes: std.ArrayList(Change) = .empty,
    /// Files read and inspected (new or changed).
    inspected: u32 = 0,
    /// Files skipped after a `stat`: known apps and unchanged scanned files.
    skipped: u32 = 0,
    desktop_entries: u32 = 0,
};

/// Binaries that start other apps' code: their real path says nothing about
/// the app, so the path that names them (/snap/bin/chromium) is the key.
const multiplexers = [_][]const u8{ "snap", "flatpak" };

/// Names of display servers: they open windows, but they are not apps.
const servers = [_][]const u8{ "Xwayland", "Xorg", "X", "Xvfb", "Xephyr", "Xnest", "Xvnc" };

/// The search paths written when the registry has none.
pub fn addDefaultPaths(store: *Store, home: []const u8) !void {
    const a = store.allocator();
    const Def = struct { kind: types.SearchKind, path: []const u8, depth: u8 = 1, in_home: bool = false };
    const defs = [_]Def{
        .{ .kind = .binaries, .path = "/usr/local/bin" },
        .{ .kind = .binaries, .path = "/usr/bin" },
        .{ .kind = .binaries, .path = "/usr/local/games" },
        .{ .kind = .binaries, .path = "/usr/games" },
        .{ .kind = .binaries, .path = "/opt", .depth = 3 },
        .{ .kind = .binaries, .path = "/snap/bin" },
        .{ .kind = .binaries, .path = "/var/lib/flatpak/exports/bin" },
        .{ .kind = .binaries, .path = ".local/bin", .in_home = true },
        .{ .kind = .binaries, .path = ".local/share/flatpak/exports/bin", .in_home = true },
        .{ .kind = .binaries, .path = "Applications", .in_home = true },
        .{ .kind = .desktop_entries, .path = ".local/share/applications", .in_home = true },
        .{ .kind = .desktop_entries, .path = ".local/share/flatpak/exports/share/applications", .in_home = true },
        .{ .kind = .desktop_entries, .path = "/var/lib/flatpak/exports/share/applications" },
        .{ .kind = .desktop_entries, .path = "/var/lib/snapd/desktop/applications" },
        .{ .kind = .desktop_entries, .path = "/usr/local/share/applications" },
        .{ .kind = .desktop_entries, .path = "/usr/share/applications" },
    };
    for (defs) |d| {
        const path = if (d.in_home) try std.fs.path.join(a, &.{ home, d.path }) else d.path;
        try store.paths.append(a, .{ .kind = d.kind, .path = path, .depth = d.depth });
    }
}

pub fn scan(gpa: std.mem.Allocator, store: *Store, env: Env) !Report {
    var s: Scanner = .{ .gpa = gpa, .env = env, .store = store, .scratch = .init(gpa) };
    defer s.deinit();
    if (store.paths.items.len == 0) try addDefaultPaths(store, env.home);
    try s.checkKnown();
    try s.walkBinaries();
    try s.readDesktopEntries();
    store.last_scan_s = env.now_s;
    return s.report;
}

const FileInfo = struct {
    stat: Stat,
    kind: std.Io.File.Kind,
    executable: bool,
};

/// What a file is, after following a wrapper script to its binary.
const Classified = struct {
    verdict: types.ScanVerdict,
    display: types.AppDisplay = .unknown,
    evidence: []const []const u8 = &.{},
    /// The app's key: the ELF binary, or the script when there is none.
    binary: []const u8,
};

const Scanner = struct {
    gpa: std.mem.Allocator,
    env: Env,
    store: *Store,
    /// Paths and lists that live only during this scan.
    scratch: std.heap.ArenaAllocator,
    report: Report = .{},
    /// Real paths seen in this scan (symlinks lead to the same file).
    visited: std.StringHashMapUnmanaged(void) = .empty,
    dpkg: ?packages.Dpkg = null,

    fn deinit(self: *Scanner) void {
        if (self.dpkg) |*d| d.deinit();
        self.scratch.deinit();
    }

    fn sa(self: *Scanner) std.mem.Allocator {
        return self.scratch.allocator();
    }

    fn trace(self: *Scanner, comptime fmt: []const u8, args: anytype) void {
        const w = self.env.trace orelse return;
        w.print(fmt ++ "\n", args) catch {};
    }

    fn note(self: *Scanner, kind: ChangeKind, id: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const a = self.store.allocator();
        const detail = try std.fmt.allocPrint(a, fmt, args);
        try self.report.changes.append(a, .{ .kind = kind, .id = id, .detail = detail });
        self.trace("{s:<9} {s}: {s}", .{ @tagName(kind), id, detail });
    }

    // ------------------------------------------------------ file system

    fn info(self: *Scanner, path: []const u8) ?FileInfo {
        const st = std.Io.Dir.cwd().statFile(self.env.io, path, .{}) catch return null;
        return .{
            .stat = .{ .size = st.size, .mtime_ns = @intCast(st.mtime.nanoseconds), .inode = @intCast(st.inode) },
            .kind = st.kind,
            .executable = st.permissions.toMode() & 0o111 != 0,
        };
    }

    fn realPath(self: *Scanner, path: []const u8) ?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.realPathFileAbsolute(self.env.io, path, &buf) catch return null;
        return self.sa().dupe(u8, buf[0..n]) catch null;
    }

    fn readFile(self: *Scanner, path: []const u8, limit: usize) ?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.env.io, path, self.sa(), .limited(limit)) catch null;
    }

    /// The first bytes of a file.
    fn head(self: *Scanner, path: []const u8, buf: []u8) []const u8 {
        var file = std.Io.Dir.openFileAbsolute(self.env.io, path, .{}) catch return buf[0..0];
        defer file.close(self.env.io);
        const n = file.readPositionalAll(self.env.io, buf, 0) catch return buf[0..0];
        return buf[0..n];
    }

    // ------------------------------------------------------- classifying

    fn classify(self: *Scanner, real: []const u8, from_desktop: bool) !Classified {
        self.report.inspected += 1;
        var buf: [4]u8 = undefined;
        const h = self.head(real, &buf);
        if (std.mem.startsWith(u8, h, "#!")) {
            // A wrapper: what does it start?
            const text = self.readFile(real, 64 * 1024) orelse return .{ .verdict = .none, .binary = real };
            const target = try scriptTarget(self.sa(), text, std.fs.path.dirname(real) orelse "/") orelse
                return .{ .verdict = .none, .binary = real };
            const treal = self.realPath(target) orelse return .{ .verdict = .none, .binary = real };
            var tbuf: [4]u8 = undefined;
            if (!std.mem.eql(u8, self.head(treal, &tbuf), "\x7fELF")) return .{ .verdict = .none, .binary = real };
            return self.classifyElf(treal, true);
        }
        if (!std.mem.eql(u8, h, "\x7fELF")) return .{ .verdict = .none, .binary = real };
        return self.classifyElf(real, from_desktop);
    }

    fn classifyElf(self: *Scanner, real: []const u8, always_search_data: bool) !Classified {
        var file = std.Io.Dir.openFileAbsolute(self.env.io, real, .{}) catch return .{ .verdict = .none, .binary = real };
        defer file.close(self.env.io);
        var ctx: FileCtx = .{ .file = file, .io = self.env.io };
        const size = file.length(self.env.io) catch return .{ .verdict = .none, .binary = real };
        const src: elf.Source = .{ .ctx = &ctx, .size = size, .readAtFn = FileCtx.readAt };
        const found = elf.inspect(self.gpa, src, .{ .always_search_data = always_search_data }) catch |err| {
            self.trace("unreadable {s}: {s}", .{ real, @errorName(err) });
            return .{ .verdict = .none, .binary = real };
        };
        var ev: std.ArrayList([]const u8) = .empty;
        try found.evidence(&ev, self.sa());
        const base = std.fs.path.basename(real);
        const is_server = for (servers) |n| {
            if (std.mem.eql(u8, base, n)) break true;
        } else false;
        const verdict: types.ScanVerdict = if (is_server) .server else switch (found.display()) {
            .server => .server,
            .wayland => .app,
            .x11 => if (self.env.x11) .app else .x11_only,
            .none => if (found.libs.count() > 0) .display_client else .none,
        };
        const display: types.AppDisplay = switch (found.display()) {
            .wayland => .wayland,
            .x11 => .x11,
            else => .unknown,
        };
        return .{ .verdict = verdict, .display = display, .evidence = ev.items, .binary = real };
    }

    // ---------------------------------------------------------- packages

    fn ownerOf(self: *Scanner, path: []const u8) !packages.Owner {
        var o = packages.fromPath(path);
        switch (o.manager) {
            .snap => {
                const meta = try std.fmt.allocPrint(self.sa(), "/snap/{s}/current/meta/snap.yaml", .{o.package});
                if (self.readFile(meta, 64 * 1024)) |text| o.version = packages.snapVersion(text);
                return o;
            },
            .manual => {},
            else => return o,
        }
        const d = try self.loadDpkg();
        return d.owner(path) orelse o;
    }

    /// dpkg's records, read once per scan and only when needed.
    fn loadDpkg(self: *Scanner) !*packages.Dpkg {
        if (self.dpkg) |*d| return d;
        self.dpkg = packages.Dpkg.init(self.gpa);
        const d = &self.dpkg.?;
        const info_dir = try std.fs.path.join(self.sa(), &.{ self.env.dpkg_dir, "info" });
        if (std.Io.Dir.openDirAbsolute(self.env.io, info_dir, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close(self.env.io);
            var it = dir.iterate();
            var list_arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer list_arena.deinit();
            while (it.next(self.env.io) catch null) |e| {
                if (!std.mem.endsWith(u8, e.name, ".list")) continue;
                _ = list_arena.reset(.retain_capacity);
                const text = dir.readFileAlloc(self.env.io, e.name, list_arena.allocator(), .limited(64 * 1024 * 1024)) catch continue;
                try d.addList(e.name, text);
            }
        } else |_| {}
        const status = try std.fs.path.join(self.sa(), &.{ self.env.dpkg_dir, "status" });
        if (self.readFile(status, 256 * 1024 * 1024)) |text| try d.addStatus(text);
        return d;
    }

    fn setOwner(self: *Scanner, app: *App) !void {
        const o = try self.ownerOf(app.binary);
        app.manager = o.manager;
        app.package = try self.store.dupe(o.package);
        app.version = try self.store.dupe(o.version);
    }

    // ---------------------------------------------------------- step 1

    fn checkKnown(self: *Scanner) !void {
        for (self.store.apps.items) |*app| {
            const fi = self.info(app.binary) orelse {
                if (app.status != .missing) {
                    app.status = .missing;
                    app.missing_since_s = self.env.now_s;
                    try self.note(.ghost, app.id, "{s} is gone", .{app.binary});
                }
                continue;
            };
            self.report.skipped += 1;
            if (app.status == .missing) {
                app.status = .installed;
                app.missing_since_s = 0;
                try self.note(.back, app.id, "{s} is back", .{app.binary});
            }
            if (!fi.stat.eql(app.binary_stat)) {
                app.binary_stat = fi.stat;
                const before = app.version;
                try self.setOwner(app);
                if (!std.mem.eql(u8, before, app.version)) {
                    try self.note(.upgraded, app.id, "{s} -> {s}", .{ before, app.version });
                }
            }
        }
    }

    // ---------------------------------------------------------- step 2

    fn walkBinaries(self: *Scanner) !void {
        // Regular files first, then symlinks: an app is named by its own
        // file (alacritty), not by an alias (x-terminal-emulator).
        var files: std.ArrayList([]const u8) = .empty;
        var links: std.ArrayList([]const u8) = .empty;
        for (self.store.paths.items) |p| {
            if (!p.enabled or p.kind != .binaries) continue;
            try self.collect(p.path, p.depth, &files, &links);
        }
        for (files.items) |f| try self.candidate(f);
        for (links.items) |f| try self.candidate(f);
    }

    fn collect(self: *Scanner, path: []const u8, depth: u8, files: *std.ArrayList([]const u8), links: *std.ArrayList([]const u8)) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.env.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.env.io);
        var names: std.ArrayList(struct { name: []const u8, kind: std.Io.File.Kind }) = .empty;
        var it = dir.iterate();
        while (it.next(self.env.io) catch null) |e| {
            try names.append(self.sa(), .{ .name = try self.sa().dupe(u8, e.name), .kind = e.kind });
        }
        for (names.items) |e| {
            const full = try std.fs.path.join(self.sa(), &.{ path, e.name });
            switch (e.kind) {
                .file => try files.append(self.sa(), full),
                .sym_link => try links.append(self.sa(), full),
                // Real folders only: a symlinked folder could loop.
                .directory => if (depth > 1) try self.collect(full, depth - 1, files, links),
                else => {},
            }
        }
    }

    fn candidate(self: *Scanner, path: []const u8) !void {
        const fi = self.info(path) orelse return;
        if (fi.kind != .file or !fi.executable) return;
        const real = self.realPath(path) orelse return;
        const seen = try self.visited.getOrPut(self.sa(), real);
        if (seen.found_existing) return;

        if (self.store.findByBinary(real) != null) {
            self.report.skipped += 1;
            return;
        }
        if (self.store.scanned.get(real)) |known| {
            const recheck = known.verdict == .x11_only and self.env.x11;
            if (known.stat.eql(fi.stat) and !recheck) {
                self.report.skipped += 1;
                return;
            }
        }
        const base = std.fs.path.basename(real);
        for (multiplexers) |m| {
            if (std.mem.eql(u8, base, m)) {
                // snap and flatpak themselves; their apps come from desktop entries.
                try self.store.setScanned(real, .{ .kind = .binary, .verdict = .none, .stat = fi.stat });
                return;
            }
        }

        const c = try self.classify(real, false);
        const override = if (self.store.scanned.get(real)) |k| k.override else .none;
        const is_app = switch (override) {
            .always_app => true,
            .always_skip => false,
            else => c.verdict == .app,
        };
        if (!is_app) {
            try self.store.setScanned(real, .{ .kind = .binary, .verdict = c.verdict, .stat = fi.stat });
            self.trace("skip      {s}: {s}", .{ real, @tagName(c.verdict) });
            return;
        }
        // A wrapper script that starts a known app: nothing new.
        if (!std.mem.eql(u8, c.binary, real) and self.store.findByBinary(c.binary) != null) {
            try self.store.setScanned(real, .{ .kind = .binary, .verdict = .app, .stat = fi.stat });
            return;
        }
        const bin_info = self.info(c.binary) orelse return;
        try self.addOrRevive(c, bin_info.stat, &.{path}, null);
        // A wrapper is remembered too, so the next scan skips it.
        if (!std.mem.eql(u8, c.binary, real)) {
            try self.store.setScanned(real, .{ .kind = .binary, .verdict = .app, .stat = fi.stat });
        }
    }

    /// A ghost with the same binary file name (and the same package, when
    /// both have one): the app moved. Only an unambiguous match counts.
    fn findGhost(self: *Scanner, binary: []const u8, package: []const u8) ?*App {
        var found: ?*App = null;
        for (self.store.apps.items) |*a| {
            if (a.status != .missing) continue;
            if (!std.mem.eql(u8, std.fs.path.basename(a.binary), std.fs.path.basename(binary))) continue;
            if (a.package.len > 0 and package.len > 0 and !std.mem.eql(u8, a.package, package)) continue;
            if (found != null) return null;
            found = a;
        }
        return found;
    }

    fn addOrRevive(self: *Scanner, c: Classified, stat: Stat, exec: []const []const u8, entry: ?DesktopInfo) !void {
        const o = try self.ownerOf(c.binary);
        if (self.findGhost(c.binary, o.package)) |g| {
            const old = g.binary;
            g.binary = try self.store.dupe(c.binary);
            // The new command path; the arguments stay.
            var cmd = try self.store.allocator().alloc([]const u8, @max(g.exec.len, 1));
            cmd[0] = try self.store.dupe(exec[0]);
            for (g.exec[@min(1, g.exec.len)..], 1..) |arg, i| cmd[i] = arg;
            g.exec = cmd;
            g.status = .installed;
            g.missing_since_s = 0;
            g.binary_stat = stat;
            g.manager = o.manager;
            g.package = try self.store.dupe(o.package);
            g.version = try self.store.dupe(o.version);
            try self.note(.revived, g.id, "moved {s} -> {s}", .{ old, g.binary });
            return;
        }
        const base = std.fs.path.basename(exec[0]);
        var app: App = .{
            .display = c.display,
            .manager = o.manager,
            .binary_stat = stat,
            .first_seen_s = self.env.now_s,
            .id = try self.store.dupe(base),
            .name = try self.store.dupe(base),
            .binary = try self.store.dupe(c.binary),
            .exec = try self.store.dupeList(exec),
            .evidence = try self.store.dupeList(c.evidence),
            .package = try self.store.dupe(o.package),
            .version = try self.store.dupe(o.version),
        };
        if (entry) |e| try self.describe(&app, e);
        try self.store.apps.append(self.store.allocator(), app);
        const added = &self.store.apps.items[self.store.apps.items.len - 1];
        try self.note(.new, added.id, "{s} ({s}; {s} {s})", .{ added.binary, @tagName(added.display), @tagName(added.manager), added.package });
    }

    // ---------------------------------------------------------- step 3

    const DesktopInfo = struct {
        id: []const u8,
        path: []const u8,
        entry: desktop.Entry,
        exec: []const []const u8,
    };

    fn readDesktopEntries(self: *Scanner) !void {
        for (self.store.paths.items) |p| {
            if (!p.enabled or p.kind != .desktop_entries) continue;
            var dir = std.Io.Dir.openDirAbsolute(self.env.io, p.path, .{ .iterate = true }) catch continue;
            defer dir.close(self.env.io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (it.next(self.env.io) catch null) |e| {
                if (std.mem.endsWith(u8, e.name, ".desktop")) try names.append(self.sa(), try self.sa().dupe(u8, e.name));
            }
            std.mem.sort([]const u8, names.items, {}, lessThan);
            for (names.items) |name| try self.desktopEntry(try std.fs.path.join(self.sa(), &.{ p.path, name }));
        }
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn desktopEntry(self: *Scanner, path: []const u8) !void {
        const fi = self.info(path) orelse return;
        if (self.store.scanned.get(path)) |known| {
            if (known.stat.eql(fi.stat)) {
                self.report.skipped += 1;
                return;
            }
        }
        self.report.desktop_entries += 1;
        const text = self.readFile(path, 1024 * 1024) orelse return;
        const entry = desktop.parse(text);
        const skip: store_mod.Scanned = .{ .kind = .desktop_entry, .verdict = .none, .stat = fi.stat };
        if (!entry.isLaunchable()) {
            try self.store.setScanned(path, skip);
            return;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try desktop.splitExec(self.sa(), entry.exec, &argv);
        // `env VAR=value cmd ...` (snap entries start this way).
        var args = argv.items;
        if (args.len > 0 and std.mem.eql(u8, std.fs.path.basename(args[0]), "env")) {
            args = args[1..];
            while (args.len > 0 and std.mem.indexOfScalar(u8, args[0], '=') != null) args = args[1..];
        }
        if (args.len == 0) return self.store.setScanned(path, skip);
        if (entry.try_exec.len > 0 and self.resolveCommand(entry.try_exec) == null) {
            // Not installed (the entry outlived its app).
            return self.store.setScanned(path, skip);
        }
        const cmd = self.resolveCommand(args[0]) orelse return self.store.setScanned(path, skip);
        const exec = try self.sa().alloc([]const u8, args.len);
        exec[0] = cmd;
        @memcpy(exec[1..], args[1..]);

        const id = std.fs.path.stem(path);
        const d: DesktopInfo = .{ .id = id, .path = path, .entry = entry, .exec = exec };
        const real = self.realPath(cmd) orelse return self.store.setScanned(path, skip);
        const base = std.fs.path.basename(real);
        const is_mux = for (multiplexers) |m| {
            if (std.mem.eql(u8, base, m)) break true;
        } else false;

        var c: Classified = if (is_mux)
            // /snap/bin/chromium -> /usr/bin/snap: the app is the name.
            .{ .verdict = .app, .binary = cmd }
        else
            try self.classify(real, true);
        if (c.verdict == .server) return self.store.setScanned(path, skip);
        try self.store.setScanned(path, .{ .kind = .desktop_entry, .verdict = .app, .stat = fi.stat });

        if (self.store.findByBinary(c.binary)) |app| {
            // Merge only into an app no entry described yet, or when this
            // id is better (com.google.Chrome over google-chrome).
            if (app.desktop_entry.len == 0 or betterId(id, app.id)) {
                try self.describe(app, d);
                try self.note(.described, app.id, "from {s}", .{path});
            }
            return;
        }
        const bin_info = self.info(c.binary) orelse return;
        c.evidence = try prepend(self.sa(), "desktop-entry", c.evidence);
        try self.addOrRevive(c, bin_info.stat, exec, d);
    }

    /// Name, icon, groups, command and id from a desktop entry.
    fn describe(self: *Scanner, app: *App, d: DesktopInfo) !void {
        const st = self.store;
        app.id = try st.dupe(d.id);
        if (d.entry.name.len > 0) app.name = try st.dupe(d.entry.name);
        app.desktop_entry = try st.dupe(d.path);
        app.exec = try st.dupeList(d.exec);
        if (try self.resolveIcon(d.entry.icon)) |icon| app.icon = try st.dupe(icon);
        var groups: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, d.entry.categories, ';');
        while (it.next()) |g| try groups.append(self.sa(), g);
        app.groups = try st.dupeList(groups.items);
        for (app.evidence) |e| if (std.mem.eql(u8, e, "desktop-entry")) return;
        app.evidence = try st.dupeList(try prepend(self.sa(), "desktop-entry", app.evidence));
    }

    /// A command name to an absolute path: the binary search paths, then
    /// the system folders.
    fn resolveCommand(self: *Scanner, cmd: []const u8) ?[]const u8 {
        if (cmd.len == 0) return null;
        if (cmd[0] == '/') return if (self.info(cmd) != null) cmd else null;
        if (std.mem.indexOfScalar(u8, cmd, '/') != null) return null;
        const extra = [_][]const u8{ "/usr/bin", "/bin", "/usr/sbin", "/sbin" };
        for (self.store.paths.items) |p| {
            if (!p.enabled or p.kind != .binaries) continue;
            if (self.tryDir(p.path, cmd)) |full| return full;
        }
        for (extra) |dir| if (self.tryDir(dir, cmd)) |full| return full;
        return null;
    }

    fn tryDir(self: *Scanner, dir: []const u8, cmd: []const u8) ?[]const u8 {
        const full = std.fs.path.join(self.sa(), &.{ dir, cmd }) catch return null;
        const fi = self.info(full) orelse return null;
        return if (fi.kind == .file and fi.executable) full else null;
    }

    /// An icon name to a file of at least 64 px: the smallest PNG from
    /// 64 px up, else the SVG, else the largest smaller one, else pixmaps.
    fn resolveIcon(self: *Scanner, name: []const u8) !?[]const u8 {
        if (name.len == 0) return null;
        if (name[0] == '/') return if (self.info(name) != null) name else null;
        const default_roots = [_][]const u8{
            try std.fs.path.join(self.sa(), &.{ self.env.home, ".local/share/icons" }),
            try std.fs.path.join(self.sa(), &.{ self.env.home, ".local/share/flatpak/exports/share/icons" }),
            "/var/lib/flatpak/exports/share/icons",
            "/usr/local/share/icons",
            "/usr/share/icons",
        };
        const roots = self.env.icon_roots orelse &default_roots;
        const sizes = [_][]const u8{
            "64x64",   "72x72",   "96x96", "128x128", "192x192", "256x256", "512x512", "scalable",
            "48x48",   "36x36",   "32x32", "24x24",   "22x22",   "16x16",
        };
        for (sizes) |size| {
            for (roots) |root| {
                for ([_][]const u8{ "png", "svg" }) |ext| {
                    const p = try std.fmt.allocPrint(self.sa(), "{s}/hicolor/{s}/apps/{s}.{s}", .{ root, size, name, ext });
                    if (self.info(p) != null) return p;
                }
            }
        }
        for ([_][]const u8{ "png", "svg", "xpm" }) |ext| {
            const p = try std.fmt.allocPrint(self.sa(), "{s}/{s}.{s}", .{ self.env.pixmaps, name, ext });
            if (self.info(p) != null) return p;
        }
        return null;
    }
};

const FileCtx = struct {
    file: std.Io.File,
    io: std.Io,

    fn readAt(ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
        const self: *FileCtx = @ptrCast(@alignCast(ctx));
        return self.file.readPositionalAll(self.io, buf, offset);
    }
};

fn prepend(a: std.mem.Allocator, first: []const u8, rest: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, rest.len + 1);
    out[0] = first;
    @memcpy(out[1..], rest);
    return out;
}

/// Prefer reverse-DNS desktop ids (com.google.Chrome over google-chrome).
fn betterId(new: []const u8, old: []const u8) bool {
    return std.mem.count(u8, new, ".") > std.mem.count(u8, old, ".");
}

/// The binary a shell wrapper starts: the last `exec` line's command.
/// `$VAR/name` (as in Chrome's `exec -a "$0" "$HERE/chrome"`) is taken
/// relative to the script's own folder, the usual meaning of such
/// variables. Caller owns the result.
pub fn scriptTarget(gpa: std.mem.Allocator, text: []const u8, script_dir: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, text, "#!")) return null;
    var found: ?[]u8 = null;
    errdefer if (found) |f| gpa.free(f);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "exec ")) continue;
        var toks = std.mem.tokenizeAny(u8, line[5..], " \t");
        const cmd = while (toks.next()) |t| {
            if (std.mem.eql(u8, t, "-a")) {
                _ = toks.next();
            } else if (t[0] != '-') break std.mem.trim(u8, t, "\"'");
        } else continue;
        const path = if (cmd.len > 0 and cmd[0] == '/')
            try gpa.dupe(u8, cmd)
        else if (cmd.len > 0 and cmd[0] == '$') blk: {
            const slash = std.mem.indexOfScalar(u8, cmd, '/') orelse continue;
            break :blk try std.fs.path.join(gpa, &.{ script_dir, cmd[slash + 1 ..] });
        } else continue; // redirections (exec < /dev/null), plain names
        if (found) |f| gpa.free(f);
        found = path;
    }
    return found;
}

// ------------------------------------------------------- the file itself

/// Loads `apps.tslx` into an empty store. A missing file is an empty
/// registry; an unreadable one is moved aside to `<path>.broken`.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, store: *Store, log: *@import("txcore").format.RepairLog) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(bytes);
    store.decode(bytes, log) catch |err| {
        const aside = try std.fmt.allocPrint(gpa, "{s}.broken", .{path});
        defer gpa.free(aside);
        std.Io.Dir.renameAbsolute(path, aside, io) catch {};
        return err;
    };
}

/// Writes `apps.tslx`: a temporary file renamed over the old one, so a
/// crash never leaves half a file.
pub fn save(gpa: std.mem.Allocator, io: std.Io, path: []const u8, store: *Store) !void {
    store.save_count += 1;
    const bytes = try store.encode(gpa);
    defer gpa.free(bytes);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

// --------------------------------------------------------------- tests

test "shell wrappers lead to the real binary" {
    const gpa = std.testing.allocator;
    const chrome =
        \\#!/bin/bash
        \\HERE="`dirname "$THIS"`"
        \\exec < /dev/null
        \\exec > >(exec cat)
        \\exec 2> >(exec cat >&2)
        \\exec -a "$0" "$HERE/chrome" "$@"
    ;
    const t = (try scriptTarget(gpa, chrome, "/opt/google/chrome")).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("/opt/google/chrome/chrome", t);

    const plain = (try scriptTarget(gpa, "#!/bin/sh\nexport X=1\nexec /usr/lib/app/app --flag \"$@\"\n", "/usr/bin")).?;
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("/usr/lib/app/app", plain);

    try std.testing.expect(try scriptTarget(gpa, "#!/usr/bin/python3\nimport gi\n", "/usr/bin") == null);
    try std.testing.expect(try scriptTarget(gpa, "\x7fELF", "/usr/bin") == null);
}

/// A small system in a temporary folder: binaries, a wrapper, a desktop
/// entry, an icon and dpkg records.
const World = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    buf: [std.fs.max_path_bytes]u8 = undefined,

    /// In place: `root` points into `buf`.
    fn init(self: *World) !void {
        self.tmp = std.testing.tmpDir(.{});
        const n = try self.tmp.dir.realPath(std.testing.io, &self.buf);
        self.root = self.buf[0..n];
    }

    fn deinit(self: *World) void {
        self.tmp.cleanup();
    }

    fn write(self: *World, sub: []const u8, data: []const u8, exec: bool) !void {
        const io = std.testing.io;
        if (std.fs.path.dirname(sub)) |d| try self.tmp.dir.createDirPath(io, d);
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data, .flags = .{ .permissions = if (exec) .executable_file else .default_file } });
    }
};

test "scan: find, skip, ghost, revive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = w.root;

    try w.write("bin/wayland-app", @embedFile("testdata/wayland-app"), true);
    try w.write("bin/x11-app", @embedFile("testdata/x11-app"), true);
    try w.write("bin/xset", @embedFile("testdata/x11-tool"), true);
    try w.write("bin/cage", @embedFile("testdata/server"), true);
    try w.write("bin/readme", "not a program", false);
    try w.write("opt/gtk/gtk-app", @embedFile("testdata/gtk-app"), true);
    try w.write("bin/gtk-wrapper", try std.fmt.allocPrint(a, "#!/bin/sh\nexec {s}/opt/gtk/gtk-app \"$@\"\n", .{r}), true);
    try w.write("share/applications/org.example.Wayland.desktop",
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Wayland Example
        \\Exec=wayland-app --new-window %U
        \\Icon=wapp
        \\Categories=Utility;Viewer;
    , false);
    try w.write("share/applications/htop.desktop", "[Desktop Entry]\nType=Application\nExec=htop\nTerminal=true\n", false);
    try w.write("icons/hicolor/48x48/apps/wapp.png", "small", false);
    try w.write("icons/hicolor/128x128/apps/wapp.png", "big", false);
    try w.write("dpkg/info/wapp:arm64.list", try std.fmt.allocPrint(a, "/.\n{s}/bin/wayland-app\n", .{r}), false);
    try w.write("dpkg/status", "Package: wapp\nStatus: install ok installed\nVersion: 1.0-1\n\n", false);

    var store = Store.init(gpa);
    defer store.deinit();
    try store.paths.append(store.allocator(), .{ .kind = .binaries, .path = try std.fs.path.join(a, &.{ r, "bin" }) });
    try store.paths.append(store.allocator(), .{ .kind = .binaries, .path = try std.fs.path.join(a, &.{ r, "opt" }), .depth = 3 });
    try store.paths.append(store.allocator(), .{ .kind = .desktop_entries, .path = try std.fs.path.join(a, &.{ r, "share/applications" }) });
    const icon_roots = [_][]const u8{try std.fs.path.join(a, &.{ r, "icons" })};
    const env: Env = .{
        .io = io,
        .home = r,
        .now_s = 1_000,
        .dpkg_dir = try std.fs.path.join(a, &.{ r, "dpkg" }),
        .icon_roots = &icon_roots,
        .pixmaps = try std.fs.path.join(a, &.{ r, "pixmaps" }),
    };

    // First scan: two apps; the rest are remembered with the reason.
    const r1 = try scan(gpa, &store, env);
    try std.testing.expectEqual(@as(usize, 2), store.apps.items.len);
    const wapp = store.findByBinary(try std.fs.path.join(a, &.{ r, "bin/wayland-app" })).?;
    try std.testing.expectEqualStrings("org.example.Wayland", wapp.id);
    try std.testing.expectEqualStrings("Wayland Example", wapp.name);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ r, "bin/wayland-app" }), wapp.exec[0]);
    try std.testing.expectEqualStrings("%U", wapp.exec[2]);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ r, "icons/hicolor/128x128/apps/wapp.png" }), wapp.icon);
    try std.testing.expectEqualStrings("Viewer", wapp.groups[1]);
    try std.testing.expectEqual(types.PackageManager.apt, wapp.manager);
    try std.testing.expectEqualStrings("wapp", wapp.package);
    try std.testing.expectEqualStrings("1.0-1", wapp.version);
    try std.testing.expectEqual(types.AppDisplay.wayland, wapp.display);

    const gtk = store.findByBinary(try std.fs.path.join(a, &.{ r, "opt/gtk/gtk-app" })).?;
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ r, "bin/gtk-wrapper" }), gtk.exec[0]);
    try std.testing.expectEqual(types.PackageManager.manual, gtk.manager);

    const verdict = struct {
        fn of(s: *Store, p: []const u8) ?types.ScanVerdict {
            return if (s.scanned.get(p)) |e| e.verdict else null;
        }
    }.of;
    try std.testing.expectEqual(types.ScanVerdict.x11_only, verdict(&store, try std.fs.path.join(a, &.{ r, "bin/x11-app" })).?);
    try std.testing.expectEqual(types.ScanVerdict.display_client, verdict(&store, try std.fs.path.join(a, &.{ r, "bin/xset" })).?);
    try std.testing.expectEqual(types.ScanVerdict.server, verdict(&store, try std.fs.path.join(a, &.{ r, "bin/cage" })).?);
    try std.testing.expectEqual(types.ScanVerdict.none, verdict(&store, try std.fs.path.join(a, &.{ r, "share/applications/htop.desktop" })).?);
    try std.testing.expect(r1.inspected >= 5);

    // Save and load: the second scan reads nothing.
    const file = try std.fs.path.join(a, &.{ r, "state/apps.tslx" });
    try save(gpa, io, file, &store);
    var again = Store.init(gpa);
    defer again.deinit();
    var log: @import("txcore").format.RepairLog = .{};
    try load(gpa, io, file, &again, &log);
    try std.testing.expectEqual(@as(u32, 0), log.total());
    const r2 = try scan(gpa, &again, env);
    try std.testing.expectEqual(@as(u32, 0), r2.inspected);
    try std.testing.expectEqual(@as(u32, 0), r2.desktop_entries);
    try std.testing.expectEqual(@as(usize, 0), r2.changes.items.len);

    // The app is uninstalled: a ghost.
    try w.tmp.dir.deleteFile(io, "bin/wayland-app");
    const r3 = try scan(gpa, &again, env);
    try std.testing.expectEqual(ChangeKind.ghost, r3.changes.items[0].kind);
    const ghost = again.findById("org.example.Wayland").?;
    try std.testing.expectEqual(types.AppStatus.missing, ghost.status);
    try std.testing.expectEqual(@as(i64, 1_000), ghost.missing_since_s);

    // It shows up somewhere else: the ghost is revived with the new path,
    // its name, icon and arguments kept.
    try w.write("opt/wapp/bin/wayland-app", @embedFile("testdata/wayland-app"), true);
    const r4 = try scan(gpa, &again, env);
    try std.testing.expectEqual(ChangeKind.revived, r4.changes.items[0].kind);
    const moved = again.findById("org.example.Wayland").?;
    try std.testing.expectEqual(types.AppStatus.installed, moved.status);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ r, "opt/wapp/bin/wayland-app" }), moved.binary);
    try std.testing.expectEqualStrings(moved.binary, moved.exec[0]);
    try std.testing.expectEqualStrings("--new-window", moved.exec[1]);
    try std.testing.expectEqualStrings("Wayland Example", moved.name);
    try std.testing.expectEqual(@as(usize, 2), again.apps.items.len);

    // Asked for X11 apps: the X11-only binary is looked at again.
    var env_x11 = env;
    env_x11.x11 = true;
    const r5 = try scan(gpa, &again, env_x11);
    try std.testing.expectEqual(ChangeKind.new, r5.changes.items[0].kind);
    try std.testing.expectEqual(types.AppDisplay.x11, again.findById("x11-app").?.display);
}
