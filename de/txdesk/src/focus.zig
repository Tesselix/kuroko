//! Focus and Recent: txdesk's recorder and its simple predictor
//! (docs/user-signals.md, "Focus, before recent"; Top-Level Design,
//! "Influence files").
//!
//! The recorder turns the compositor's scene into facts: one use per window
//! (an episode) with when it opened and closed and how long it had keyboard
//! focus (facts.krkde). The predictor reads the facts and writes the
//! launcher's lists (focus.krkde, sdk/txcore/src/influence.zig):
//!
//!   Focus first, at most 4:
//!     - cycles that are due: an app opened in the first hour of the day on
//!       at least 3 days, and on more than half of the recent days, is in
//!       Focus during the first hour of today. There are no login events
//!       yet: the first window of the day stands in for the login.
//!     - real interest: time with keyboard focus, halving every 3 days
//!       (salience); at least 2 minutes' worth. An app opened and closed at
//!       once earns nothing.
//!   Recent second, at most 4: what is not in Focus, by when it was last
//!   opened. Time only.
//!
//! Apps only for now: nothing reports which file a window shows yet, so
//! uses carry an empty object.
//!
//! Pure: no I/O. Times are Unix seconds; `tz_s` is the local offset from
//! UTC, for day boundaries.

const std = @import("std");
const core = @import("txcore");
const types = core.types;
const format = core.format;
const influence = core.influence;
const Pick = influence.Pick;

pub const day_s: i64 = 24 * 60 * 60;
/// Salience halves every 3 days.
const half_life_s: f64 = 3 * 24 * 60 * 60;
/// Decayed seconds with keyboard focus needed to be in Focus.
const min_salience_s: f64 = 120;
/// The "first hour" of a day, for cycles.
const cycle_window_s: i64 = 60 * 60;
/// Days looked back for cycles, and days needed.
const cycle_days = 14;
const cycle_min_hits = 3;
/// Facts older than this are dropped, and at most this many are kept.
const keep_s: i64 = 60 * day_s;
const max_uses = 5000;

pub const Use = struct {
    app: []const u8,
    object: []const u8 = "",
    opened_s: i64,
    closed_s: i64,
    focused_s: u32 = 0,
};

/// A window on screen now, as the scene shows it.
pub const WindowNow = struct {
    id: u64,
    /// Its binary, or its app id for Kuroko's own apps.
    app: []const u8,
    focused: bool,
};

const Live = struct {
    id: u64,
    use: Use,
    focus_since: ?i64,
};

