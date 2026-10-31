//! Attention tiling: the layout executor as a pure function
//! (Top-Level Design, "Window layout"; Design Concept, "attention tiling").
//!
//! Rules implemented:
//!  - up to 2 rows and 4 windows per screen; more go to the shelf
//!  - windows 1–2 share row 0; the 3rd and 4th go to row 1
//!    (open question: which row a new window goes to; for now, by order)
//!  - row 1 is as tall as its content needs; row 0 gets the rest
//!  - a lone window fills the whole area; tiles appear with two or more
//!  - each window gets a **window tile**: the area allocated to it
//!  - in normal mode a window fills 99% of its tile, centered, so a thin
//!    margin shows where the tile ends (agreed 2026-10-14 at 95%, raised to
//!    99% 2026-10-28; replaces "centered at its optimal size")
//!  - a tile is as wide as its window needs (optimal width / fill); the
//!    leftover width goes to the tiles of windows that can use it
//!    (growable: reflowable content such as documents), equally between
//!    them; if none can, it is shared equally between all tiles
//!  - when windows don't fit, a window with fixed content keeps its tile and
//!    a growable one takes the rest; between two of the same kind, the
//!    focused one keeps its optimal width
//!  - the user's border drags override slot widths and the row split

const std = @import("std");
const core = @import("krkcore");
const Rect = core.Rect;
const Size = core.Size;

pub const max_windows = 4;
pub const max_rows = 2;

pub const Params = struct {
    /// How much of its tile a window fills, per axis.
    fill: f32 = 0.99,
    min_slot_w: i32 = 260,
    min_row_h: i32 = 140,
    /// Row 1 may take at most this fraction of the height.
    row1_max: f32 = 0.5,
};

/// The user's adjustments, from dragging shared borders.
pub const Overrides = struct {
    /// Fraction of the height given to row 0.
    row_split: ?f32 = null,
    /// Per row, the fraction of the row width given to its first slot.
    col_split: [max_rows]?f32 = .{ null, null },
};

pub const Item = struct {
    /// Optimal frame size (content + chrome).
    optimal: Size,
    focused: bool = false,
    /// The window's content can use more room than its optimal size.
    growable: bool = false,
};

pub const Slot = struct {
    /// The tile: the area allocated to the window.
    slot: Rect,
    /// The window's frame inside its tile.
    frame: Rect,
    row: u8,
};

pub fn rowOf(index: usize, count: usize) u8 {
    if (count <= 2) return 0;
    return if (index < 2) 0 else 1;
}

pub fn layout(area: Rect, items: []const Item, ov: Overrides, p: Params, out: []Slot) void {
    const n = @min(items.len, max_windows);
    if (n == 0) return;
    std.debug.assert(out.len >= n);

    // A lone window has the whole area: tiling only matters with two or
    // more windows (agreed 2026-10-14).
    if (n == 1) {
        out[0] = .{ .slot = area, .frame = area, .row = 0 };
        return;
    }

    // Row heights.
    var rows: [max_rows]Rect = undefined;
    const two_rows = n > 2;
    if (!two_rows) {
        rows[0] = area;
    } else {
        var want1: i32 = 0;
        for (items[2..n]) |it| want1 = @max(want1, it.optimal.h);
        const max1: i32 = @intFromFloat(@as(f32, @floatFromInt(area.h)) * p.row1_max);
        var h1 = std.math.clamp(want1, p.min_row_h, @max(p.min_row_h, max1));
        if (ov.row_split) |s| {
            h1 = area.h - @as(i32, @intFromFloat(@as(f32, @floatFromInt(area.h)) * s));
        }
        h1 = std.math.clamp(h1, p.min_row_h, area.h - p.min_row_h);
        rows[0] = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h - h1 };
        rows[1] = .{ .x = area.x, .y = area.y + area.h - h1, .w = area.w, .h = h1 };
    }

    // Slots within each row.
    var row_idx: u8 = 0;
    while (row_idx < (if (two_rows) @as(u8, 2) else 1)) : (row_idx += 1) {
        const first: usize = if (row_idx == 0) 0 else 2;
        const last: usize = if (row_idx == 0) @min(n, 2) else n;
        const members = items[first..last];
        const widths = slotWidths(rows[row_idx].w, members, ov.col_split[row_idx], p);
        var x = rows[row_idx].x;
        for (members, 0..) |_, i| {
            const slot = Rect{ .x = x, .y = rows[row_idx].y, .w = widths[i], .h = rows[row_idx].h };
            out[first + i] = .{ .slot = slot, .frame = fillFrame(slot, p.fill), .row = row_idx };
            x += widths[i];
        }
    }
}

/// The window's frame: `fill` of the tile on each axis, centered.
pub fn fillFrame(tile: Rect, fill: f32) Rect {
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(tile.w)) * fill));
    const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(tile.h)) * fill));
    return tile.centered(.{ .w = w, .h = h });
}

fn tileFor(optimal: i32, fill: f32) i32 {
    return @intFromFloat(@ceil(@as(f32, @floatFromInt(optimal)) / fill));
}

