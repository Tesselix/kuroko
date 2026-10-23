//! txdesk: the first desktop service, a stub of the context hub.
//!
//! It connects to the compositor's socket, reads scene-graph deltas
//! (Tesselix records, with the validation and repair ladder), keeps its own
//! copy of the scene, and prints it as terse text: the form the agent will
//! reason over (Design Concept, "Text, not pixels").
//!
//! It runs as a separate process. If it crashes or hangs, the compositor
//! carries on; if the compositor restarts, txdesk reconnects.
//!
//! It also keeps the app registry (apps/): it loads apps.tslx, sends the
//! known apps to the compositor, scans for changes (at start, then every
//! five minutes; apt updates every six hours), saves, and sends what
//! changed. By hand:
//!   txdesk apps scan [--x11] [--verbose] [--file PATH]
//!                         scan for installed graphical apps, update apps.tslx
//!   txdesk apps list [--skipped] [--file PATH]
//!                         print the registry
//! The file is $XDG_STATE_HOME/tesselix/apps.tslx (~/.local/state/...).

const std = @import("std");
const core = @import("txcore");
const types = core.types;
const apps = @import("apps/root.zig");

const Win = struct {
    id: u64,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    app_id: [96]u8 = undefined,
    app_id_len: usize = 0,
    rect: core.Rect = .{},
    focused: bool = false,
    shelved: bool = false,
    status: types.Status = .normal,
    progress: f32 = 0,
};