pub const Facts = struct {
    gpa: std.mem.Allocator,
    /// Closed uses, oldest first. Strings owned.
    uses: std.ArrayList(Use) = .empty,
    /// Windows open now. Strings owned.
    live: std.ArrayList(Live) = .empty,
    save_count: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Facts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Facts) void {
        for (self.uses.items) |u| self.freeUse(u);
        self.uses.deinit(self.gpa);
        for (self.live.items) |l| self.freeUse(l.use);
        self.live.deinit(self.gpa);
    }

    fn freeUse(self: *Facts, u: Use) void {
        self.gpa.free(u.app);
        self.gpa.free(u.object);
    }

    pub const Changes = struct {
        opened: u32 = 0,
        closed: u32 = 0,
        focus: bool = false,

        pub fn any(c: Changes) bool {
            return c.opened > 0 or c.closed > 0 or c.focus;
        }
    };

    /// Brings the open uses in line with the windows on screen.
    pub fn sync(self: *Facts, windows: []const WindowNow, now_s: i64) !Changes {
        var ch: Changes = .{};
        // Closed since the last sync.
        var i: usize = 0;
        while (i < self.live.items.len) {
            const l = self.live.items[i];
            const still = for (windows) |w| {
                if (w.id == l.id) break true;
            } else false;
            if (still) {
                i += 1;
                continue;
            }
            try self.closeLive(i, now_s);
            ch.closed += 1;
        }
        for (windows) |w| {
            if (w.app.len == 0) continue;
            const l = for (self.live.items) |*l| {
                if (l.id == w.id) break l;
            } else null;
            if (l) |live| {
                if (w.focused and live.focus_since == null) {
                    live.focus_since = now_s;
                    ch.focus = true;
                } else if (!w.focused and live.focus_since != null) {
                    live.use.focused_s +|= @intCast(@max(0, now_s - live.focus_since.?));
                    live.focus_since = null;
                    ch.focus = true;
                }
                continue;
            }
            const app = try self.gpa.dupe(u8, w.app);
            errdefer self.gpa.free(app);
            try self.live.append(self.gpa, .{
                .id = w.id,
                .use = .{ .app = app, .object = try self.gpa.dupe(u8, ""), .opened_s = now_s, .closed_s = now_s },
                .focus_since = if (w.focused) now_s else null,
            });
            ch.opened += 1;
        }
        return ch;
    }

    /// The compositor went away: every open use ends now.
    pub fn closeAll(self: *Facts, now_s: i64) !void {
        while (self.live.items.len > 0) try self.closeLive(self.live.items.len - 1, now_s);
    }

    fn closeLive(self: *Facts, i: usize, now_s: i64) !void {
        var u = self.live.items[i].use;
        if (self.live.items[i].focus_since) |since| u.focused_s +|= @intCast(@max(0, now_s - since));
        u.closed_s = now_s;
        try self.uses.append(self.gpa, u);
        _ = self.live.orderedRemove(i);
        self.prune(now_s);
    }

    fn prune(self: *Facts, now_s: i64) void {
        var drop: usize = 0;
        while (drop < self.uses.items.len) : (drop += 1) {
            const old = self.uses.items[drop].closed_s < now_s - keep_s;
            const over = self.uses.items.len - drop > max_uses;
            if (!old and !over) break;
            self.freeUse(self.uses.items[drop]);
        }
        if (drop > 0) self.uses.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    /// A use of an open window as it stands now.
    fn liveNow(l: Live, now_s: i64) Use {
        var u = l.use;
        u.closed_s = now_s;
        if (l.focus_since) |since| u.focused_s +|= @intCast(@max(0, now_s - since));
        return u;
    }

    // ---------------------------------------------------------- file

    /// Closed uses, then the open ones as they stand now.
    pub fn encode(self: *const Facts, gpa: std.mem.Allocator, now_s: i64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(gpa);
        try format.appendStruct(gpa, &out, types.facts_header, 1, types.FactsHeader{ .save_count = self.save_count }, "");
        for (self.uses.items) |u| try appendUse(gpa, &out, &extra, u);
        for (self.live.items) |l| try appendUse(gpa, &out, &extra, liveNow(l, now_s));
        return out.toOwnedSlice(gpa);
    }

    fn appendUse(gpa: std.mem.Allocator, out: *std.ArrayList(u8), extra: *std.ArrayList(u8), u: Use) !void {
        if (u.app.len > std.math.maxInt(u16) or u.object.len > std.math.maxInt(u16)) return;
        extra.clearRetainingCapacity();
        try extra.appendSlice(gpa, u.app);
        try extra.appendSlice(gpa, u.object);
        try format.appendStruct(gpa, out, types.fact_use, 1, types.FactUse{
            .opened_s = u.opened_s,
            .closed_s = u.closed_s,
            .focused_s = u.focused_s,
            .app_len = @intCast(u.app.len),
            .object_len = @intCast(u.object.len),
        }, extra.items);
    }

    /// Loads saved uses (all closed: their windows belong to an earlier
    /// run). Damaged records are skipped and counted.
    pub fn decode(self: *Facts, bytes: []const u8, log: *format.RepairLog) !void {
        var reader = format.Reader.init(bytes, &types.known);
        while (reader.next()) |rec| {
            if (rec.swapped) continue;
            switch (rec.type_id) {
                types.facts_header => self.save_count = format.readStruct(types.FactsHeader, rec).save_count,
                types.fact_use => {
                    const e = format.readStruct(types.FactUse, rec);
                    const t = format.trailing(types.FactUse, rec);
                    if (@as(usize, e.app_len) + e.object_len != t.len or e.app_len == 0) {
                        log.note(.truncated);
                        continue;
                    }
                    const app = try self.gpa.dupe(u8, t[0..e.app_len]);
                    errdefer self.gpa.free(app);
                    const object = try self.gpa.dupe(u8, t[e.app_len..]);
                    errdefer self.gpa.free(object);
                    try self.uses.append(self.gpa, .{ .app = app, .object = object, .opened_s = e.opened_s, .closed_s = e.closed_s, .focused_s = e.focused_s });
                },
                else => {},
            }
        }
        reader.finish();
        for (std.enums.values(format.Repair)) |rp| {
            if (rp != .none) log.counts.getPtr(rp).* += reader.log.counts.get(rp);
        }
    }

    // ------------------------------------------------------- predict

    const Agg = struct {
        salience: f64 = 0,
        week_s: u64 = 0,
        last_opened: i64 = 0,
        /// Bit d: opened in the first hour of the day `d` days before today.
        cycle_days: u32 = 0,
    };

    /// Focus first, then Recent from what is not in Focus. The picks'
    /// strings point into the facts: encode them before the next change.
    pub fn predict(self: *const Facts, gpa: std.mem.Allocator, now_s: i64, tz_s: i64, out: *std.ArrayList(Pick)) !void {
        out.clearRetainingCapacity();
        const today = dayOf(now_s, tz_s);

        // The first use of each recent day stands in for the login.
        var first: [cycle_days + 1]?i64 = @splat(null);
        var all: std.ArrayList(Use) = .empty;
        defer all.deinit(gpa);
        try all.appendSlice(gpa, self.uses.items);
        for (self.live.items) |l| try all.append(gpa, liveNow(l, now_s));
        for (all.items) |u| {
            const back = today - dayOf(u.opened_s, tz_s);
            if (back < 0 or back > cycle_days) continue;
            const slot = &first[@intCast(back)];
            if (slot.* == null or u.opened_s < slot.*.?) slot.* = u.opened_s;
        }

        var aggs: std.StringArrayHashMapUnmanaged(Agg) = .empty;
        defer aggs.deinit(gpa);
        for (all.items) |u| {
            const gop = try aggs.getOrPut(gpa, u.app);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const a = gop.value_ptr;
            const age: f64 = @floatFromInt(@max(0, now_s - u.closed_s));
            a.salience += @as(f64, @floatFromInt(u.focused_s)) * std.math.pow(f64, 0.5, age / half_life_s);
            if (u.closed_s >= now_s - 7 * day_s) a.week_s += u.focused_s;
            a.last_opened = @max(a.last_opened, u.opened_s);
            const back = today - dayOf(u.opened_s, tz_s);
            if (back >= 1 and back <= cycle_days) {
                if (first[@intCast(back)]) |f| {
                    if (u.opened_s < f + cycle_window_s) a.cycle_days |= @as(u32, 1) << @intCast(back);
                }
            }
        }

        // Days with any use, before today.
        var used_days: u32 = 0;
        for (1..cycle_days + 1) |d| {
            if (first[d] != null) used_days += 1;
        }
        // The first hour of today (no use yet today: it starts now).
        const today_first = first[0] orelse now_s;
        const cycle_due = now_s < today_first + cycle_window_s;

        const Cand = struct { app: []const u8, key: f64, agg: Agg };
        var cycles: std.ArrayList(Cand) = .empty;
        defer cycles.deinit(gpa);
        var liked: std.ArrayList(Cand) = .empty;
        defer liked.deinit(gpa);
        var it = aggs.iterator();
        while (it.next()) |e| {
            const a = e.value_ptr.*;
            const hits = @popCount(a.cycle_days);
            if (cycle_due and hits >= cycle_min_hits and hits * 2 > used_days) {
                try cycles.append(gpa, .{ .app = e.key_ptr.*, .key = @floatFromInt(hits), .agg = a });
            } else if (a.salience >= min_salience_s) {
                try liked.append(gpa, .{ .app = e.key_ptr.*, .key = a.salience, .agg = a });
            }
        }
        const byKey = struct {
            fn lt(_: void, x: Cand, y: Cand) bool {
                if (x.key != y.key) return x.key > y.key;
                return std.mem.lessThan(u8, x.app, y.app);
            }
        }.lt;
        std.mem.sort(Cand, cycles.items, {}, byKey);
        std.mem.sort(Cand, liked.items, {}, byKey);

        var n_focus: usize = 0;
        for (cycles.items) |c| {
            if (n_focus == influence.max_per_list) break;
            try out.append(gpa, .{ .list = .focus, .reason = .cycle, .value = @intCast(@popCount(c.agg.cycle_days)), .app = c.app });
            n_focus += 1;
        }
        for (liked.items) |c| {
            if (n_focus == influence.max_per_list) break;
            try out.append(gpa, .{ .list = .focus, .reason = .used, .value = @intCast(@max(1, c.agg.week_s / 60)), .app = c.app });
            n_focus += 1;
        }

        // Recent: the rest, by time only.
        var rest: std.ArrayList(Cand) = .empty;
        defer rest.deinit(gpa);
        it = aggs.iterator();
        while (it.next()) |e| {
            const in_focus = for (out.items[0..n_focus]) |p| {
                if (std.mem.eql(u8, p.app, e.key_ptr.*)) break true;
            } else false;
            if (in_focus) continue;
            try rest.append(gpa, .{ .app = e.key_ptr.*, .key = @floatFromInt(e.value_ptr.last_opened), .agg = e.value_ptr.* });
        }
        std.mem.sort(Cand, rest.items, {}, byKey);
        for (rest.items[0..@min(rest.items.len, influence.max_per_list)]) |c| {
            try out.append(gpa, .{ .list = .recent, .reason = .opened, .value = c.agg.last_opened, .app = c.app });
        }
    }
};

