//! Small line glyphs the shell draws: the top-bar icons and the symbols in
//! their menus. Each is drawn around a center, about 16 px across, in one
//! color; state is shown by shape, never by color alone.

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");

const Rect = core.Rect;
const Color = core.Color;
const Canvas = tw.Canvas;
const font = tw.font;

fn box(x: f32, y: f32, w: i32, h: i32) Rect {
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)), .w = w, .h = h };
}

/// An arc around (cx, cy) from angle `a0` to `a1` (radians, y down).
pub fn arc(cv: *Canvas, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, c: Color) void {
    const n = 10;
    var px = cx + r * @cos(a0);
    var py = cy + r * @sin(a0);
    var i: f32 = 1;
    while (i <= n) : (i += 1) {
        const a = a0 + (a1 - a0) * i / n;
        const qx = cx + r * @cos(a);
        const qy = cy + r * @sin(a);
        cv.line(px, py, qx, qy, width, c);
        px = qx;
        py = qy;
    }
}

/// Settings: a gear (until the desktop has an icon of its own).
pub fn gear(cv: *Canvas, cx: f32, cy: f32, c: Color, hole: Color) void {
    var i: f32 = 0;
    while (i < 8) : (i += 1) {
        const a = i / 8 * std.math.tau;
        cv.line(cx + 5 * @cos(a), cy + 5 * @sin(a), cx + 7.2 * @cos(a), cy + 7.2 * @sin(a), 2.2, c);
    }
    cv.fillCircle(cx, cy, 5.2, c);
    cv.fillCircle(cx, cy, 2.4, hole);
}

/// Control center: two switches, one off and one on.
pub fn toggles(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.strokeRoundRect(box(cx - 8, cy - 7, 16, 6), 3, 1.3, c);
    cv.fillCircle(cx - 5, cy - 4, 1.9, c);
    cv.strokeRoundRect(box(cx - 8, cy + 1, 16, 6), 3, 1.3, c);
    cv.fillCircle(cx + 5, cy + 4, 1.9, c);
}

/// Device center: a screen with a phone in front of it.
pub fn devices(cv: *Canvas, cx: f32, cy: f32, c: Color, bg: Color) void {
    cv.strokeRoundRect(box(cx - 9, cy - 7, 14, 10), 1.5, 1.3, c);
    cv.line(cx - 5, cy + 6, cx + 1, cy + 6, 1.3, c);
    cv.line(cx - 2, cy + 3, cx - 2, cy + 6, 1.3, c);
    const phone = box(cx + 2, cy - 3, 7, 11);
    cv.fillRoundRect(phone.inset(-2), 2.5, bg);
    cv.fillRoundRect(phone, 1.5, c);
    cv.fillRect(box(cx + 3.5, cy - 1.5, 4, 6), bg);
}

/// Language: the keyboard layout's code in an outlined key.
pub fn layoutKey(cv: *Canvas, cx: f32, cy: f32, code: []const u8, c: Color) void {
    const style: font.Style = .{ .size = .small, .weight = .semibold };
    const m = font.Metrics.of(style, cv.scale);
    const w = m.width(code);
    const bw: i32 = @max(20, @as(i32, @intFromFloat(@ceil(w))) + 8);
    cv.strokeRoundRect(box(cx - @as(f32, @floatFromInt(bw)) / 2, cy - 7, bw, 14), 3, 1.2, c);
    _ = cv.text(cx - w / 2, cy - @as(f32, @floatFromInt(m.lineHeight())) / 2, code, style, c);
}

/// Wi-Fi: a dot and three arcs, those beyond `signal` faded.
pub fn wifi(cv: *Canvas, cx: f32, cy: f32, signal: u8, c: Color) void {
    const by = cy + 5.5;
    cv.fillCircle(cx, by, 1.6, c);
    var k: u8 = 0;
    while (k < 3) : (k += 1) {
        const r = 4.5 + 3.5 * @as(f32, @floatFromInt(k));
        arc(cv, cx, by, r, -std.math.pi * 0.75, -std.math.pi * 0.25, 1.7, if (k < signal) c else c.fade(0.3));
    }
}

/// Bluetooth: the rune.
pub fn bluetooth(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    const w = 1.5;
    cv.line(cx, cy - 7, cx, cy + 7, w, c);
    cv.line(cx, cy - 7, cx + 4, cy - 3.5, w, c);
    cv.line(cx + 4, cy - 3.5, cx - 4, cy + 3.5, w, c);
    cv.line(cx, cy + 7, cx + 4, cy + 3.5, w, c);
    cv.line(cx + 4, cy + 3.5, cx - 4, cy - 3.5, w, c);
}

/// Wired network: three linked boxes.
pub fn wired(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.fillRoundRect(box(cx - 3, cy - 7, 6, 5), 1, c);
    cv.fillRoundRect(box(cx - 8, cy + 2, 6, 5), 1, c);
    cv.fillRoundRect(box(cx + 2, cy + 2, 6, 5), 1, c);
    cv.line(cx, cy - 2, cx, cy - 0.5, 1.4, c);
    cv.line(cx - 5, cy - 0.5, cx + 5, cy - 0.5, 1.4, c);
    cv.line(cx - 5, cy - 0.5, cx - 5, cy + 2, 1.4, c);
    cv.line(cx + 5, cy - 0.5, cx + 5, cy + 2, 1.4, c);
}