const Scene = struct {
    gpa: std.mem.Allocator,
    windows: std.ArrayList(Win) = .empty,
    snapshot: bool = false,

    fn find(self: *Scene, id: u64) ?*Win {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn apply(self: *Scene, rec: core.format.Record) !bool {
        if (rec.type_id != types.scene_window) return false;
        const m = core.format.readStruct(types.SceneWindow, rec);
        const extra = core.format.trailing(types.SceneWindow, rec);
        switch (m.kind) {
            .snapshot_begin => {
                self.windows.clearRetainingCapacity();
                self.snapshot = true;
                return false;
            },
            .snapshot_end => {
                self.snapshot = false;
                return true;
            },
            .closed => {
                for (self.windows.items, 0..) |w, i| {
                    if (w.id == m.window_id) {
                        _ = self.windows.orderedRemove(i);
                        break;
                    }
                }
            },
            .opened, .changed => {
                const w = self.find(m.window_id) orelse blk: {
                    try self.windows.append(self.gpa, .{ .id = m.window_id });
                    break :blk &self.windows.items[self.windows.items.len - 1];
                };
                // Strings are length-prefixed by the struct; never trust
                // them past the payload.
                const tl = @min(m.title_len, extra.len, w.title.len);
                @memcpy(w.title[0..tl], extra[0..tl]);
                w.title_len = tl;
                const rest = extra[@min(m.title_len, extra.len)..];
                const al = @min(m.app_id_len, rest.len, w.app_id.len);
                @memcpy(w.app_id[0..al], rest[0..al]);
                w.app_id_len = al;
                w.rect = .{ .x = m.x, .y = m.y, .w = m.w, .h = m.h };
                w.focused = m.focused != 0;
                w.shelved = m.shelved != 0;
                w.status = m.status;
                w.progress = m.progress;
            },
        }
        return !self.snapshot;
    }

    fn print(self: *const Scene, out: anytype, t: f64) !void {
        try out.print("scene t={d:.1}s windows={d}\n", .{ t, self.windows.items.len });
        for (self.windows.items) |w| {
            const h = core.Handle.fromId(w.id);
            try out.print("  win#{d}.{d} {s} \"{s}\" [{d},{d} {d}x{d}]", .{ h.index, h.generation, w.app_id[0..w.app_id_len], w.title[0..w.title_len], w.rect.x, w.rect.y, w.rect.w, w.rect.h });
            if (w.focused) try out.print(" focused", .{});
            if (w.shelved) try out.print(" shelved", .{});
            switch (w.status) {
                .normal => {},
                .progress => try out.print(" progress={d:.0}%", .{w.progress * 100}),
                .working => try out.print(" working", .{}),
                .failed => try out.print(" error", .{}),
            }
            try out.print("\n", .{});
        }
    }
};

/// How often the registry is checked again (cheap: known files are only
/// `stat`ed), and how often apt is asked about updates.
const scan_every_ms: i64 = 5 * 60 * 1000;
const updates_every_ms: i64 = 6 * 60 * 60 * 1000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "apps")) return appsCommand(init, args[2..]);

    var path_buf: [512]u8 = undefined;
    const path = try core.ipc.socketPath(&path_buf, core.ipc.compositor_socket);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    var scene: Scene = .{ .gpa = gpa };
    defer scene.windows.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    // The app registry: loaded first, so the compositor gets the known
    // apps at once; scanned right after.
    var desk: Desk = .{
        .gpa = gpa,
        .io = io,
        .out = out,
        .file = try registryFile(init),
        .home = init.environ_map.get("HOME") orelse "/",
        .store = .init(gpa),
        .link = .init(gpa),
    };
    defer desk.deinit();
    desk.load();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var log: core.format.RepairLog = .{};
    var next_scan: i64 = 0;
    var waiting_said = false;
    while (true) {
        if (desk.fd == null) {
            if (core.ipc.connect(path)) |fd| {
                desk.fd = fd;
                waiting_said = false;
                buf.clearRetainingCapacity();
                scene.windows.clearRetainingCapacity();
                try out.print("txdesk: connected\n", .{});
                desk.sendSnapshot();
            } else |_| if (!waiting_said) {
                try out.print("txdesk: waiting for the compositor at {s}\n", .{path});
                waiting_said = true;
            }
            try out.flush();
        }

        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now >= next_scan) {
            desk.refresh(now);
            next_scan = now + scan_every_ms;
        }

        const left: i32 = @intCast(std.math.clamp(next_scan - std.Io.Timestamp.now(io, .awake).toMilliseconds(), 0, 2000));
        const fd = desk.fd orelse {
            io.sleep(.fromMilliseconds(left), .awake) catch {};
            continue;
        };
        if (!core.ipc.waitReadable(fd, left)) continue;
        var chunk: [8192]u8 = undefined;
        const n = core.ipc.read(fd, &chunk) catch 0;
        if (n == 0) {
            desk.disconnect();
            try out.print("txdesk: compositor closed the connection; reconnecting\n", .{});
            try out.flush();
            continue;
        }
        try buf.appendSlice(gpa, chunk[0..n]);

        var reader = core.format.Reader.init(buf.items, &types.known);
        var changed = false;
        while (reader.next()) |rec| {
            if (rec.type_id == types.desk_request) {
                const req = core.format.readStruct(types.DeskRequest, rec);
                if (req.kind == .app_snapshot) desk.sendSnapshot();
                continue;
            }
            if (try scene.apply(rec)) changed = true;
        }
        for (std.enums.values(core.format.Repair)) |r| {
            if (r != .none) log.counts.getPtr(r).* += reader.log.counts.get(r);
        }
        // Keep a partial record for the next read.
        const rest = reader.remaining().len;
        std.mem.copyForwards(u8, buf.items[0..rest], buf.items[buf.items.len - rest ..]);
        buf.shrinkRetainingCapacity(rest);

        if (changed) {
            const t = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).toMilliseconds() - start)) / 1000;
            try scene.print(out, t);
            if (log.total() > 0) try out.print("  (repairs so far: {d})\n", .{log.total()});
            try out.flush();
        }
    }
}

