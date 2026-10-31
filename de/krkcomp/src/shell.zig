//! Built-in shell UI drawn by the compositor: top bar, launcher, shelf
//! (Top-Level Design: "Top bar and control center", "Launcher").

const std = @import("std");
const core = @import("krkcore");
const tw = @import("krkwidgets");
const chrome = @import("chrome.zig");
const glyphs = @import("glyphs.zig");

const Rect = core.Rect;
const Theme = core.Theme;
const Tween = core.anim.Tween;
const Canvas = tw.Canvas;
const font = tw.font;

pub const top_bar_h = 28;
/// The panel on the left that holds minimized windows.
/// The panel has one width, with or without windows: thumbnails are
/// small, and hovering one shows it enlarged.
pub const panel_w = 76;
pub const panel_pad = 12;
/// The apps button at the bottom of the panel opens the launcher.
pub const apps_button = 60;

/// The apps icon: a 3 x 3 grid of dots, the same in the top bar and, much
/// larger, at the bottom of the panel. Hover tints the square behind it;
/// while the launcher is open the dots take the accent color.
pub fn drawAppsIcon(cv: *Canvas, th: *const Theme, r: Rect, hovered: bool, open: bool) void {
    const size: f32 = @floatFromInt(@min(r.w, r.h));
    if (hovered or open) cv.fillRoundRect(r, size * 0.22, th.get(.accent).fade(if (open) 0.24 else 0.16));
    const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
    const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
    const step = size * 0.24;
    const dot_r = size * 0.075;
    const col = th.get(if (hovered or open) .accent else .chrome_text);
    var i: f32 = -1;
    while (i <= 1) : (i += 1) {
        var j: f32 = -1;
        while (j <= 1) : (j += 1) cv.fillCircle(cx + j * step, cy + i * step, dot_r, col);
    }
}

// ------------------------------------------------------------- top bar

/// From the right corner: the date and time, then settings, control
/// center, device center, language; the learning indicator to their left.
pub const TopBarHit = enum { none, apps, gear, control_center, devices, language, learning };

/// The four menu icons at the right, from the corner inward.
pub const menu_icons = [_]TopBarHit{ .gear, .control_center, .devices, .language };

/// The Apps button at the left of the top bar opens the launcher.
pub const apps_w = 36;
/// One menu icon's button: side by side, no gap, so the row is one target.
const icon_w = 32;
/// The date and time in the right corner ("Fri Oct 30  13:35"), right
/// aligned in a fixed slot so the icons do not move as it changes.
pub const datetime_w = 124;
const learning_w = 74;

pub fn topBarHit(screen_w: i32, x: f32, y: f32) TopBarHit {
    if (y >= top_bar_h or y < 0) return .none;
    for ([_]TopBarHit{ .apps, .gear, .control_center, .devices, .language, .learning }) |which| {
        if (topBarRect(screen_w, which).contains(x, @min(y, top_bar_h - 3))) return which;
    }
    return .none;
}

/// Hover and press area of a top-bar button.
pub fn topBarRect(w: i32, which: TopBarHit) Rect {
    return switch (which) {
        .gear, .control_center, .devices, .language => {
            const i: i32 = @intCast(std.mem.indexOfScalar(TopBarHit, &menu_icons, which).?);
            return .{ .x = w - 8 - datetime_w - icon_w * (i + 1), .y = 2, .w = icon_w, .h = top_bar_h - 4 };
        },
        .learning => .{ .x = topBarRect(w, .language).x - 8 - learning_w, .y = 3, .w = learning_w, .h = top_bar_h - 6 },
        .apps => .{ .x = 4, .y = 2, .w = apps_w - 8, .h = top_bar_h - 4 },
        .none => .{},
    };
}

