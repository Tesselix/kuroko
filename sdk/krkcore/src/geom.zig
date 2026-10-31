//! Geometry in logical pixels. Physical pixels = logical × scale.

const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    w: i32,
    h: i32,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= @as(f32, @floatFromInt(r.x)) and y >= @as(f32, @floatFromInt(r.y)) and
            x < @as(f32, @floatFromInt(r.right())) and y < @as(f32, @floatFromInt(r.bottom()));
    }
    pub fn inset(r: Rect, d: i32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = @max(0, r.w - 2 * d), .h = @max(0, r.h - 2 * d) };
    }
    pub fn insetXY(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
    /// The smallest rect holding both.
    pub fn unite(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.right(), b.right()) - x0, .h = @max(a.bottom(), b.bottom()) - y0 };
    }

    pub fn translate(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
    /// A rect of `size` centered in `r`, never larger than `r`.
    pub fn centered(r: Rect, size: Size) Rect {
        const w = @min(size.w, r.w);
        const h = @min(size.h, r.h);
        return .{ .x = r.x + @divTrunc(r.w - w, 2), .y = r.y + @divTrunc(r.h - h, 2), .w = w, .h = h };
    }
    /// Moves `r` so it lies inside `bounds` where possible.
    pub fn clampInto(r: Rect, bounds: Rect) Rect {
        var out = r;
        if (out.right() > bounds.right()) out.x = bounds.right() - out.w;
        if (out.bottom() > bounds.bottom()) out.y = bounds.bottom() - out.h;
        if (out.x < bounds.x) out.x = bounds.x;
        if (out.y < bounds.y) out.y = bounds.y;
        return out;
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

/// Rect with float fields, for animation.
pub const RectF = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn from(r: Rect) RectF {
        return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
    }
    pub fn round(r: RectF) Rect {
        return .{ .x = @intFromFloat(@round(r.x)), .y = @intFromFloat(@round(r.y)), .w = @intFromFloat(@round(r.w)), .h = @intFromFloat(@round(r.h)) };
    }
    pub fn lerp(a: RectF, b: RectF, t: f32) RectF {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t, .w = a.w + (b.w - a.w) * t, .h = a.h + (b.h - a.h) * t };
    }
};

test "centered and clamp" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const c = r.centered(.{ .w = 40, .h = 10 });
    try std.testing.expectEqual(@as(i32, 30), c.x);
    try std.testing.expectEqual(@as(i32, 20), c.y);
    const big = r.centered(.{ .w = 400, .h = 10 });
    try std.testing.expectEqual(@as(i32, 100), big.w);
    const moved = (Rect{ .x = 90, .y = 0, .w = 20, .h = 10 }).clampInto(r);
    try std.testing.expectEqual(@as(i32, 80), moved.x);
}
