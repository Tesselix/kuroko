//! Built-in shell UI drawn by the compositor: top bar, launcher, shelf
//! (Top-Level Design: "Top bar and control center", "Launcher").

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const chrome = @import("chrome.zig");

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

pub const TopBarHit = enum { none, apps, gear, control_center, learning };

/// The Apps button at the left of the top bar opens the launcher.
pub const apps_w = 36;

pub fn topBarHit(screen_w: i32, x: f32, y: f32) TopBarHit {
    if (y >= top_bar_h or y < 0) return .none;
    for ([_]TopBarHit{ .apps, .gear, .control_center, .learning }) |which| {
        if (topBarRect(screen_w, which).contains(x, @min(y, top_bar_h - 3))) return which;
    }
    return .none;
}

/// Hover and press area of a top-bar button.
pub fn topBarRect(w: i32, which: TopBarHit) Rect {
    return switch (which) {
        .gear => .{ .x = w - 34, .y = 2, .w = 32, .h = top_bar_h - 4 },
        .control_center => .{ .x = w - 66, .y = 2, .w = 32, .h = top_bar_h - 4 },
        .learning => .{ .x = w - 192, .y = 3, .w = 74, .h = top_bar_h - 6 },
        .apps => .{ .x = 4, .y = 2, .w = apps_w - 8, .h = top_bar_h - 4 },
        .none => .{},
    };
}

pub fn drawTopBar(cv: *Canvas, th: *const Theme, w: i32, clock: []const u8, learning: bool, hint: []const u8, hover: TopBarHit, launcher_open: bool, panel_from: TopBarHit) void {
    const bar = Rect{ .x = 0, .y = 0, .w = w, .h = top_bar_h };
    cv.fillRect(bar, th.get(.chrome_focused).fade(0.96));
    cv.hairlineHBottom(0, top_bar_h - 1, w, th.get(.hairline));
    const cy: f32 = top_bar_h / 2;
    const col = th.get(.chrome_text);

    // Every icon is a button: a tint on hover, a stronger one while the
    // panel it opened is showing.
    for ([_]TopBarHit{ .gear, .control_center, .learning }) |which| {
        const r = topBarRect(w, which);
        if (panel_from == which) {
            cv.fillRoundRect(r, 6, th.get(.accent).fade(0.24));
        } else if (hover == which) cv.fillRoundRect(r, 6, th.get(.accent).fade(0.14));
    }

    // From the right corner: gear, then control center, then indicators.
    const gx: f32 = @floatFromInt(w - 17);
    var i: f32 = 0;
    while (i < 8) : (i += 1) {
        const a = i / 8 * std.math.tau;
        cv.line(gx + 5 * @cos(a), cy + 5 * @sin(a), gx + 7.2 * @cos(a), cy + 7.2 * @sin(a), 2.2, col);
    }
    cv.fillCircle(gx, cy, 5.2, col);
    cv.fillCircle(gx, cy, 2.4, th.get(.chrome_focused));

    const cx: f32 = @floatFromInt(w - 50);
    cv.line(cx - 7, cy - 3.5, cx + 7, cy - 3.5, 1.5, col);
    cv.line(cx - 7, cy + 3.5, cx + 7, cy + 3.5, 1.5, col);
    cv.fillCircle(cx + 3, cy - 3.5, 2.6, col);
    cv.fillCircle(cx - 3, cy + 3.5, 2.6, col);

    const small: font.Style = .{ .size = .body };
    const m = font.Metrics.of(small, cv.scale);
    const clock_w = m.width(clock);
    const clock_x = cx - 22 - clock_w;
    _ = cv.text(clock_x, @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), clock, small, col);

    // Learning indicator: a shape (filled dot vs ring) plus a word.
    const lx = clock_x - 84;
    if (learning) {
        cv.fillCircle(lx, cy, 3.5, th.get(.accent));
    } else {
        cv.fillCircle(lx, cy, 3.5, th.get(.text_dim));
        cv.fillCircle(lx, cy, 2, th.get(.chrome_focused));
    }
    _ = cv.text(lx + 8, @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), if (learning) "Learning" else "Paused", small, th.get(.text_dim));

    // Apps button: opens the launcher (same as Super).
    drawAppsIcon(cv, th, .{ .x = 4, .y = 2, .w = apps_w - 8, .h = top_bar_h - 4 }, hover == .apps, launcher_open);
    cv.fillRect(.{ .x = apps_w, .y = 6, .w = 1, .h = top_bar_h - 12 }, th.get(.hairline));

    _ = cv.text(apps_w + 10, @floatFromInt(@divTrunc(top_bar_h - m.lineHeight(), 2)), hint, .{ .size = .small }, th.get(.text_dim));
}