/// `clock` is the date and time; `layout` the current keyboard layout's
/// code ("EN").
pub fn drawTopBar(cv: *Canvas, th: *const Theme, w: i32, clock: []const u8, learning: bool, layout: []const u8, hint: []const u8, hover: TopBarHit, launcher_open: bool, menu_from: TopBarHit) void {
    const bar = Rect{ .x = 0, .y = 0, .w = w, .h = top_bar_h };
    const bg = th.get(.chrome_focused);
    cv.fillRect(bar, bg.fade(0.96));
    cv.hairlineHBottom(0, top_bar_h - 1, w, th.get(.hairline));
    const cy: f32 = top_bar_h / 2;
    const col = th.get(.chrome_text);

    // Every icon is a button: a tint on hover, a stronger one while the
    // menu it opened is showing.
    for (menu_icons ++ [_]TopBarHit{.learning}) |which| {
        const r = topBarRect(w, which);
        if (menu_from == which) {
            cv.fillRoundRect(r, 6, th.get(.accent).fade(0.24));
        } else if (hover == which) cv.fillRoundRect(r, 6, th.get(.accent).fade(0.14));
    }

    for (menu_icons) |which| {
        const r = topBarRect(w, which);
        const ix = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
        switch (which) {
            .gear => glyphs.gear(cv, ix, cy, col, bg),
            .control_center => glyphs.toggles(cv, ix, cy, col),
            .devices => glyphs.devices(cv, ix, cy, col, bg),
            .language => glyphs.layoutKey(cv, ix, cy, layout, col),
            else => unreachable,
        }
    }

    const small: font.Style = .{ .size = .body };
    const m = font.Metrics.of(small, cv.scale);
    // The date and time in the corner, as on macOS.
    _ = cv.text(@as(f32, @floatFromInt(w - 10)) - m.width(clock), @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), clock, small, col);

    // Learning indicator: a shape (filled dot vs ring) plus a word.
    const lx: f32 = @floatFromInt(topBarRect(w, .learning).x + 8);
    if (learning) {
        cv.fillCircle(lx, cy, 3.5, th.get(.accent));
    } else {
        cv.fillCircle(lx, cy, 3.5, th.get(.text_dim));
        cv.fillCircle(lx, cy, 2, bg);
    }
    _ = cv.text(lx + 8, @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), if (learning) "Learning" else "Paused", small, th.get(.text_dim));

    // Apps button: opens the launcher (same as Super).
    drawAppsIcon(cv, th, .{ .x = 4, .y = 2, .w = apps_w - 8, .h = top_bar_h - 4 }, hover == .apps, launcher_open);
    cv.fillRect(.{ .x = apps_w, .y = 6, .w = 1, .h = top_bar_h - 12 }, th.get(.hairline));

    _ = cv.text(apps_w + 10, @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), hint, .{ .size = .small }, th.get(.text_dim));
}

// ------------------------------------------------------------- launcher

pub const AppInfo = struct {
    name: []const u8,
    /// Open windows of this app (the launcher shows a dot under it).
    running: u8 = 0,
    /// Not shown: an installed app that left the registry.
    hidden: bool = false,
    /// Uninstalled: shown as a ghost (faded, dashed outline), not started.
    missing: bool = false,
    /// A newer version is available: an up-arrow badge on the icon.
    update: bool = false,
    /// Its icon, when krkdesk has drawn one.
    icon: chrome.Icon = .{},
};

/// An entry of Focus or Recent: an app (its launcher index) and why it is
/// offered (sdk/krkcore/src/influence.zig).
pub const Pick = struct {
    app: usize,
    reason: core.types.InfluenceReason = .opened,
    /// See InfluenceReason; 0 with `.opened` means "when is unknown".
    value: i64 = 0,
};

pub const Section = enum { focus, recent, all };