/// The app registry as the running service keeps it: the file, and the
/// compositor's copy (link.zig). Saves first, then tells the compositor.
const Desk = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    file: []const u8,
    home: []const u8,
    store: apps.store.Store,
    link: apps.link.Link,
    fd: ?core.ipc.Fd = null,
    next_updates: i64 = 0,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Desk) void {
        self.disconnect();
        self.bytes.deinit(self.gpa);
        self.link.deinit();
        self.store.deinit();
    }

    fn load(self: *Desk) void {
        var log: core.format.RepairLog = .{};
        apps.scan.load(self.gpa, self.io, self.file, &self.store, &log) catch |err| {
            self.out.print("txdesk: {s} is unreadable ({s}); moved aside, rebuilding\n", .{ self.file, @errorName(err) }) catch {};
        };
        if (log.total() > 0) self.out.print("txdesk: {s}: {d} damaged records skipped\n", .{ self.file, log.total() }) catch {};
        self.out.print("txdesk: {d} apps known\n", .{self.store.apps.items.len}) catch {};
    }

    /// Scan, check updates when due, save when anything changed, and send
    /// the changes. A failure is reported and the service carries on.
    fn refresh(self: *Desk, now_ms: i64) void {
        const t0 = std.Io.Timestamp.now(self.io, .awake);
        const report = apps.scan.scan(self.gpa, &self.store, .{
            .io = self.io,
            .home = self.home,
            .now_s = std.Io.Timestamp.now(self.io, .real).toSeconds(),
        }) catch |err| {
            self.out.print("txdesk: scan failed: {s}\n", .{@errorName(err)}) catch {};
            return;
        };
        var updated: u32 = 0;
        if (now_ms >= self.next_updates) {
            updated = apps.updates.check(self.gpa, self.io, &self.store) catch |err| blk: {
                self.out.print("txdesk: update check failed: {s}\n", .{@errorName(err)}) catch {};
                break :blk 0;
            };
            self.next_updates = now_ms + updates_every_ms;
        }
        const ms = t0.durationTo(std.Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        for (report.changes.items) |c| self.out.print("txdesk: app {s} {s}: {s}\n", .{ @tagName(c.kind), c.id, c.detail }) catch {};
        if (updated > 0) self.out.print("txdesk: update check: {d} apps changed\n", .{updated}) catch {};
        self.out.print("txdesk: scan {d} ms, {d} inspected, {d} known, {d} apps\n", .{ ms, report.inspected, report.skipped, self.store.apps.items.len }) catch {};
        self.out.flush() catch {};
        if (report.changes.items.len == 0 and report.inspected == 0 and report.desktop_entries == 0 and updated == 0) return;
        apps.scan.save(self.gpa, self.io, self.file, &self.store) catch |err| {
            self.out.print("txdesk: cannot save {s}: {s}\n", .{ self.file, @errorName(err) }) catch {};
            return;
        };
        if (self.fd == null) return;
        self.bytes.clearRetainingCapacity();
        self.link.changes(&self.bytes, &self.store) catch return;
        self.send();
    }

    fn sendSnapshot(self: *Desk) void {
        if (self.fd == null) return;
        self.bytes.clearRetainingCapacity();
        self.link.snapshot(&self.bytes, &self.store) catch return;
        self.send();
    }

    /// The socket blocks: txdesk may wait, the compositor never does.
    fn send(self: *Desk) void {
        const fd = self.fd orelse return;
        var rest = self.bytes.items;
        while (rest.len > 0) {
            const n = core.ipc.write(fd, rest) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return self.disconnect(),
            };
            rest = rest[n..];
        }
    }

    fn disconnect(self: *Desk) void {
        if (self.fd) |fd| core.ipc.close(fd);
        self.fd = null;
    }
};

fn registryFile(init: std.process.Init) ![]const u8 {
    const arena = init.arena.allocator();
    if (init.environ_map.get("XDG_STATE_HOME")) |st| return std.fs.path.join(arena, &.{ st, "tesselix/apps.tslx" });
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".local/state/tesselix/apps.tslx" });
}

// ------------------------------------------------------------ app registry