/// Sound output: a speaker with one to three waves for the level, none at
/// zero, a cross when muted.
pub fn speaker(cv: *Canvas, cx: f32, cy: f32, level: f32, muted: bool, c: Color) void {
    const left = cx - 8;
    const neck = cx - 4.5;
    const mouth = cx - 0.5;
    var x = left;
    while (x <= mouth) : (x += 0.5) {
        const half: f32 = if (x < neck) 2.5 else 2.5 + (x - neck) / (mouth - neck) * 3.5;
        cv.line(x, cy - half, x, cy + half, 0.8, c);
    }
    if (muted) {
        cv.line(cx + 2.5, cy - 3, cx + 8, cy + 3, 1.6, c);
        cv.line(cx + 2.5, cy + 3, cx + 8, cy - 3, 1.6, c);
        return;
    }
    const waves: u8 = if (level <= 0) 0 else if (level < 0.34) 1 else if (level < 0.67) 2 else 3;
    const spread = std.math.pi * 0.28;
    var k: u8 = 0;
    while (k < waves) : (k += 1) {
        arc(cv, mouth, cy, 3 + 2.6 * @as(f32, @floatFromInt(k)), -spread, spread, 1.5, c);
    }
}

/// Sound input: a microphone, struck through when muted.
pub fn mic(cv: *Canvas, cx: f32, cy: f32, muted: bool, c: Color) void {
    cv.fillRoundRect(box(cx - 2.5, cy - 8, 5, 10), 2.5, c);
    arc(cv, cx, cy - 1, 5, 0, std.math.pi, 1.4, c);
    cv.line(cx, cy + 4, cx, cy + 7, 1.4, c);
    cv.line(cx - 3, cy + 7, cx + 3, cy + 7, 1.4, c);
    if (muted) cv.line(cx - 6, cy - 7, cx + 6, cy + 6, 1.6, c);
}

/// USB: the trident.
pub fn usb(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx, cy - 6, cx, cy + 5, 1.4, c);
    cv.line(cx, cy - 7.5, cx - 2, cy - 5, 1.4, c);
    cv.line(cx, cy - 7.5, cx + 2, cy - 5, 1.4, c);
    cv.fillCircle(cx, cy + 6, 2, c);
    cv.line(cx, cy + 2, cx - 4.5, cy - 1, 1.4, c);
    cv.line(cx - 4.5, cy - 1, cx - 4.5, cy - 2.5, 1.4, c);
    cv.fillRect(box(cx - 6, cy - 5, 3, 3), c);
    cv.line(cx, cy + 0.5, cx + 4.5, cy - 2.5, 1.4, c);
    cv.fillCircle(cx + 4.5, cy - 3.5, 1.6, c);
}

/// A shared folder: a folder.
pub fn folder(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.fillRoundRect(box(cx - 8, cy - 6, 7, 4), 1.5, c);
    cv.fillRoundRect(box(cx - 8, cy - 4, 16, 10), 2, c);
}

/// A remote disk: a drive with its light.
pub fn disk(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.strokeRoundRect(box(cx - 8, cy - 5, 16, 10), 2, 1.3, c);
    cv.line(cx - 7, cy + 1, cx + 7, cy + 1, 1.2, c);
    cv.fillCircle(cx + 4.5, cy + 3, 1.1, c);
}

/// A check mark: the chosen item of a list.
pub fn check(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx - 5, cy, cx - 1.5, cy + 3.5, 1.8, c);
    cv.line(cx - 1.5, cy + 3.5, cx + 5, cy - 4, 1.8, c);
}

/// A padlock: a secured network.
pub fn lock(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    arc(cv, cx, cy - 1, 2.6, std.math.pi, std.math.tau, 1.3, c);
    cv.fillRoundRect(box(cx - 4, cy - 1, 8, 6), 1.2, c);
}

/// A chevron pointing right: more is behind it.
pub fn chevronRight(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx - 2, cy - 4.5, cx + 2.5, cy, 1.7, c);
    cv.line(cx + 2.5, cy, cx - 2, cy + 4.5, 1.7, c);
}

/// A chevron pointing left: back.
pub fn chevronLeft(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx + 2, cy - 4.5, cx - 2.5, cy, 1.7, c);
    cv.line(cx - 2.5, cy, cx + 2, cy + 4.5, 1.7, c);
}

/// Two bars: paused.
pub fn pause(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx - 1.5, cy - 2.5, cx - 1.5, cy + 2.5, 1.4, c);
    cv.line(cx + 1.5, cy - 2.5, cx + 1.5, cy + 2.5, 1.4, c);
}

/// A plus: add.
pub fn plus(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx - 5, cy, cx + 5, cy, 1.7, c);
    cv.line(cx, cy - 5, cx, cy + 5, 1.7, c);
}

/// A minus: remove.
pub fn minus(cv: *Canvas, cx: f32, cy: f32, c: Color) void {
    cv.line(cx - 5, cy, cx + 5, cy, 1.7, c);
}