// ------------------------------------------------------- control center

/// The small panel the gear and the control-center icon open, under the
/// top bar at the right. Each row is a switch; a click flips it.
pub const ControlCenter = struct {
    from: TopBarHit = .none,

    pub const Row = enum { dark, learning, wheel_natural, touchpad_natural };
    pub const rows = [_]Row{ .dark, .learning, .wheel_natural, .touchpad_natural };
    const row_h = 40;
    const width = 300;

    pub fn isOpen(self: ControlCenter) bool {
        return self.from != .none;
    }

    pub fn rect(_: ControlCenter, screen_w: i32) Rect {
        return .{ .x = screen_w - width - 8, .y = top_bar_h + 6, .w = width, .h = 44 + rows.len * row_h + 10 };
    }

    fn rowRect(self: ControlCenter, screen_w: i32, i: usize) Rect {
        const r = self.rect(screen_w);
        return .{ .x = r.x + 8, .y = r.y + 44 + @as(i32, @intCast(i)) * row_h, .w = r.w - 16, .h = row_h };
    }

    pub fn rowAt(self: ControlCenter, screen_w: i32, x: f32, y: f32) ?Row {
        for (rows, 0..) |row, i| {
            if (self.rowRect(screen_w, i).contains(x, y)) return row;
        }
        return null;
    }

    pub fn draw(self: ControlCenter, cv: *Canvas, th: *const Theme, screen_w: i32, values: [rows.len]bool, px: f32, py: f32) void {
        if (!self.isOpen()) return;
        const r = self.rect(screen_w);
        cv.fillRoundRect(r.translate(0, 4), 12, th.get(.shadow));
        cv.fillRoundRect(r, 12, th.get(.surface));
        cv.strokeRoundRect(r, 12, 1, th.get(.border));
        const title = if (self.from == .gear) "Settings" else "Control Center";
        _ = cv.text(@floatFromInt(r.x + 18), @floatFromInt(r.y + 14), title, .{ .size = .body, .weight = .semibold }, th.get(.text));
        const labels = [_][]const u8{ "Dark mode", "Learning", "Natural scrolling: mouse wheel", "Natural scrolling: touchpad" };
        const m = font.Metrics.of(.{}, cv.scale);
        for (rows, 0..) |_, i| {
            const rr = self.rowRect(screen_w, i);
            if (rr.contains(px, py)) cv.fillRoundRect(rr, 8, th.get(.accent).fade(0.10));
            _ = cv.text(@floatFromInt(rr.x + 10), @floatFromInt(rr.y + @divTrunc(rr.h - m.lineHeight(), 2)), labels[i], .{}, th.get(.text));
            // Switch: a pill with a knob; on = accent and knob on the right
            // (position, not only color).
            const on = values[i];
            const sw = Rect{ .x = rr.right() - 48, .y = rr.y + @divTrunc(rr.h - 20, 2), .w = 38, .h = 20 };
            cv.fillRoundRect(sw, 10, th.get(if (on) .accent else .surface_sunken));
            cv.strokeRoundRect(sw, 10, 1, th.get(if (on) .accent else .border));
            const kx: f32 = @floatFromInt(if (on) sw.right() - 10 else sw.x + 10);
            cv.fillCircle(kx, @as(f32, @floatFromInt(sw.y)) + 10, 7, .rgb(0xFFFFFF));
        }
    }
};

// ------------------------------------------------------------- launcher

pub const AppInfo = struct {
    name: []const u8,
    /// Open windows of this app (the launcher shows a dot under it).
    running: u8 = 0,
};

