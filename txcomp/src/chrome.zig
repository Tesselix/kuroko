//! Window chrome drawn by the compositor for every app (Top-Level Design,
//! "Window chrome"): icon, window buttons that expand from the aimed
//! button, the app menu in the title bar, centered title, and the bottom
//! border as status line.

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");

const Rect = core.Rect;
const Theme = core.Theme;
const Canvas = tw.Canvas;
const font = tw.font;

pub const title_h = 30;
pub const status_h = 3;

/// Window actions, left to right (Top-Level Design, "Close, minimize,
/// maximize, full screen").
pub const Button = enum(u8) { close, shelve, maximize, fullscreen };
pub const button_count = 4;

/// Where a point on the title bar lands.
pub const Hit = union(enum) {
    none,
    icon,
    button: Button,
    menu: usize,
    title,
};

pub const State = struct {
    /// 0 = buttons at rest, 1 = expanded.
    buttons_t: f32,
    aimed: u8,
    /// 0 = menu at rest, 1 = expanded over the title.
    menu_t: f32,
    focused: bool,
    failed: bool,
    elevated: bool = false,
    /// The maximize button shows "restore" while the window is maximized.
    maximized: bool = false,
    /// The full-screen button shows "exit full screen" in full screen.
    fullscreen: bool = false,
};

const icon_x = 8;
const icon_size = 18;
const buttons_x = 34;
const rest_r: f32 = 4;
const rest_gap: f32 = 14;
/// Expanded, a button fills the title bar's height, 1 px short at the top
/// and bottom.
const open_r: f32 = (title_h - 2) / 2.0;
const open_gap: f32 = 2 * open_r + 2;

/// Button centers for an expansion amount. The group grows to the right
/// and down from the left edge of the first button, so nothing moves over
/// the app icon or above the title bar. `aimed` is kept for the caller's
/// highlight only.
pub fn buttonCenters(frame: Rect, t: f32, aimed: u8) [button_count]f32 {
    _ = aimed;
    const left: f32 = @floatFromInt(frame.x + buttons_x);
    const r = buttonRadius(t);
    const gap = rest_gap + (open_gap - rest_gap) * t;
    var out: [button_count]f32 = undefined;
    for (&out, 0..) |*c, i| c.* = left + r + gap * @as(f32, @floatFromInt(i));
    return out;
}

/// Vertical center of the buttons: the middle of the title bar. Expanded,
/// they reach 1 px from its top and bottom; they grow only to the right.
pub fn buttonCenterY(frame: Rect, t: f32) f32 {
    _ = t;
    return @as(f32, @floatFromInt(frame.y)) + title_h / 2.0;
}

pub fn buttonRadius(t: f32) f32 {
    return rest_r + (open_r - rest_r) * t;
}

/// The zone where the pointer makes the buttons expand.
pub fn buttonZone(frame: Rect) Rect {
    return .{ .x = frame.x + buttons_x - 4, .y = frame.y, .w = @as(i32, @intFromFloat(button_count * open_gap)) + 8, .h = title_h };
}