fn appsCommand(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    var file = try registryFile(init);
    var x11 = false;
    var verbose = false;
    var skipped = false;
    const cmd: []const u8 = if (args.len > 0) args[0] else "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--x11")) x11 = true else if (std.mem.eql(u8, a, "--verbose")) verbose = true else if (std.mem.eql(u8, a, "--skipped")) skipped = true else if (std.mem.eql(u8, a, "--file") and i + 1 < args.len) {
            i += 1;
            file = args[i];
        } else {
            try out.print("unknown option: {s}\n", .{a});
            return error.BadArgs;
        }
    }

    var store = apps.store.Store.init(gpa);
    defer store.deinit();
    var log: core.format.RepairLog = .{};
    apps.scan.load(gpa, io, file, &store, &log) catch |err| {
        try out.print("{s} is unreadable ({s}); moved aside to .broken, starting empty\n", .{ file, @errorName(err) });
    };
    if (log.total() > 0) try out.print("{s}: {d} damaged records skipped\n", .{ file, log.total() });

    if (std.mem.eql(u8, cmd, "scan")) {
        const start = std.Io.Timestamp.now(io, .awake);
        const report = try apps.scan.scan(gpa, &store, .{
            .io = io,
            .home = home,
            .now_s = std.Io.Timestamp.now(io, .real).toSeconds(),
            .x11 = x11,
            .trace = if (verbose) out else null,
        });
        const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        try apps.scan.save(gpa, io, file, &store);
        for (report.changes.items) |c| {
            try out.print("  {s:<9} {s}: {s}\n", .{ @tagName(c.kind), c.id, c.detail });
        }
        try out.print("scan: {d} ms, {d} files inspected, {d} skipped as known, {d} desktop entries read, {d} changes\n", .{ ms, report.inspected, report.skipped, report.desktop_entries, report.changes.items.len });
        try out.print("saved {s} (save {d})\n", .{ file, store.save_count });
    } else if (std.mem.eql(u8, cmd, "list")) {
        try printStore(out, &store, file, skipped);
    } else {
        try out.print("usage: txdesk apps scan [--x11] [--verbose] [--file PATH]\n       txdesk apps list [--skipped] [--file PATH]\n", .{});
        return error.BadArgs;
    }
}

fn printDate(out: *std.Io.Writer, unix_s: i64) !void {
    if (unix_s <= 0) return out.writeAll("never");
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_s) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try out.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
}

fn printList(out: *std.Io.Writer, items: []const []const u8) !void {
    for (items, 0..) |s, n| {
        if (n > 0) try out.writeByte(' ');
        try out.writeAll(s);
    }
}

fn printStore(out: *std.Io.Writer, store: *apps.store.Store, file: []const u8, skipped: bool) !void {
    try out.print("{s}: {d} apps, {d} scanned files, save {d}, last scan ", .{ file, store.apps.items.len, store.scanned.count(), store.save_count });
    try printDate(out, store.last_scan_s);
    try out.writeAll("\n\n");
    for (store.apps.items) |a| {
        const status = switch (a.status) {
            .installed => "installed",
            .missing => "GHOST",
            .hidden => "hidden",
            _ => "?",
        };
        try out.print("{s:<9}  {s}  \"{s}\"  {s}", .{ status, a.id, a.name, @tagName(a.display) });
        if (a.package.len > 0) try out.print("  {s} {s} {s}", .{ @tagName(a.manager), a.package, a.version }) else try out.print("  {s}", .{@tagName(a.manager)});
        if (a.status == .missing) {
            try out.writeAll("  missing since ");
            try printDate(out, a.missing_since_s);
        }
        try out.print("\n    binary:   {s}\n    exec:     ", .{a.binary});
        try printList(out, a.exec);
        if (a.icon.len > 0) try out.print("\n    icon:     {s}", .{a.icon});
        if (a.desktop_entry.len > 0) try out.print("\n    desktop:  {s}", .{a.desktop_entry});
        if (a.groups.len > 0) {
            try out.writeAll("\n    groups:   ");
            try printList(out, a.groups);
        }
        try out.writeAll("\n    evidence: ");
        try printList(out, a.evidence);
        try out.writeAll("\n\n");
    }
    var counts = std.EnumArray(types.ScanVerdict, u32).initFill(0);
    var it = store.scanned.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.verdict) {
            .none, .display_client, .server, .x11_only, .app => |v| counts.getPtr(v).* += 1,
            _ => {},
        }
    }
    try out.print("scanned: {d} not graphical, {d} display clients, {d} display servers, {d} X11-only, {d} belong to apps\n", .{ counts.get(.none), counts.get(.display_client), counts.get(.server), counts.get(.x11_only), counts.get(.app) });
    if (!skipped) return out.writeAll("(--skipped lists the display clients, servers and X11-only binaries)\n");
    it = store.scanned.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.verdict) {
            .display_client, .server, .x11_only => try out.print("  {s:<14} {s}\n", .{ @tagName(e.value_ptr.verdict), e.key_ptr.* }),
            else => {},
        }
    }
}