pub fn dayOf(t_s: i64, tz_s: i64) i64 {
    return @divFloor(t_s + tz_s, day_s);
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn findPick(picks: []const Pick, list: influence.List, app: []const u8) ?Pick {
    for (picks) |p| {
        if (p.list == list and std.mem.eql(u8, p.app, app)) return p;
    }
    return null;
}

test "a window opened and closed at once is recent, not in focus" {
    const gpa = testing.allocator;
    var f = Facts.init(gpa);
    defer f.deinit();
    const t0: i64 = 1_760_000_000;
    _ = try f.sync(&.{.{ .id = 1, .app = "/usr/bin/viewer", .focused = true }}, t0);
    _ = try f.sync(&.{}, t0 + 3);
    var picks: std.ArrayList(Pick) = .empty;
    defer picks.deinit(gpa);
    try f.predict(gpa, t0 + 60, 0, &picks);
    try testing.expect(findPick(picks.items, .focus, "/usr/bin/viewer") == null);
    try testing.expectEqual(t0, findPick(picks.items, .recent, "/usr/bin/viewer").?.value);
}

test "time with keyboard focus puts an app in focus, and it leaves recent" {
    const gpa = testing.allocator;
    var f = Facts.init(gpa);
    defer f.deinit();
    const t0: i64 = 1_760_000_000;
    // Editor: 20 minutes focused. Browser: open longer, never focused.
    _ = try f.sync(&.{ .{ .id = 1, .app = "/usr/bin/editor", .focused = true }, .{ .id = 2, .app = "/usr/bin/browser", .focused = false } }, t0);
    const c = try f.sync(&.{ .{ .id = 1, .app = "/usr/bin/editor", .focused = false }, .{ .id = 2, .app = "/usr/bin/browser", .focused = true } }, t0 + 20 * 60);
    try testing.expect(c.focus);
    _ = try f.sync(&.{.{ .id = 2, .app = "/usr/bin/browser", .focused = false }}, t0 + 20 * 60 + 10);
    var picks: std.ArrayList(Pick) = .empty;
    defer picks.deinit(gpa);
    try f.predict(gpa, t0 + 21 * 60, 0, &picks);
    const ed = findPick(picks.items, .focus, "/usr/bin/editor").?;
    try testing.expectEqual(influence.Reason.used, ed.reason);
    try testing.expectEqual(@as(i64, 20), ed.value);
    try testing.expect(findPick(picks.items, .recent, "/usr/bin/editor") == null);
    try testing.expect(findPick(picks.items, .recent, "/usr/bin/browser") != null);

    // Two weeks later the interest has faded.
    try f.predict(gpa, t0 + 14 * day_s, 0, &picks);
    try testing.expect(findPick(picks.items, .focus, "/usr/bin/editor") == null);
}

test "an app opened every morning is in focus during today's first hour" {
    const gpa = testing.allocator;
    var f = Facts.init(gpa);
    defer f.deinit();
    const day0: i64 = 20_000 * day_s; // a midnight (UTC)
    // Five days: login at 9:00 (a terminal), the report app at 9:10.
    for (1..6) |d| {
        const base = day0 - @as(i64, @intCast(d)) * day_s + 9 * 3600;
        _ = try f.sync(&.{.{ .id = d * 10, .app = "/usr/bin/term", .focused = false }}, base);
        _ = try f.sync(&.{ .{ .id = d * 10, .app = "/usr/bin/term", .focused = false }, .{ .id = d * 10 + 1, .app = "/usr/bin/report", .focused = false } }, base + 600);
        _ = try f.sync(&.{}, base + 630);
    }
    var picks: std.ArrayList(Pick) = .empty;
    defer picks.deinit(gpa);
    // Today, 9:05, after logging in at 9:00.
    _ = try f.sync(&.{.{ .id = 99, .app = "/usr/bin/term", .focused = false }}, day0 + 9 * 3600);
    try f.predict(gpa, day0 + 9 * 3600 + 300, 0, &picks);
    const rep = findPick(picks.items, .focus, "/usr/bin/report").?;
    try testing.expectEqual(influence.Reason.cycle, rep.reason);
    try testing.expectEqual(@as(i64, 5), rep.value);
    // After the first hour it is only recent.
    try f.predict(gpa, day0 + 11 * 3600, 0, &picks);
    try testing.expect(findPick(picks.items, .focus, "/usr/bin/report") == null);
    try testing.expect(findPick(picks.items, .recent, "/usr/bin/report") != null);
}

test "facts survive a round trip; open uses are saved as they stand" {
    const gpa = testing.allocator;
    var f = Facts.init(gpa);
    defer f.deinit();
    const t0: i64 = 1_760_000_000;
    _ = try f.sync(&.{.{ .id = 1, .app = "/usr/bin/a", .focused = true }}, t0);
    _ = try f.sync(&.{}, t0 + 100);
    _ = try f.sync(&.{.{ .id = 2, .app = "org.kuroko.notes", .focused = true }}, t0 + 200);
    const bytes = try f.encode(gpa, t0 + 260);
    defer gpa.free(bytes);

    var g = Facts.init(gpa);
    defer g.deinit();
    var log: format.RepairLog = .{};
    try g.decode(bytes, &log);
    try testing.expectEqual(@as(u32, 0), log.total());
    try testing.expectEqual(@as(usize, 2), g.uses.items.len);
    try testing.expectEqual(@as(u32, 100), g.uses.items[0].focused_s);
    try testing.expectEqual(@as(u32, 60), g.uses.items[1].focused_s);
    try testing.expectEqualStrings("org.kuroko.notes", g.uses.items[1].app);
}