/// Nearest button to x (the aimed one).
pub fn aimedAt(frame: Rect, x: f32) u8 {
    const c = buttonCenters(frame, 0, 0);
    var best: u8 = 0;
    var bd: f32 = std.math.inf(f32);
    for (c, 0..) |cx, i| {
        const d = @abs(cx - x);
        if (d < bd) {
            bd = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn menuStart(t: f32) i32 {
    // Menu starts after the buttons; it shifts right while they expand.
    return buttons_x + @as(i32, @intFromFloat(button_count * rest_gap + 10 + t * (open_gap - rest_gap) * button_count));
}

const menu_rest: font.Style = .{ .size = .body };
const menu_open: font.Style = .{ .size = .large };
const menu_gap = 14;

/// Hit-tests the title bar of a window frame.
pub fn hit(frame: Rect, st: State, menu: []const []const u8, scale: i32, x: f32, y: f32) Hit {
    const bar = Rect{ .x = frame.x, .y = frame.y, .w = frame.w, .h = title_h };
    if (!bar.contains(x, y)) return .none;
    if (x < @as(f32, @floatFromInt(frame.x + icon_x + icon_size + 4))) return .icon;
    const centers = buttonCenters(frame, st.buttons_t, st.aimed);
    const r = buttonRadius(st.buttons_t) + 2;
    for (centers, 0..) |cx, i| {
        if (@abs(x - cx) <= r and @abs(y - buttonCenterY(frame, st.buttons_t)) <= r + 4)
            return .{ .button = @enumFromInt(i) };
    }
    const style = if (st.menu_t > 0.5) menu_open else menu_rest;
    const m = font.Metrics.of(style, scale);
    var mx: f32 = @floatFromInt(frame.x + menuStart(st.buttons_t));
    const limit = menuLimit(frame, st.menu_t);
    for (menu, 0..) |item, i| {
        const w = m.width(item);
        if (mx + w > limit) break;
        if (x >= mx - menu_gap / 2 and x < mx + w + menu_gap / 2) return .{ .menu = i };
        mx += w + menu_gap;
    }
    return .title;
}

/// At rest, the menu stops at the drag zone (the middle third).
fn menuLimit(frame: Rect, menu_t: f32) f32 {
    // At rest the menu stops at the middle third (the drag zone). Expanded,
    // it stops before the title, which moves to the right and stays
    // visible (room for a title up to a third of the width).
    const third: f32 = @as(f32, @floatFromInt(frame.x)) + @as(f32, @floatFromInt(frame.w)) / 3;
    const full: f32 = @as(f32, @floatFromInt(frame.right() - 24)) - @as(f32, @floatFromInt(frame.w)) / 3;
    return third + @max(0, full - third) * menu_t;
}

pub fn drawTitleBar(cv: *Canvas, th: *const Theme, frame: Rect, st: State, title: []const u8, app_name: []const u8, icon: Icon, menu: []const []const u8) void {
    const bar = Rect{ .x = frame.x, .y = frame.y, .w = frame.w, .h = title_h };
    cv.fillRect(bar, th.get(if (st.focused) .chrome_focused else .chrome));
    if (st.elevated) cv.fillRect(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 3 }, th.get(.danger));
    // Focus has a shape cue: a 2 px line under the bar, not only a tint.
    if (st.focused) {
        cv.fillRect(.{ .x = bar.x, .y = bar.bottom() - 2, .w = bar.w, .h = 2 }, th.get(.accent));
    } else {
        cv.hairlineHBottom(bar.x, bar.bottom() - 1, bar.w, th.get(.hairline));
    }

    const old = cv.pushClip(bar);
    defer cv.popClip(old);

    drawAppIcon(cv, th, .{ .x = frame.x + icon_x, .y = frame.y + (title_h - icon_size) / 2, .w = icon_size, .h = icon_size }, app_name, .small, icon);

    // Title, centered; hidden while the menu takes over the bar.
    const title_style: font.Style = .{ .size = .body, .weight = if (st.focused) .semibold else .regular };
    const tm = font.Metrics.of(title_style, cv.scale);
    const max_w: f32 = @as(f32, @floatFromInt(frame.w)) / 3;
    const tw_ = @min(tm.width(title), max_w);
    // The title is always shown. While the menu is expanded it moves to the
    // right end of the bar to make room.
    {
        const centered: f32 = @as(f32, @floatFromInt(frame.x)) + (@as(f32, @floatFromInt(frame.w)) - tw_) / 2;
        const right: f32 = @as(f32, @floatFromInt(frame.right() - 12)) - tw_;
        const tx = centered + (@max(centered, right) - centered) * st.menu_t;
        _ = cv.textEllipsis(tx, @floatFromInt(frame.y + @divTrunc(title_h - tm.lineHeight(), 2)), title, max_w, title_style, th.get(if (st.focused) .chrome_text else .text_dim));
    }

    // Menu.
    const style = if (st.menu_t > 0.5) menu_open else menu_rest;
    const m = font.Metrics.of(style, cv.scale);
    var mx: f32 = @floatFromInt(frame.x + menuStart(st.buttons_t));
    const limit = menuLimit(frame, st.menu_t);
    const my: f32 = @floatFromInt(frame.y + @divTrunc(title_h - m.lineHeight(), 2));
    const mcol = th.get(if (st.menu_t > 0.5) .chrome_text else .text_dim);
    for (menu, 0..) |item, i| {
        const w = m.width(item);
        if (mx + w > limit) {
            // Too narrow: as many items as fit, then "»".
            if (i < menu.len) _ = cv.text(mx, my, "\u{00BB}", style, mcol);
            break;
        }
        _ = cv.text(mx, my, item, style, mcol);
        mx += w + menu_gap;
    }

    // Window buttons, drawn last so the expanded group is on top.
    const centers = buttonCenters(frame, st.buttons_t, st.aimed);
    const r = buttonRadius(st.buttons_t);
    const cy = buttonCenterY(frame, st.buttons_t);
    for (centers, 0..) |cx, i| {
        if (st.buttons_t < 0.05) {
            cv.fillCircle(cx, cy, r, th.get(.text_dim).fade(0.45));
            continue;
        }
        const aimed = i == st.aimed;
        cv.fillCircle(cx, cy, r, th.get(if (aimed) .surface else .surface_alt));
        cv.fillCircle(cx, cy, r, th.get(.border).fade(0.0));
        ringCircle(cv, cx, cy, r, th.get(.border));
        const g = th.get(.text).fade(st.buttons_t);
        const glyph: Glyph = switch (@as(Button, @enumFromInt(i))) {
            .close => .close,
            .shelve => .minimize,
            .maximize => if (st.maximized) .restore_max else .maximize,
            .fullscreen => if (st.fullscreen) .exit_fullscreen else .fullscreen,
        };
        drawGlyph(cv, glyph, cx, cy, r, g);
    }

    // Error: an icon in the title bar as well as the red dashed border.
    if (st.failed) {
        const ex: f32 = @floatFromInt(frame.right() - 18);
        const ey: f32 = @as(f32, @floatFromInt(frame.y)) + title_h / 2.0;
        cv.fillCircle(ex, ey, 7, th.get(.danger));
        cv.line(ex, ey - 3.5, ex, ey + 1, 1.8, .rgb(0xFFFFFF));
        cv.fillCircle(ex, ey + 3.6, 1.1, .rgb(0xFFFFFF));
    }
}

/// Button glyphs, shared by the title bar and the panel preview.
pub const Glyph = enum { close, minimize, maximize, restore_max, fullscreen, exit_fullscreen, to_desktop };

/// Draws a glyph centered at (cx, cy) for a round button of radius r.
pub fn drawGlyph(cv: *Canvas, glyph: Glyph, cx: f32, cy: f32, r: f32, g: core.Color) void {
    const s = r * 0.42;
    const lw: f32 = 1.2 + r * 0.05;
    switch (glyph) {
        .close => {
            cv.line(cx - s, cy - s, cx + s, cy + s, lw, g);
            cv.line(cx - s, cy + s, cx + s, cy - s, lw, g);
        },
        .minimize => cv.line(cx - s, cy, cx + s, cy, lw, g),
        // Restore: two overlapping squares.
        .restore_max => {
            squareOutline(cv, cx - s * 0.3, cy + s * 0.3, s * 0.6, g);
            squareOutline(cv, cx + s * 0.3, cy - s * 0.3, s * 0.6, g);
        },
        .maximize => squareOutline(cv, cx, cy, s * 0.85, g),
        // Two diagonal arrows: outward to enter, inward to exit.
        .fullscreen => {
            const a = s * 0.95;
            const k = s * 0.55;
            corner(cv, cx + a, cy - a, -k, k, g);
            corner(cv, cx - a, cy + a, k, -k, g);
            cv.line(cx + a, cy - a, cx + a * 0.2, cy - a * 0.2, lw, g);
            cv.line(cx - a, cy + a, cx - a * 0.2, cy + a * 0.2, lw, g);
        },
        .exit_fullscreen => {
            const a = s * 0.95;
            const k = s * 0.55;
            const b = a * 0.25;
            corner(cv, cx + b, cy - b, k, -k, g);
            corner(cv, cx - b, cy + b, -k, k, g);
            cv.line(cx + b, cy - b, cx + a, cy - a, lw, g);
            cv.line(cx - b, cy + b, cx - a, cy + a, lw, g);
        },
        // Back to the window area: an arrow out of the panel, to the right.
        .to_desktop => {
            cv.line(cx - s, cy, cx + s, cy, lw, g);
            cv.line(cx + s, cy, cx + s * 0.35, cy - s * 0.6, lw, g);
            cv.line(cx + s, cy, cx + s * 0.35, cy + s * 0.6, lw, g);
            cv.line(cx - s, cy - s * 0.8, cx - s, cy + s * 0.8, lw, g);
        },
    }
}

fn squareOutline(cv: *Canvas, cx: f32, cy: f32, half: f32, c: core.Color) void {
    cv.line(cx - half, cy - half, cx + half, cy - half, 1.4, c);
    cv.line(cx + half, cy - half, cx + half, cy + half, 1.4, c);
    cv.line(cx + half, cy + half, cx - half, cy + half, 1.4, c);
    cv.line(cx - half, cy + half, cx - half, cy - half, 1.4, c);
}

/// An arrow head at (x, y): one stroke along x by dx, one along y by dy.
fn corner(cv: *Canvas, x: f32, y: f32, dx: f32, dy: f32, c: core.Color) void {
    cv.line(x, y, x + dx, y, 1.5, c);
    cv.line(x, y, x, y + dy, 1.5, c);
}

fn ringCircle(cv: *Canvas, cx: f32, cy: f32, r: f32, c: core.Color) void {
    var a: f32 = 0;
    const steps: f32 = 28;
    while (a < steps) : (a += 1) {
        const t0 = a / steps * std.math.tau;
        const t1 = (a + 1) / steps * std.math.tau;
        cv.line(cx + r * @cos(t0), cy + r * @sin(t0), cx + r * @cos(t1), cy + r * @sin(t1), 1, c);
    }
}

/// App icon placeholder: a rounded square with the first letter.
/// An app's icon as pixels (from txdesk's icons.krkde), at two sizes.
pub const Icon = struct {
    small: ?tw.Image = null,
    large: ?tw.Image = null,
};

/// The app's icon; without one, a tile with its first letter.
pub fn drawAppIcon(cv: *Canvas, th: *const Theme, r: Rect, name: []const u8, size: font.Size, icon: Icon) void {
    // The smaller image that still covers the rect's physical pixels.
    const want = r.w * cv.scale;
    const img = if (icon.small) |s| (if (s.w >= want or icon.large == null) s else icon.large.?) else icon.large;
    if (img) |i| return cv.drawImage(i, r, 255);
    var h: u32 = 2166136261;
    for (name) |ch| h = (h ^ ch) *% 16777619;
    const tints = [_]u24{ 0x2F6BD0, 0x2E8B7A, 0x5B5FC7, 0x3C7DA6, 0x4F6D8F, 0x1F8A9E };
    const base = core.Color.rgb(tints[h % tints.len]);
    cv.fillRoundRect(r, @as(f32, @floatFromInt(r.w)) * 0.24, base);
    if (name.len == 0) return;
    const style: font.Style = .{ .size = size, .weight = .semibold };
    const m = font.Metrics.of(style, cv.scale);
    const letter = name[0..1];
    _ = cv.text(@as(f32, @floatFromInt(r.x)) + (@as(f32, @floatFromInt(r.w)) - m.width(letter)) / 2, @floatFromInt(r.y + @divTrunc(r.h - m.lineHeight(), 2)), letter, style, th.get(.accent_text).withAlpha(255));
}

/// Side and bottom hairlines, and the status line on the bottom border.
pub fn drawBorders(cv: *Canvas, th: *const Theme, frame: Rect, status: tw.surface.Status, now: i64) void {
    const c = th.get(.hairline);
    cv.hairlineV(frame.x, frame.y + title_h, frame.h - title_h, c);
    cv.hairlineVRight(frame.right() - 1, frame.y + title_h, frame.h - title_h, c);
    const by = frame.bottom() - status_h;
    switch (status.kind) {
        .normal => cv.hairlineHBottom(frame.x, frame.bottom() - 1, frame.w, c),
        .progress => {
            cv.fillRect(.{ .x = frame.x, .y = by, .w = frame.w, .h = status_h }, th.get(.surface_sunken));
            const w: i32 = @intFromFloat(@as(f32, @floatFromInt(frame.w)) * std.math.clamp(status.progress, 0, 1));
            cv.fillRect(.{ .x = frame.x, .y = by, .w = w, .h = status_h }, th.get(.accent));
        },
        .working => {
            cv.fillRect(.{ .x = frame.x, .y = by, .w = frame.w, .h = status_h }, th.get(.surface_sunken));
            const period: i64 = 2200 * std.time.ns_per_ms;
            const f: f32 = @as(f32, @floatFromInt(@mod(now, period))) / @as(f32, @floatFromInt(period));
            const seg = @divTrunc(frame.w, 5);
            const x = frame.x - seg + @as(i32, @intFromFloat(f * @as(f32, @floatFromInt(frame.w + seg))));
            const old = cv.pushClip(frame);
            cv.fillRect(.{ .x = x, .y = by, .w = seg, .h = status_h }, th.get(.accent));
            cv.popClip(old);
        },
        .failed => {
            cv.fillRect(.{ .x = frame.x, .y = by, .w = frame.w, .h = status_h }, th.get(.surface));
            cv.dashedH(frame.x, by, frame.w, status_h, 10, 6, th.get(.danger));
        },
    }
}

test "buttons grow to the right only and fill the bar height" {
    const frame = Rect{ .x = 100, .y = 0, .w = 600, .h = 400 };
    const rest = buttonCenters(frame, 0, 0);
    const open = buttonCenters(frame, 1, 3);
    const icon_right: f32 = @floatFromInt(frame.x + icon_x + icon_size);
    try std.testing.expect(open[0] - buttonRadius(1) > icon_right);
    try std.testing.expectApproxEqAbs(rest[0] - buttonRadius(0), open[0] - buttonRadius(1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), buttonCenterY(frame, 1) - buttonRadius(1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, title_h - 1), buttonCenterY(frame, 1) + buttonRadius(1), 0.001);
}
