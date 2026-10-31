//! Where a popup goes (xdg_positioner): an anchor point on the anchor
//! rect, a gravity telling which way the popup extends from it, an offset,
//! and rules for staying inside the allowed area: flip to the other side,
//! then slide, then shrink.
//!
//! Pure geometry, in the parent's window-geometry coordinates.

const std = @import("std");

pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// xdg_positioner.anchor and .gravity share these values.
pub const Edge = enum(u32) { none = 0, top, bottom, left, right, top_left, bottom_left, top_right, bottom_right, _ };

pub const adjust_slide_x: u32 = 1;
pub const adjust_slide_y: u32 = 2;
pub const adjust_flip_x: u32 = 4;
pub const adjust_flip_y: u32 = 8;
pub const adjust_resize_x: u32 = 16;
pub const adjust_resize_y: u32 = 32;

pub const Positioner = struct {
    w: i32 = 0,
    h: i32 = 0,
    anchor_rect: Rect = .{},
    anchor: Edge = .none,
    gravity: Edge = .none,
    adjust: u32 = 0,
    off_x: i32 = 0,
    off_y: i32 = 0,

    /// The popup's rect. `bounds` is the area it must stay in, in the same
    /// coordinates (the window's content, or the screen).
    pub fn place(self: Positioner, bounds: Rect) Rect {
        var r = self.unconstrained(self.anchor, self.gravity);
        if (overflowX(r, bounds) and self.adjust & adjust_flip_x != 0) {
            const f = self.unconstrained(flipX(self.anchor), flipX(self.gravity));
            if (!overflowX(f, bounds)) r.x = f.x;
        }
        if (overflowY(r, bounds) and self.adjust & adjust_flip_y != 0) {
            const f = self.unconstrained(flipY(self.anchor), flipY(self.gravity));
            if (!overflowY(f, bounds)) r.y = f.y;
        }
        if (self.adjust & adjust_slide_x != 0) {
            if (r.x + r.w > bounds.x + bounds.w) r.x = bounds.x + bounds.w - r.w;
            if (r.x < bounds.x) r.x = bounds.x;
        }
        if (self.adjust & adjust_slide_y != 0) {
            if (r.y + r.h > bounds.y + bounds.h) r.y = bounds.y + bounds.h - r.h;
            if (r.y < bounds.y) r.y = bounds.y;
        }
        if (self.adjust & adjust_resize_x != 0) {
            const x0 = @max(r.x, bounds.x);
            const x1 = @min(r.x + r.w, bounds.x + bounds.w);
            if (x1 > x0) {
                r.x = x0;
                r.w = x1 - x0;
            }
        }
        if (self.adjust & adjust_resize_y != 0) {
            const y0 = @max(r.y, bounds.y);
            const y1 = @min(r.y + r.h, bounds.y + bounds.h);
            if (y1 > y0) {
                r.y = y0;
                r.h = y1 - y0;
            }
        }
        return r;
    }

    fn unconstrained(self: Positioner, anchor: Edge, gravity: Edge) Rect {
        const a = self.anchor_rect;
        // The anchor point on the anchor rect.
        const ax = switch (anchor) {
            .left, .top_left, .bottom_left => a.x,
            .right, .top_right, .bottom_right => a.x + a.w,
            else => a.x + @divTrunc(a.w, 2),
        };
        const ay = switch (anchor) {
            .top, .top_left, .top_right => a.y,
            .bottom, .bottom_left, .bottom_right => a.y + a.h,
            else => a.y + @divTrunc(a.h, 2),
        };
        // The popup extends from the anchor point toward the gravity.
        const x = switch (gravity) {
            .left, .top_left, .bottom_left => ax - self.w,
            .right, .top_right, .bottom_right => ax,
            else => ax - @divTrunc(self.w, 2),
        };
        const y = switch (gravity) {
            .top, .top_left, .top_right => ay - self.h,
            .bottom, .bottom_left, .bottom_right => ay,
            else => ay - @divTrunc(self.h, 2),
        };
        return .{ .x = x + self.off_x, .y = y + self.off_y, .w = self.w, .h = self.h };
    }
};

fn overflowX(r: Rect, b: Rect) bool {
    return r.x < b.x or r.x + r.w > b.x + b.w;
}

fn overflowY(r: Rect, b: Rect) bool {
    return r.y < b.y or r.y + r.h > b.y + b.h;
}

fn flipX(e: Edge) Edge {
    return switch (e) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => e,
    };
}

fn flipY(e: Edge) Edge {
    return switch (e) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => e,
    };
}

test "a menu under its button" {
    const p: Positioner = .{ .w = 200, .h = 300, .anchor_rect = .{ .x = 10, .y = 0, .w = 80, .h = 30 }, .anchor = .bottom_left, .gravity = .bottom_right };
    const r = p.place(.{ .w = 1000, .h = 800 });
    try std.testing.expectEqual(Rect{ .x = 10, .y = 30, .w = 200, .h = 300 }, r);
}

test "flip up near the bottom, slide in from the right" {
    var p: Positioner = .{ .w = 200, .h = 300, .anchor_rect = .{ .x = 900, .y = 700, .w = 80, .h = 30 }, .anchor = .bottom_left, .gravity = .bottom_right, .adjust = adjust_flip_y | adjust_slide_x };
    const r = p.place(.{ .w = 1000, .h = 800 });
    try std.testing.expectEqual(@as(i32, 700 - 300), r.y);
    try std.testing.expectEqual(@as(i32, 800), r.x);
    // Without adjustments it stays where asked, even outside.
    p.adjust = 0;
    try std.testing.expectEqual(@as(i32, 730), p.place(.{ .w = 1000, .h = 800 }).y);
}

test "centered on the anchor rect, with an offset" {
    const p: Positioner = .{ .w = 40, .h = 20, .anchor_rect = .{ .x = 100, .y = 100, .w = 60, .h = 60 }, .off_x = 5, .off_y = -3 };
    try std.testing.expectEqual(Rect{ .x = 115, .y = 117, .w = 40, .h = 20 }, p.place(.{ .w = 1000, .h = 1000 }));
}
