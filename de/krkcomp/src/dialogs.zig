//! Dialogs (Top-Level Design, "Dialogs"): windows that float over the
//! others and are never tiled. Modal or modeless, near the window that
//! opened them; desktop dialogs above every app dialog. This file holds
//! the dialog itself, where it goes and how it moves; the compositor
//! routes input to it and draws it in its layer.

const std = @import("std");
const core = @import("krkcore");
const tw = @import("krkwidgets");

const Rect = core.Rect;
const Size = core.Size;
const Handle = core.Handle;
const Surface = tw.Surface;
const Canvas = tw.Canvas;
const ms = std.time.ns_per_ms;

pub const Layer = enum { app, desktop };

pub const Options = struct {
    /// The window that opened it; none for a desktop dialog of its own.
    parent: ?Handle = null,
    modal: bool = false,
    layer: Layer = .app,
};

pub const appear_ms = 180;
pub const close_ms = 150;
pub const nudge_ms = 200;
/// Room kept between a dialog and the work area's edges.
pub const margin = 16;
/// The frame around the content: its rounded corners stay outside the
/// content's square ones.
pub const frame_pad = 6;
pub const frame_radius = 14;

pub const Dialog = struct {
    id: u32,
    surface: Surface,
    opts: Options,

    pixels: []u32 = &.{},
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    image_id: u64 = 0,
    version: u64 = 0,
    content: Size = .{ .w = 0, .h = 0 },
    dirty: bool = true,

    open_start: i64,
    close_start: i64 = -1,
    nudge_start: i64 = -1,
    /// Where its content is on screen this frame (hit testing); empty
    /// while hidden with its parent.
    rect: Rect = .{},

    pub fn image(d: *const Dialog) tw.Image {
        return .{ .pixels = d.pixels, .w = d.buf_w, .h = d.buf_h, .id = d.image_id, .version = d.version };
    }

    /// Draws the content into the buffer if it changed.
    pub fn paint(d: *Dialog, scale: i32) void {
        if (!d.dirty or d.pixels.len == 0) return;
        var cv = Canvas.init(d.pixels, d.buf_w, d.buf_h, d.buf_w, scale);
        d.surface.draw(&cv);
        d.dirty = false;
        d.version += 1;
    }

    pub fn closing(d: *const Dialog) bool {
        return d.close_start >= 0;
    }

    /// Done closing: it can be destroyed.
    pub fn gone(d: *const Dialog, now: i64) bool {
        return d.closing() and now - d.close_start >= close_ms * ms;
    }

    pub fn animating(d: *const Dialog, now: i64) bool {
        return now - d.open_start < appear_ms * ms or d.closing() or (d.nudge_start >= 0 and now - d.nudge_start < nudge_ms * ms);
    }

    /// How it is drawn now: its scale around its center and its opacity.
    /// Appears growing from 96 % and fading in; closes the other way; a
    /// nudge is one small bump.
    pub fn look(d: *const Dialog, now: i64) struct { k: f32, alpha: f32 } {
        var k: f32 = 1;
        var a: f32 = 1;
        const open_t = progress(now - d.open_start, appear_ms);
        const e = core.anim.easeOutCubic(open_t);
        k = 0.96 + 0.04 * e;
        a = e;
        if (d.closing()) {
            const c = core.anim.easeOutCubic(progress(now - d.close_start, close_ms));
            k *= 1 - 0.04 * c;
            a *= 1 - c;
        }
        if (d.nudge_start >= 0) {
            const t = progress(now - d.nudge_start, nudge_ms);
            if (t < 1) k *= 1 + 0.02 * @sin(std.math.pi * t);
        }
        return .{ .k = k, .alpha = a };
    }
};

fn progress(elapsed: i64, dur_ms: i64) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(dur_ms * ms)), 0, 1);
}

/// The size a dialog gets: its content's optimal size, inside the work
/// area with a margin.
pub fn fit(optimal: Size, area: Rect) Size {
    const max_w = area.w - 2 * (margin + frame_pad);
    const max_h = area.h - 2 * (margin + frame_pad);
    return .{ .w = std.math.clamp(optimal.w, 120, @max(120, max_w)), .h = std.math.clamp(optimal.h, 60, @max(60, max_h)) };
}

/// Where a dialog's content goes: centered over its parent's content, a
/// little above center (40 % of the free room above, 60 % below), or over
/// the work area when it has no parent; always inside the work area.
pub fn place(size: Size, parent: ?Rect, area: Rect) Rect {
    const over = parent orelse area;
    var r = Rect{
        .x = over.x + @divTrunc(over.w - size.w, 2),
        .y = over.y + @divTrunc((over.h - size.h) * 2, 5),
        .w = size.w,
        .h = size.h,
    };
    const inner = area.inset(margin + frame_pad);
    r.x = std.math.clamp(r.x, inner.x, @max(inner.x, inner.right() - r.w));
    r.y = std.math.clamp(r.y, inner.y, @max(inner.y, inner.bottom() - r.h));
    return r;
}

test "a dialog is centered over its parent, a little above center" {
    const area = Rect{ .x = 76, .y = 28, .w = 1364, .h = 872 };
    const parent = Rect{ .x = 100, .y = 100, .w = 600, .h = 500 };
    const r = place(.{ .w = 300, .h = 200 }, parent, area);
    try std.testing.expectEqual(@as(i32, 250), r.x);
    try std.testing.expectEqual(@as(i32, 100 + 120), r.y);
}

test "a dialog without a parent is centered on the work area; it never leaves it" {
    const area = Rect{ .x = 76, .y = 28, .w = 1364, .h = 872 };
    const r = place(.{ .w = 400, .h = 300 }, null, area);
    try std.testing.expectEqual(@as(i32, 76 + 482), r.x);
    // A parent at the right edge: the dialog stays inside.
    const edge = place(.{ .w = 500, .h = 200 }, .{ .x = 1200, .y = 40, .w = 240, .h = 300 }, area);
    try std.testing.expect(edge.right() <= area.right() - margin);
    try std.testing.expect(edge.y >= area.y + margin);
}

test "fit keeps a large dialog inside the work area" {
    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const s = fit(.{ .w = 2000, .h = 2000 }, area);
    try std.testing.expect(s.w <= 800 - 2 * margin and s.h <= 600 - 2 * margin);
}