pub const Launcher = struct {
    open: bool = false,
    t: Tween = Tween.init(0),
    rect: Rect = .{},
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    hover: ?usize = null,
    pointer_moved: bool = false,
    /// Focus, then Recent (Top-Level Design, "Launcher"): frozen while
    /// visible, computed at opening. An app is in at most one of them, and
    /// All apps leaves out both (don't overload the user).
    focus: [4]Pick = undefined,
    focus_len: usize = 0,
    recent: [4]Pick = undefined,
    recent_len: usize = 0,
    /// Wall clock at opening (Unix seconds), for "5 min ago"; 0 unknown.
    wall_s: i64 = 0,
    /// Alphabetical order of apps, stable.
    order: [96]usize = undefined,
    order_len: usize = 0,

    const tile_w = 124;
    const tile_h = 116;
    /// Focus and Recent tiles have a reason line under the name.
    const pick_h = 126;
    /// Between Focus and Recent when they share a row.
    const band_gap = 48;
    /// App icons are at least 64 px, so badges fit on them.
    const icon_px = 64;
    const max_tiles = 4 + 4 + 96;

    pub fn show(self: *Launcher, screen: Rect, px: f32, py: f32, apps: []const AppInfo, focus: []const Pick, recent: []const Pick, wall_s: i64, now: i64) void {
        self.open = true;
        self.t.set(1, now, 180);
        self.filter_len = 0;
        self.hover = null;
        self.pointer_moved = false;
        // A large rectangle centered on the pointer, clamped to the screen.
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(screen.w)) * 0.66);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(screen.h)) * 0.7);
        self.rect = (Rect{ .x = @as(i32, @intFromFloat(px)) - @divTrunc(w, 2), .y = @as(i32, @intFromFloat(py)) - @divTrunc(h, 2), .w = w, .h = h }).clampInto(screen.inset(12));

        self.wall_s = wall_s;
        // Focus first; Recent only what Focus does not hold.
        self.focus_len = 0;
        for (focus) |p| {
            if (self.focus_len == self.focus.len) break;
            if (!offerable(apps, p.app) or self.picked(p.app)) continue;
            self.focus[self.focus_len] = p;
            self.focus_len += 1;
        }
        self.recent_len = 0;
        for (recent) |p| {
            if (self.recent_len == self.recent.len) break;
            if (!offerable(apps, p.app) or self.picked(p.app)) continue;
            self.recent[self.recent_len] = p;
            self.recent_len += 1;
        }
        self.order_len = 0;
        for (apps, 0..) |a, i| {
            if (a.hidden or self.picked(i)) continue;
            if (self.order_len == self.order.len) break;
            self.order[self.order_len] = i;
            self.order_len += 1;
        }
        std.mem.sort(usize, self.order[0..self.order_len], apps, struct {
            fn lt(a: []const AppInfo, x: usize, y: usize) bool {
                return std.ascii.lessThanIgnoreCase(a[x].name, a[y].name);
            }
        }.lt);
    }

    fn offerable(apps: []const AppInfo, a: usize) bool {
        return a < apps.len and !apps[a].hidden and !apps[a].missing;
    }

    /// Already in Focus or Recent.
    fn picked(self: *const Launcher, app: usize) bool {
        for (self.focus[0..self.focus_len]) |p| {
            if (p.app == app) return true;
        }
        for (self.recent[0..self.recent_len]) |p| {
            if (p.app == app) return true;
        }
        return false;
    }

    /// The reason line under a Focus or Recent tile.
    fn reasonText(self: *const Launcher, p: Pick, buf: []u8) []const u8 {
        return switch (p.reason) {
            .used => if (p.value < 60)
                std.fmt.bufPrint(buf, "{d} min this week", .{p.value}) catch ""
            else
                std.fmt.bufPrint(buf, "{d} h this week", .{@divTrunc(p.value, 60)}) catch "",
            .cycle => "usually now",
            .opened => blk: {
                if (p.value <= 0 or self.wall_s <= 0) break :blk "";
                const ago = @max(0, self.wall_s - p.value);
                if (ago < 60) break :blk "just now";
                if (ago < 3600) break :blk std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(ago, 60)}) catch "";
                if (ago < 86400) break :blk std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(ago, 3600)}) catch "";
                if (ago < 2 * 86400) break :blk "yesterday";
                break :blk std.fmt.bufPrint(buf, "{d} days ago", .{@divTrunc(ago, 86400)}) catch "";
            },
            _ => "",
        };
    }

    pub fn hide(self: *Launcher, now: i64) void {
        self.open = false;
        self.t.set(0, now, 150);
    }

    pub fn visible(self: *const Launcher, now: i64) bool {
        return self.open or self.t.value(now) > 0.01;
    }

    fn matches(self: *const Launcher, name: []const u8) bool {
        if (self.filter_len == 0) return true;
        return std.ascii.indexOfIgnoreCase(name, self.filter[0..self.filter_len]) != null;
    }

    const Tile = struct {
        app: usize,
        rect: Rect,
        ghost: bool,
        section: Section = .all,
        pick: Pick = .{ .app = 0 },

        fn w(self: Tile) i32 {
            return self.rect.w;
        }
    };

    /// Tiles for the current state: Focus, then Recent (side by side when
    /// they fit, else one under the other), then all the other apps.
    fn tiles(self: *const Launcher, apps: []const AppInfo, out: []Tile) usize {
        var n: usize = 0;
        const r = self.rect;
        const fw = @as(i32, @intCast(self.focus_len)) * tile_w;
        const rw = @as(i32, @intCast(self.recent_len)) * tile_w;
        const both = self.focus_len > 0 and self.recent_len > 0;
        const one_row = !both or fw + band_gap + rw <= r.w - 40;
        var y = r.y + 96;
        const gap: i32 = if (both) band_gap else 0;
        const first_w: i32 = if (one_row) fw + gap + rw else fw;
        var x = r.x + @divTrunc(r.w - first_w, 2);
        for (self.focus[0..self.focus_len]) |p| {
            out[n] = .{ .app = p.app, .rect = .{ .x = x, .y = y, .w = tile_w, .h = pick_h }, .ghost = !self.matches(apps[p.app].name), .section = .focus, .pick = p };
            n += 1;
            x += tile_w;
        }
        if (both) {
            if (one_row) {
                x += band_gap;
            } else {
                y += pick_h + 40;
                x = r.x + @divTrunc(r.w - rw, 2);
            }
        }
        for (self.recent[0..self.recent_len]) |p| {
            out[n] = .{ .app = p.app, .rect = .{ .x = x, .y = y, .w = tile_w, .h = pick_h }, .ghost = !self.matches(apps[p.app].name), .section = .recent, .pick = p };
            n += 1;
            x += tile_w;
        }
        const all_y: i32 = y + @as(i32, if (self.focus_len + self.recent_len > 0) pick_h + 48 else 0);
        const cols: i32 = @max(1, @divTrunc(r.w - 80, tile_w));
        const row_w = @min(cols, @as(i32, @intCast(self.order_len))) * tile_w;
        const x0 = r.x + @divTrunc(r.w - row_w, 2);
        for (self.order[0..self.order_len], 0..) |a, i| {
            const col: i32 = @intCast(@as(i32, @intCast(i)) - @divTrunc(@as(i32, @intCast(i)), cols) * cols);
            const rowi: i32 = @divTrunc(@as(i32, @intCast(i)), cols);
            out[n] = .{ .app = a, .rect = .{ .x = x0 + col * tile_w, .y = all_y + rowi * tile_h, .w = tile_w, .h = tile_h }, .ghost = !self.matches(apps[a].name) };
            n += 1;
        }
        return n;
    }

    /// `from` is the icon's rect, where the animation to the window starts.
    /// `new` asks for a new window even if the app is running (Shift).
    pub const Launch = struct { app: usize, from: Rect, new: bool = false };
    pub const Action = union(enum) { none, close, launch: Launch };

    fn iconRect(tile: Tile) Rect {
        return .{ .x = tile.rect.x + @divTrunc(tile.w() - icon_px, 2), .y = tile.rect.y + 10, .w = icon_px, .h = icon_px };
    }

    /// "New window" badge on a running app's tile: a "+" at the icon's
    /// top-right corner, shown while the tile is hovered.
    fn newBadge(tile: Tile) Rect {
        const ic = iconRect(tile);
        return .{ .x = ic.right() - 8, .y = ic.y - 10, .w = 22, .h = 22 };
    }

    pub fn pointerMotion(self: *Launcher, apps: []const AppInfo, x: f32, y: f32) void {
        // No accidental hover: highlights wait until the pointer moves.
        self.pointer_moved = true;
        var buf: [max_tiles]Tile = undefined;
        const n = self.tiles(apps, &buf);
        self.hover = null;
        for (buf[0..n]) |t| {
            if (!t.ghost and !apps[t.app].missing and t.rect.contains(x, y)) self.hover = t.app;
        }
    }

    pub fn press(self: *Launcher, apps: []const AppInfo, x: f32, y: f32, shift: bool) Action {
        if (!self.rect.contains(x, y)) return .close;
        var buf: [max_tiles]Tile = undefined;
        const n = self.tiles(apps, &buf);
        for (buf[0..n]) |t| {
            if (t.ghost) continue;
            if (apps[t.app].running > 0 and newBadge(t).contains(x, y)) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = true } };
        }
        for (buf[0..n]) |t| {
            // A ghost cannot be started.
            if (!t.ghost and !apps[t.app].missing and t.rect.contains(x, y)) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = shift } };
        }
        return .none;
    }

    pub fn key(self: *Launcher, apps: []const AppInfo, k: core.input.Key, shift: bool) Action {
        switch (k) {
            .escape => {
                if (self.filter_len > 0) {
                    self.filter_len = 0;
                    return .none;
                }
                return .close;
            },
            .backspace => {
                if (self.filter_len > 0) self.filter_len -= 1;
                return .none;
            },
            .enter => {
                var buf: [max_tiles]Tile = undefined;
                const n = self.tiles(apps, &buf);
                for (buf[0..n]) |t| {
                    if (!t.ghost and !apps[t.app].missing) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = shift } };
                }
                return .none;
            },
            else => return .none,
        }
    }

    pub fn text(self: *Launcher, s: []const u8) void {
        const n = @min(s.len, self.filter.len - self.filter_len);
        @memcpy(self.filter[self.filter_len..][0..n], s[0..n]);
        self.filter_len += n;
    }

    pub fn draw(self: *Launcher, cv: *Canvas, th: *const Theme, apps: []const AppInfo, now: i64) void {
        const t = self.t.value(now);
        if (t <= 0.01) return;
        const r = self.rect;
        // Tint with soft edges fading into the desktop (reduce-transparency
        // style; a blurred snapshot comes with the GPU renderer).
        var e: i32 = 12;
        while (e > 0) : (e -= 2) {
            cv.fillRoundRect(r.inset(-e), 18 + @as(f32, @floatFromInt(e)), th.get(.overlay_tint).fade(t * 0.08));
        }
        cv.fillRoundRect(r, 18, th.get(.overlay_tint).fade(t));
        cv.strokeRoundRect(r, 18, 0, th.get(.border).fade(t * 0.6));

        const head: font.Style = .{ .size = .small, .weight = .semibold };
        // Filter box fades in at the top center on the first keystroke.
        if (self.filter_len > 0) {
            const box = Rect{ .x = r.x + @divTrunc(r.w - 320, 2), .y = r.y + 24, .w = 320, .h = 34 };
            cv.fillRoundRect(box, 8, th.get(.surface).fade(t));
            cv.strokeRoundRect(box, 8, 0, th.get(.accent).fade(t));
            const s = self.filter[0..self.filter_len];
            const end = cv.text(@floatFromInt(box.x + 12), @floatFromInt(box.y + 8), s, .{ .size = .large }, th.get(.text).fade(t));
            cv.fillRect(.{ .x = box.x + 13 + @as(i32, @intFromFloat(end)), .y = box.y + 8, .w = 1, .h = 18 }, th.get(.text).fade(t));
        } else {
            _ = cv.text(@floatFromInt(r.x + @divTrunc(r.w, 2) - 70), @floatFromInt(r.y + 32), "Type to filter", .{ .size = .body }, th.get(.text_dim).fade(t * 0.7));
        }

        var buf: [max_tiles]Tile = undefined;
        const n = self.tiles(apps, &buf);
        // Each section's heading over its first tile.
        for (buf[0..n], 0..) |tile, i| {
            if (i > 0 and buf[i - 1].section == tile.section) continue;
            const label = switch (tile.section) {
                .focus => "FOCUS",
                .recent => "RECENT",
                .all => if (self.focus_len + self.recent_len > 0) "ALL OTHER APPS" else "ALL APPS",
            };
            _ = cv.text(@floatFromInt(tile.rect.x + 8), @floatFromInt(tile.rect.y - 22), label, head, th.get(.text_dim).fade(t));
        }
        var all_ghost = true;
        for (buf[0..n]) |tile| {
            if (!tile.ghost) all_ghost = false;
        }
        for (buf[0..n]) |tile| {
            const info = apps[tile.app];
            const a: f32 = if (tile.ghost) 0.18 else if (info.missing) 0.45 else 1.0;
            const hovered = self.pointer_moved and self.hover == tile.app and !tile.ghost;
            if (hovered) cv.fillRoundRect(tile.rect.inset(6), 10, th.get(.accent).fade(0.12 * t));
            const icon = iconRect(tile);
            if (tile.ghost) {
                cv.fillRoundRect(icon, 15, th.get(.text_dim).fade(0.15 * t));
            } else if (info.missing) {
                // Uninstalled: a faded tile in a dashed outline.
                cv.fillRoundRect(icon, 15, th.get(.text_dim).fade(0.25 * t));
                cv.dashedRect(icon.inset(-4), 1, 5, 4, th.get(.text_dim).fade(t));
            } else {
                chrome.drawAppIcon(cv, th, icon, info.name, .title, info.icon);
            }
            const m = font.Metrics.of(.{}, cv.scale);
            const nw = @min(m.width(info.name), @as(f32, tile_w - 12));
            _ = cv.textEllipsis(@as(f32, @floatFromInt(tile.rect.x)) + (@as(f32, tile_w) - nw) / 2, @floatFromInt(tile.rect.y + 80), info.name, tile_w - 12, .{}, th.get(.text).fade(t * a));
            if (tile.section != .all) {
                var rbuf: [32]u8 = undefined;
                const note = self.reasonText(tile.pick, &rbuf);
                const sm = font.Metrics.of(.{ .size = .small }, cv.scale);
                const rw = @min(sm.width(note), @as(f32, tile_w - 8));
                _ = cv.textEllipsis(@as(f32, @floatFromInt(tile.rect.x)) + (@as(f32, tile_w) - rw) / 2, @floatFromInt(tile.rect.y + 97), note, tile_w - 8, .{ .size = .small }, th.get(.text_dim).fade(t * a));
            }
            if (info.missing and !tile.ghost) {
                const note = "not installed";
                const sm = font.Metrics.of(.{ .size = .small }, cv.scale);
                _ = cv.text(@as(f32, @floatFromInt(tile.rect.x)) + (@as(f32, tile_w) - sm.width(note)) / 2, @floatFromInt(tile.rect.y + 97), note, .{ .size = .small }, th.get(.text_dim).fade(t));
            }
            // A newer version: an up arrow in a circle at the top right.
            if (info.update and !tile.ghost and !(hovered and info.running > 0)) {
                const b = newBadge(tile);
                const bx: f32 = @as(f32, @floatFromInt(b.x)) + 11;
                const by: f32 = @as(f32, @floatFromInt(b.y)) + 11;
                cv.fillCircle(bx, by, 12, th.get(.surface).fade(t));
                cv.fillCircle(bx, by, 11, th.get(.accent).fade(t));
                const fg = th.get(.accent_text).fade(t);
                cv.line(bx, by + 5, bx, by - 5, 2, fg);
                cv.line(bx - 4.5, by - 0.5, bx, by - 5, 2, fg);
                cv.line(bx + 4.5, by - 0.5, bx, by - 5, 2, fg);
            }
            // Running and hovered: the "+" badge opens a new window.
            if (hovered and apps[tile.app].running > 0) {
                const b = newBadge(tile);
                const bx: f32 = @as(f32, @floatFromInt(b.x)) + 11;
                const by: f32 = @as(f32, @floatFromInt(b.y)) + 11;
                cv.fillCircle(bx, by, 11, th.get(.accent).fade(t));
                cv.line(bx - 5, by, bx + 5, by, 2, th.get(.accent_text).fade(t));
                cv.line(bx, by - 5, bx, by + 5, 2, th.get(.accent_text).fade(t));
            }
            // Running: a dot under the name; two dots for two or more windows.
            const running = apps[tile.app].running;
            if (running > 0) {
                const cx: f32 = @as(f32, @floatFromInt(tile.rect.x)) + tile_w / 2.0;
                const dy: f32 = @floatFromInt(tile.rect.y + @as(i32, if (tile.section == .all) 106 else 118));
                const col = th.get(.accent).fade(t * a);
                if (running == 1) {
                    cv.fillCircle(cx, dy, 3, col);
                } else {
                    cv.fillCircle(cx - 5, dy, 3, col);
                    cv.fillCircle(cx + 5, dy, 3, col);
                }
            }
        }
        if (all_ghost and n > 0) {
            _ = cv.text(@floatFromInt(r.x + @divTrunc(r.w, 2) - 30), @floatFromInt(r.bottom() - 60), "No match", .{ .size = .large }, th.get(.text_dim).fade(t));
        }
    }
};