pub const Launcher = struct {
    open: bool = false,
    t: Tween = Tween.init(0),
    rect: Rect = .{},
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    hover: ?usize = null,
    pointer_moved: bool = false,
    /// Frozen while visible (Top-Level Design: computed at opening).
    predicted: [4]usize = undefined,
    predicted_len: usize = 0,
    /// Alphabetical order of apps, stable.
    order: [32]usize = undefined,
    order_len: usize = 0,

    const tile_w = 124;
    const tile_h = 100;

    pub fn show(self: *Launcher, screen: Rect, px: f32, py: f32, apps: []const AppInfo, recent: []const usize, now: i64) void {
        self.open = true;
        self.t.set(1, now, 180);
        self.filter_len = 0;
        self.hover = null;
        self.pointer_moved = false;
        // A large rectangle centered on the pointer, clamped to the screen.
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(screen.w)) * 0.66);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(screen.h)) * 0.7);
        self.rect = (Rect{ .x = @as(i32, @intFromFloat(px)) - @divTrunc(w, 2), .y = @as(i32, @intFromFloat(py)) - @divTrunc(h, 2), .w = w, .h = h }).clampInto(screen.inset(12));

        self.predicted_len = 0;
        for (recent) |a| {
            if (self.predicted_len == self.predicted.len) break;
            self.predicted[self.predicted_len] = a;
            self.predicted_len += 1;
        }
        self.order_len = @min(apps.len, self.order.len);
        for (0..self.order_len) |i| self.order[i] = i;
        std.mem.sort(usize, self.order[0..self.order_len], apps, struct {
            fn lt(a: []const AppInfo, x: usize, y: usize) bool {
                return std.ascii.lessThanIgnoreCase(a[x].name, a[y].name);
            }
        }.lt);
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

        fn w(self: Tile) i32 {
            return self.rect.w;
        }
    };

    /// Tiles for the current state: predicted section first, then all apps.
    fn tiles(self: *const Launcher, apps: []const AppInfo, out: []Tile) usize {
        var n: usize = 0;
        const r = self.rect;
        const pred_y = r.y + 96;
        const pred_w = @as(i32, @intCast(self.predicted_len)) * tile_w;
        var x = r.x + @divTrunc(r.w - pred_w, 2);
        for (self.predicted[0..self.predicted_len]) |a| {
            out[n] = .{ .app = a, .rect = .{ .x = x, .y = pred_y, .w = tile_w, .h = tile_h }, .ghost = !self.matches(apps[a].name) };
            n += 1;
            x += tile_w;
        }
        const all_y: i32 = pred_y + @as(i32, if (self.predicted_len > 0) tile_h + 56 else 0);
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
        return .{ .x = tile.rect.x + @divTrunc(tile.w() - 48, 2), .y = tile.rect.y + 10, .w = 48, .h = 48 };
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
        var buf: [40]Tile = undefined;
        const n = self.tiles(apps, &buf);
        self.hover = null;
        for (buf[0..n]) |t| {
            if (!t.ghost and t.rect.contains(x, y)) self.hover = t.app;
        }
    }

    pub fn press(self: *Launcher, apps: []const AppInfo, x: f32, y: f32, shift: bool) Action {
        if (!self.rect.contains(x, y)) return .close;
        var buf: [40]Tile = undefined;
        const n = self.tiles(apps, &buf);
        for (buf[0..n]) |t| {
            if (t.ghost) continue;
            if (apps[t.app].running > 0 and newBadge(t).contains(x, y)) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = true } };
        }
        for (buf[0..n]) |t| {
            if (!t.ghost and t.rect.contains(x, y)) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = shift } };
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
                var buf: [40]Tile = undefined;
                const n = self.tiles(apps, &buf);
                for (buf[0..n]) |t| {
                    if (!t.ghost) return .{ .launch = .{ .app = t.app, .from = iconRect(t), .new = shift } };
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

        var buf: [40]Tile = undefined;
        const n = self.tiles(apps, &buf);
        if (self.predicted_len > 0) {
            _ = cv.text(@floatFromInt(buf[0].rect.x + 8), @floatFromInt(buf[0].rect.y - 22), "MOST PROBABLE", head, th.get(.text_dim).fade(t));
        }
        const all_first = self.predicted_len;
        if (all_first < n) {
            _ = cv.text(@floatFromInt(buf[all_first].rect.x + 8), @floatFromInt(buf[all_first].rect.y - 22), "ALL APPS", head, th.get(.text_dim).fade(t));
        }
        var all_ghost = true;
        for (buf[0..n]) |tile| {
            if (!tile.ghost) all_ghost = false;
        }
        for (buf[0..n]) |tile| {
            const a: f32 = if (tile.ghost) 0.18 else 1.0;
            const hovered = self.pointer_moved and self.hover == tile.app and !tile.ghost;
            if (hovered) cv.fillRoundRect(tile.rect.inset(6), 10, th.get(.accent).fade(0.12 * t));
            const icon = iconRect(tile);
            if (a > 0.5) chrome.drawAppIcon(cv, th, icon, apps[tile.app].name, .title) else cv.fillRoundRect(icon, 11, th.get(.text_dim).fade(0.15 * t));
            const m = font.Metrics.of(.{}, cv.scale);
            const nw = @min(m.width(apps[tile.app].name), @as(f32, tile_w - 12));
            _ = cv.textEllipsis(@as(f32, @floatFromInt(tile.rect.x)) + (@as(f32, tile_w) - nw) / 2, @floatFromInt(tile.rect.y + 66), apps[tile.app].name, tile_w - 12, .{}, th.get(.text).fade(t * a));
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
                const dy: f32 = @floatFromInt(tile.rect.y + 92);
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