fn slotWidths(total: i32, members: []const Item, split: ?f32, p: Params) [2]i32 {
    var w: [2]i32 = .{ total, 0 };
    if (members.len == 1) return w;
    if (split) |s| {
        const a = std.math.clamp(@as(i32, @intFromFloat(@as(f32, @floatFromInt(total)) * s)), p.min_slot_w, total - p.min_slot_w);
        return .{ a, total - a };
    }
    // The tile a window needs so that `fill` of it is its optimal width.
    const oa = tileFor(members[0].optimal.w, p.fill);
    const ob = tileFor(members[1].optimal.w, p.fill);
    if (oa + ob <= total) {
        // Everything fits: the leftover goes to windows that can use it.
        const extra = total - oa - ob;
        const ga = members[0].growable;
        const gb = members[1].growable;
        if (ga and !gb) {
            w = .{ oa + extra, ob };
        } else if (gb and !ga) {
            w = .{ oa, ob + extra };
        } else {
            const half = @divTrunc(extra, 2);
            w = .{ oa + half, total - oa - half };
        }
    } else if (members[0].growable != members[1].growable) {
        // Too wide: the window with fixed content keeps what it needs;
        // the growable one reflows into the rest.
        if (members[0].growable) {
            const b = std.math.clamp(ob, p.min_slot_w, total - p.min_slot_w);
            w = .{ total - b, b };
        } else {
            const a = std.math.clamp(oa, p.min_slot_w, total - p.min_slot_w);
            w = .{ a, total - a };
        }
    } else if (members[0].focused) {
        const a = std.math.clamp(oa, p.min_slot_w, total - p.min_slot_w);
        w = .{ a, total - a };
    } else if (members[1].focused) {
        const b = std.math.clamp(ob, p.min_slot_w, total - p.min_slot_w);
        w = .{ total - b, b };
    } else {
        const a = @divTrunc(total * oa, oa + ob);
        w = .{ a, total - a };
    }
    return w;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const screen = Rect{ .x = 0, .y = 0, .w = 1600, .h = 900 };

test "a lone window fills the whole area" {
    var out: [4]Slot = undefined;
    layout(screen, &.{.{ .optimal = .{ .w = 800, .h = 600 } }}, .{}, .{}, &out);
    try testing.expect(out[0].frame.eql(screen));
}

test "two windows that fit: leftover shared equally when neither can grow" {
    var out: [4]Slot = undefined;
    layout(screen, &.{ .{ .optimal = .{ .w = 570, .h = 800 } }, .{ .optimal = .{ .w = 380, .h = 800 } } }, .{}, .{}, &out);
    // Tiles of 576 and 384 needed; 640 left over, 320 each.
    try testing.expectEqual(@as(i32, 896), out[0].slot.w);
    try testing.expectEqual(@as(i32, 704), out[1].slot.w);
    try testing.expectEqual(@as(i32, 0), out[0].row);
    try testing.expectEqual(@as(i32, 0), out[1].row);
}

test "the leftover goes to the window that can use it" {
    var out: [4]Slot = undefined;
    layout(screen, &.{ .{ .optimal = .{ .w = 570, .h = 800 } }, .{ .optimal = .{ .w = 380, .h = 800 }, .growable = true } }, .{}, .{}, &out);
    try testing.expectEqual(@as(i32, 576), out[0].slot.w); // just what it needs
    try testing.expectEqual(@as(i32, 570), out[0].frame.w); // 99% of it = optimal
    try testing.expectEqual(@as(i32, 1024), out[1].slot.w);
}

test "too wide: the focused window keeps its optimal width" {
    var out: [4]Slot = undefined;
    layout(screen, &.{ .{ .optimal = .{ .w = 1000, .h = 800 } }, .{ .optimal = .{ .w = 1000, .h = 800 }, .focused = true } }, .{}, .{}, &out);
    try testing.expectEqual(@as(i32, 1011), out[1].slot.w); // 1000 / 0.99
    try testing.expectEqual(@as(i32, 589), out[0].slot.w);
}

test "third window goes to a short second row" {
    var out: [4]Slot = undefined;
    layout(screen, &.{
        .{ .optimal = .{ .w = 700, .h = 900 } },
        .{ .optimal = .{ .w = 700, .h = 900 } },
        .{ .optimal = .{ .w = 400, .h = 200 } },
    }, .{}, .{}, &out);
    try testing.expectEqual(@as(u8, 1), out[2].row);
    try testing.expectEqual(@as(i32, 200), out[2].slot.h);
    try testing.expectEqual(@as(i32, 700), out[0].slot.h);
    try testing.expectEqual(@as(i32, 1600), out[2].slot.w); // spans the row
    try testing.expectEqual(@as(i32, 8), out[2].frame.x); // 99% of the tile, centered
}

test "too wide: fixed content keeps its tile, growable takes the rest" {
    var out: [4]Slot = undefined;
    layout(screen, &.{ .{ .optimal = .{ .w = 950, .h = 800 } }, .{ .optimal = .{ .w = 760, .h = 800 }, .growable = true, .focused = true } }, .{}, .{}, &out);
    try testing.expectEqual(@as(i32, 960), out[0].slot.w);
    try testing.expectEqual(@as(i32, 640), out[1].slot.w);
}

test "overrides from border drags" {
    var out: [4]Slot = undefined;
    var ov: Overrides = .{};
    ov.col_split[0] = 0.25;
    layout(screen, &.{ .{ .optimal = .{ .w = 600, .h = 800 } }, .{ .optimal = .{ .w = 600, .h = 800 } } }, ov, .{}, &out);
    try testing.expectEqual(@as(i32, 400), out[0].slot.w);
}
