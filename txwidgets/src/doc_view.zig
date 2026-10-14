//! Document view: a scroll area over structured content, with the
//! scrolling behavior from Look and Controls:
//!
//!  - wheel bands (slow / fast / very fast), Shift = run, line unit
//!  - thin always-visible scrollbar that widens when the pointer approaches
//!  - document map on hover: at most ~5 pages, slides past the middle,
//!    position depends only on the pointer; structure drawn bolder
//!  - magnifier with the section title; click to jump keeps the clicked
//!    line at the pointer's height; jumps are animated
//!  - viewport marker (two lines + band) and center marker (line + ▸)
//!  - footprints (where the user read) and a back marker; Alt+← goes back
//!  - Home/End and Ctrl+Home/End go to top and bottom (no text cursor)

const std = @import("std");
const core = @import("txcore");
const font = @import("font.zig");
const scroll = @import("scroll.zig");
const Canvas = @import("canvas.zig").Canvas;

const Rect = core.Rect;
const Theme = core.Theme;
const Tween = core.anim.Tween;
const Band = core.wheel.Band;
const ms = std.time.ns_per_ms;

pub const BlockKind = enum { heading, paragraph, figure };

pub const Block = struct {
    kind: BlockKind,
    text: []const u8,
    /// Figure height in lines.
    lines: u8 = 8,
};

pub const MarkerParams = struct {
    enabled: bool = true,
    /// Center marker length as a fraction of the content width.
    center_fraction: f32 = 1.0 / 3.0,
    /// Fade-out after scrolling stops.
    fade_ms: i64 = 1000,
    viewport_band: bool = true,
    /// Jump anchor: the clicked line lands at the pointer's height, or at
    /// the center marker.
    jump_to_center: bool = false,
};

const LineKind = enum { heading, text, figure };

const Line = struct {
    y: f32,
    h: f32,
    kind: LineKind,
    block: u32,
    start: u32,
    end: u32,
    width: f32,
    section: u32,
    /// Space above the text inside the line box (headings).
    pad: f32 = 0,
};

const Section = struct {
    block: u32,
    y: f32,
    read_s: f32 = 0,
};

const gutter = 14;
const margin_x = 28;
const margin_top = 18;
const map_w = 112;
const body: font.Style = .{ .size = .body };
const heading_style: font.Style = .{ .size = .title, .weight = .semibold };
const small_semibold: font.Style = .{ .size = .small, .weight = .semibold };

pub const DocView = struct {
    gpa: std.mem.Allocator,
    blocks: []const Block,
    lines: std.ArrayList(Line) = .empty,
    sections: std.ArrayList(Section) = .empty,
    content_h: f32 = 0,
    laid_w: i32 = -1,
    laid_scale: i32 = 0,
    line_h: f32 = 19,
    rect: Rect = .{},

    scroller: scroll.Scroller = .{},
    map_params: scroll.MapParams = .{},
    markers: MarkerParams = .{},

    px: f32 = -1,
    py: f32 = -1,
    inside: bool = false,
    bar_w: Tween = Tween.init(3),
    strip_since: ?i64 = null,
    map_t: Tween = Tween.init(0),
    leave_since: ?i64 = null,
    drag_grab: ?f32 = null,

    back: [16]f32 = undefined,
    back_len: usize = 0,

    center_t: Tween = Tween.init(0),
    last_move: i64 = 0,
    last_tick: i64 = 0,
    shown_band: Band = .slow,

    pub fn create(gpa: std.mem.Allocator, blocks: []const Block) !*DocView {
        const d = try gpa.create(DocView);
        d.* = .{ .gpa = gpa, .blocks = blocks };
        return d;
    }

    pub fn destroy(self: *DocView) void {
        self.lines.deinit(self.gpa);
        self.sections.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // ------------------------------------------------------------ layout

    fn textWidth(self: *const DocView) i32 {
        return @max(80, self.rect.w - gutter - 2 * margin_x);
    }

    fn viewH(self: *const DocView) f32 {
        return @floatFromInt(self.rect.h);
    }

    pub fn arrange(self: *DocView, r: Rect, scale: i32) void {
        self.rect = r;
        const w = self.textWidth();
        if (w != self.laid_w or scale != self.laid_scale) {
            // Keep the line at the top of the view through a relayout.
            const anchor = self.lineAt(self.scroller.pos);
            const anchor_block: ?u32 = if (anchor) |i| self.lines.items[i].block else null;
            self.layoutLines(w, scale) catch {};
            if (anchor_block) |b| {
                for (self.lines.items) |l| {
                    if (l.block == b) {
                        self.scroller.setPos(l.y);
                        break;
                    }
                }
            }
        }
        self.scroller.setExtent(self.content_h + margin_top, self.viewH(), self.line_h);
    }

    fn layoutLines(self: *DocView, w: i32, scale: i32) !void {
        self.laid_w = w;
        self.laid_scale = scale;
        self.lines.clearRetainingCapacity();
        self.sections.clearRetainingCapacity();
        const bm = font.Metrics.of(body, scale);
        const hm = font.Metrics.of(heading_style, scale);
        self.line_h = @floatFromInt(bm.lineHeight());
        const maxw: f32 = @floatFromInt(w);
        var y: f32 = margin_top;
        var section: u32 = 0;
        for (self.blocks, 0..) |b, bi| {
            switch (b.kind) {
                .heading => {
                    if (self.sections.items.len > 0 or bi > 0) y += self.line_h * 0.9;
                    try self.sections.append(self.gpa, .{ .block = @intCast(bi), .y = y });
                    section = @intCast(self.sections.items.len - 1);
                    y = try self.wrap(b.text, @intCast(bi), section, .heading, hm, maxw, y, @floatFromInt(hm.lineHeight()));
                    y += self.line_h * 0.3;
                },
                .paragraph => {
                    y = try self.wrap(b.text, @intCast(bi), section, .text, bm, maxw, y, self.line_h);
                    y += self.line_h * 0.6;
                },
                .figure => {
                    const h = self.line_h * @as(f32, @floatFromInt(b.lines));
                    try self.lines.append(self.gpa, .{
                        .y = y,
                        .h = h,
                        .kind = .figure,
                        .block = @intCast(bi),
                        .start = 0,
                        .end = @intCast(b.text.len),
                        .width = maxw * 0.8,
                        .section = section,
                    });
                    y += h + self.line_h * 0.6;
                },
            }
        }
        self.content_h = y + self.line_h * 2;
    }

    fn wrap(self: *DocView, t: []const u8, bi: u32, section: u32, kind: LineKind, m: font.Metrics, maxw: f32, y0: f32, lh: f32) !f32 {
        var y = y0;
        const space = m.width(" ");
        var line_start: usize = 0;
        var line_w: f32 = 0;
        var last_end: usize = 0;
        var i: usize = 0;
        while (i <= t.len) {
            // Find the next word [i, j).
            while (i < t.len and t[i] == ' ') i += 1;
            if (i >= t.len) break;
            var j = i;
            while (j < t.len and t[j] != ' ') j += 1;
            const ww = m.width(t[i..j]);
            const add = if (last_end == 0 and line_w == 0) ww else line_w + space + ww;
            if (add > maxw and line_w > 0) {
                try self.lines.append(self.gpa, .{ .y = y, .h = lh, .kind = kind, .block = bi, .start = @intCast(line_start), .end = @intCast(last_end), .width = line_w, .section = section });
                y += lh;
                line_start = i;
                line_w = ww;
            } else {
                if (line_w == 0) line_start = i;
                line_w = add;
            }
            last_end = j;
            i = j;
        }
        if (line_w > 0) {
            try self.lines.append(self.gpa, .{ .y = y, .h = lh, .kind = kind, .block = bi, .start = @intCast(line_start), .end = @intCast(last_end), .width = line_w, .section = section });
            y += lh;
        }
        return y;
    }

    /// Index of the line at document y (or the last line above it).
    fn lineAt(self: *const DocView, y: f32) ?usize {
        const items = self.lines.items;
        if (items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid].y + items[mid].h <= y) lo = mid + 1 else hi = mid;
        }
        return @min(lo, items.len - 1);
    }

    fn sectionAt(self: *const DocView, y: f32) ?*Section {
        var found: ?*Section = null;
        for (self.sections.items) |*s| {
            if (s.y <= y) found = s else break;
        }
        return found;
    }

    // ------------------------------------------------------- geometry

    fn stripRect(self: *const DocView) Rect {
        return .{ .x = self.rect.right() - gutter, .y = self.rect.y, .w = gutter, .h = self.rect.h };
    }

    fn mapRect(self: *const DocView, now: i64) Rect {
        const t = self.map_t.value(now);
        const slide: i32 = @intFromFloat((1 - t) * 24);
        return .{
            .x = self.rect.right() - gutter - map_w - 2 + slide,
            .y = self.rect.y + 6,
            .w = map_w,
            .h = self.rect.h - 12,
        };
    }

    fn mapOpen(self: *const DocView) bool {
        return self.map_t.to > 0.5;
    }

    fn mapViewAt(self: *const DocView, py: f32, now: i64) scroll.MapView {
        const mr = self.mapRect(now);
        const f = (py - @as(f32, @floatFromInt(mr.y))) / @as(f32, @floatFromInt(@max(1, mr.h)));
        return scroll.mapView(self.content_h, self.viewH(), @floatFromInt(mr.h), f, self.map_params);
    }

    fn thumb(self: *const DocView) struct { y: f32, h: f32 } {
        const track: f32 = @floatFromInt(self.rect.h - 4);
        const total = self.content_h + margin_top;
        const vh = self.viewH();
        const h = if (total <= vh) track else @max(24, track * vh / total);
        const f = if (self.scroller.max <= 0) 0 else self.scroller.pos / self.scroller.max;
        return .{ .y = @as(f32, @floatFromInt(self.rect.y + 2)) + f * (track - h), .h = h };
    }

    // ------------------------------------------------------- interaction

    pub fn pointerMotion(self: *DocView, x: f32, y: f32, now: i64) void {
        self.px = x;
        self.py = y;
        self.inside = self.rect.contains(x, y);
        const near = self.inside and x >= @as(f32, @floatFromInt(self.rect.right() - 40));
        self.bar_w.set(if (near or self.drag_grab != null) 10 else 3, now, 120);

        const in_strip = self.stripRect().contains(x, y);
        if (in_strip) {
            if (self.strip_since == null) self.strip_since = now;
        } else self.strip_since = null;

        if (self.mapOpen()) {
            const keep = in_strip or self.mapRect(now).contains(x, y);
            if (keep) self.leave_since = null else if (self.leave_since == null) self.leave_since = now;
        }

        if (self.drag_grab) |grab| {
            const track: f32 = @floatFromInt(self.rect.h - 4);
            const th = self.thumb().h;
            const f = (y - grab - @as(f32, @floatFromInt(self.rect.y + 2))) / @max(1, track - th);
            self.scroller.setPos(f * self.scroller.max);
            self.noteMove(now);
        }
    }

    pub fn pointerLeave(self: *DocView, now: i64) void {
        self.inside = false;
        self.strip_since = null;
        self.bar_w.set(3, now, 120);
        if (self.mapOpen() and self.leave_since == null) self.leave_since = now;
    }

    /// Returns true if the press was used (the caller then captures).
    pub fn press(self: *DocView, x: f32, y: f32, now: i64) bool {
        if (self.mapOpen() and self.mapRect(now).contains(x, y)) {
            const v = self.mapViewAt(y, now);
            const anchor = if (self.markers.jump_to_center)
                self.viewH() / 2
            else
                y - @as(f32, @floatFromInt(self.rect.y));
            self.jumpWithBack(v.doc_y - anchor, now);
            return true;
        }
        if (self.stripRect().contains(x, y)) {
            const t = self.thumb();
            if (y >= t.y and y <= t.y + t.h) {
                self.drag_grab = y - t.y;
            } else {
                // Track click: jump so the thumb centers on the click.
                const track: f32 = @floatFromInt(self.rect.h - 4);
                const f = (y - t.h / 2 - @as(f32, @floatFromInt(self.rect.y + 2))) / @max(1, track - t.h);
                self.jumpWithBack(f * self.scroller.max, now);
            }
            return true;
        }
        return self.rect.contains(x, y);
    }

    pub fn release(self: *DocView, now: i64) void {
        self.drag_grab = null;
        self.bar_w.set(if (self.inside and self.px >= @as(f32, @floatFromInt(self.rect.right() - 40))) 10 else 3, now, 120);
    }

    pub fn wheel(self: *DocView, w: core.input.Wheel, now: i64) void {
        if (w.dy == 0) return;
        switch (w.source) {
            .touchpad => self.scroller.pixels(w.dy),
            .wheel => self.scroller.wheel(w.dy, w.band, w.rate),
        }
        self.shown_band = if (w.source == .touchpad) .slow else w.band;
        self.noteMove(now);
    }

    fn noteMove(self: *DocView, now: i64) void {
        self.last_move = now;
        if (self.markers.enabled) self.center_t.set(1, now, 120);
    }

    pub fn jumpWithBack(self: *DocView, y: f32, now: i64) void {
        const from = self.scroller.pos;
        const to = std.math.clamp(y, 0, self.scroller.max);
        if (@abs(to - from) > self.viewH() / 2) {
            if (self.back_len == self.back.len) {
                std.mem.copyForwards(f32, self.back[0 .. self.back.len - 1], self.back[1..]);
                self.back_len -= 1;
            }
            self.back[self.back_len] = from;
            self.back_len += 1;
        }
        self.scroller.jumpTo(to, now);
        self.noteMove(now);
    }

    pub fn goBack(self: *DocView, now: i64) bool {
        if (self.back_len == 0) return false;
        self.back_len -= 1;
        self.scroller.jumpTo(self.back[self.back_len], now);
        self.noteMove(now);
        return true;
    }

    pub fn key(self: *DocView, k: core.input.Key, mods: core.input.Mods, now: i64) bool {
        const page = self.viewH() - 2 * self.line_h;
        switch (k) {
            .down => self.scroller.wheel(1.0 / self.scroller.params.lines_per_notch, .slow, 0),
            .up => self.scroller.wheel(-1.0 / self.scroller.params.lines_per_notch, .slow, 0),
            .page_down, .space => self.scroller.jumpTo(self.scroller.target + page, now),
            .page_up => self.scroller.jumpTo(self.scroller.target - page, now),
            // No text cursor here: Home/End go to the top and bottom.
            .home => self.jumpWithBack(0, now),
            .end => self.jumpWithBack(self.scroller.max, now),
            .left => {
                if (!mods.alt) return false;
                return self.goBack(now);
            },
            else => return false,
        }
        self.noteMove(now);
        return true;
    }

    /// Returns true while anything animates.
    pub fn tick(self: *DocView, now: i64) bool {
        const dt: f32 = if (self.last_tick == 0) 0 else @as(f32, @floatFromInt(@min(now - self.last_tick, 100 * ms))) / std.time.ns_per_s;
        self.last_tick = now;
        const moving = self.scroller.update(dt, now);
        if (moving) self.last_move = now;

        if (self.strip_since) |t0| {
            if (!self.mapOpen() and now - t0 >= 80 * ms) {
                self.map_t.set(1, now, 160);
                self.leave_since = null;
            }
        }
        if (self.leave_since) |t0| {
            if (now - t0 >= 300 * ms) {
                self.map_t.set(0, now, 160);
                self.leave_since = null;
            }
        }
        // Center marker: while scrolling and while the map is open; fades.
        if (self.markers.enabled) {
            if (self.mapOpen()) {
                self.center_t.set(1, now, 120);
            } else if (!moving and now - self.last_move > self.markers.fade_ms * ms) {
                self.center_t.set(0, now, 400);
            }
        }
        if (!moving and now - self.last_move > 300 * ms) self.shown_band = .slow;

        // Footprints: time spent reading at the middle of the view.
        if (!moving and dt > 0 and self.inside) {
            if (self.sectionAt(self.scroller.pos + self.viewH() / 2)) |s| s.read_s += dt;
        }

        return moving or !self.bar_w.done(now) or !self.map_t.done(now) or !self.center_t.done(now) or
            self.strip_since != null or self.leave_since != null;
    }

    pub fn band(self: *const DocView) Band {
        return self.shown_band;
    }

    // --------------------------------------------------------------- draw

    pub fn draw(self: *DocView, cv: *Canvas, theme: *const Theme, now: i64) void {
        const r = self.rect;
        const old = cv.pushClip(r);
        defer cv.popClip(old);
        cv.fillRect(r, theme.get(.surface));

        const top = self.scroller.pos;
        const ox: f32 = @floatFromInt(r.x + margin_x);
        const oy: f32 = @as(f32, @floatFromInt(r.y)) - top;
        self.drawLines(cv, theme, top, top + self.viewH(), ox, oy);

        // Center marker in the content: right-aligned line ending in ▸.
        const ct = self.center_t.value(now);
        if (ct > 0.01) {
            const cy: f32 = @as(f32, @floatFromInt(r.y)) + self.viewH() / 2;
            const right: f32 = @floatFromInt(r.right() - gutter - 2);
            const len = @as(f32, @floatFromInt(r.w - gutter)) * self.markers.center_fraction;
            const c = theme.get(.center_marker).fade(ct);
            cv.fillRect(.{ .x = @intFromFloat(right - len), .y = @intFromFloat(cy), .w = @intFromFloat(len), .h = 1 }, c);
            cv.triangleRight(right + 1, cy + 0.5, 6, c);
        }

        self.drawScrollbar(cv, theme, now);
        if (self.map_t.value(now) > 0.01) {
            if (self.drawMap(cv, theme, now)) |doc_y| self.drawMagnifier(cv, theme, doc_y, now);
        }
    }

    fn drawLines(self: *DocView, cv: *Canvas, theme: *const Theme, y0: f32, y1: f32, ox: f32, oy: f32) void {
        const first = self.lineAt(y0) orelse return;
        for (self.lines.items[first..]) |l| {
            if (l.y > y1) break;
            const b = self.blocks[l.block];
            const y = oy + l.y;
            switch (l.kind) {
                .heading => _ = cv.text(ox, y, b.text[l.start..l.end], heading_style, theme.get(.text)),
                .text => _ = cv.text(ox, y, b.text[l.start..l.end], body, theme.get(.text)),
                .figure => drawFigure(cv, theme, .{
                    .x = @intFromFloat(ox),
                    .y = @intFromFloat(y),
                    .w = @intFromFloat(l.width),
                    .h = @intFromFloat(l.h),
                }, b.text),
            }
        }
    }

    fn drawFigure(cv: *Canvas, theme: *const Theme, r: Rect, caption: []const u8) void {
        const box = Rect{ .x = r.x, .y = r.y + 4, .w = r.w, .h = r.h - 8 };
        cv.fillRoundRect(box, 6, theme.get(.surface_alt));
        cv.strokeRoundRect(box, 6, 0, theme.get(.border));
        // A small line chart, so figures have a shape on the map too.
        const fx: f32 = @floatFromInt(box.x + 16);
        const fw: f32 = @floatFromInt(box.w - 32);
        const fy: f32 = @floatFromInt(box.y + 14);
        const fh: f32 = @floatFromInt(box.h - 44);
        const pts = [_]f32{ 0.7, 0.55, 0.62, 0.35, 0.42, 0.2, 0.3 };
        var i: usize = 1;
        while (i < pts.len) : (i += 1) {
            const xa = fx + fw * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(pts.len - 1));
            const xb = fx + fw * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pts.len - 1));
            cv.line(xa, fy + fh * pts[i - 1], xb, fy + fh * pts[i], 2, theme.get(.accent));
        }
        _ = cv.text(@floatFromInt(box.x + 16), @floatFromInt(box.bottom() - 24), caption, .{ .size = .small }, theme.get(.text_dim));
    }

    fn drawScrollbar(self: *DocView, cv: *Canvas, theme: *const Theme, now: i64) void {
        const r = self.rect;
        const bw: f32 = self.bar_w.value(now);
        const x: f32 = @as(f32, @floatFromInt(r.right() - 2)) - bw;
        const wide = bw > 4;
        if (wide) {
            cv.fillRoundRect(.{ .x = @intFromFloat(x), .y = r.y + 2, .w = @intFromFloat(@ceil(bw)), .h = r.h - 4 }, bw / 2, theme.get(.surface_sunken));
        }
        // Footprints: small ticks left of the bar.
        const total = self.content_h + margin_top;
        const track: f32 = @floatFromInt(r.h - 4);
        for (self.sections.items, 0..) |s, i| {
            if (s.read_s < 3) continue;
            const end = if (i + 1 < self.sections.items.len) self.sections.items[i + 1].y else self.content_h;
            const ya = @as(f32, @floatFromInt(r.y + 2)) + s.y / total * track;
            const yb = @as(f32, @floatFromInt(r.y + 2)) + end / total * track;
            cv.fillRect(.{ .x = @intFromFloat(x - 4), .y = @intFromFloat(ya), .w = 2, .h = @max(2, @as(i32, @intFromFloat(yb - ya))) }, theme.get(.footprint));
        }
        const t = self.thumb();
        const hot = self.drag_grab != null or (self.inside and self.px >= x - 2);
        const col = if (hot) theme.get(.text_dim) else theme.get(.border);
        cv.fillRoundRect(.{ .x = @intFromFloat(x), .y = @intFromFloat(t.y), .w = @intFromFloat(@ceil(bw)), .h = @intFromFloat(t.h) }, bw / 2, col);
        // Back marker: where "back" returns to.
        if (self.back_len > 0 and self.scroller.max > 0) {
            const by = @as(f32, @floatFromInt(r.y + 2)) + (self.back[self.back_len - 1] + self.viewH() / 2) / total * track;
            cv.line(x - 8, by, x - 3, by, 1.5, theme.get(.text_dim));
            cv.fillCircle(x - 9, by, 1.6, theme.get(.text_dim));
        }
    }

    /// Draws the map; returns the document y under the pointer when the
    /// pointer is over it (the magnifier is drawn after, over the content).
    fn drawMap(self: *DocView, cv: *Canvas, theme: *const Theme, now: i64) ?f32 {
        const t = self.map_t.value(now);
        const mr = self.mapRect(now);
        const over = self.mapRect(now).contains(self.px, self.py);
        const py = if (over) self.py else @as(f32, @floatFromInt(mr.y));
        const v = self.mapViewAt(py, now);

        cv.fillRect(mr.translate(-2, 2), theme.get(.shadow).fade(t));
        cv.fillRect(mr, theme.get(.surface_alt).fade(0.97 * t));
        cv.hairlineRect(mr, theme.get(.border).fade(t));
        const old = cv.pushClip(mr.inset(1));
        defer cv.popClip(old);

        const mx: f32 = @floatFromInt(mr.x + 8);
        const my: f32 = @floatFromInt(mr.y);
        const mw: f32 = @floatFromInt(mr.w - 14);
        const tw: f32 = @floatFromInt(self.textWidth());
        const sx = mw / tw;
        const doc_end = v.top + @as(f32, @floatFromInt(mr.h)) / v.scale;

        // Page separators.
        const page = self.viewH();
        var p = @floor(v.top / page) * page;
        while (p < doc_end) : (p += page) {
            if (p > 0) cv.hairlineH(mr.x + 3, @intFromFloat(my + (p - v.top) * v.scale), mr.w - 6, theme.get(.hairline).fade(0.6 * t));
        }

        // Structure: lines as bars, headings bolder, figures as boxes.
        if (self.lineAt(v.top)) |first| {
            for (self.lines.items[first..]) |l| {
                if (l.y > doc_end) break;
                const y = my + (l.y - v.top) * v.scale;
                const h = l.h * v.scale;
                switch (l.kind) {
                    .heading => cv.fillRect(.{ .x = @intFromFloat(mx), .y = @intFromFloat(y + h * 0.2), .w = @intFromFloat(@max(4, l.width * sx)), .h = @max(2, @as(i32, @intFromFloat(h * 0.6))) }, theme.get(.text).fade(0.85 * t)),
                    .text => cv.fillRect(.{ .x = @intFromFloat(mx), .y = @intFromFloat(y + h * 0.3), .w = @intFromFloat(@max(2, l.width * sx)), .h = @max(1, @as(i32, @intFromFloat(h * 0.4))) }, theme.get(.text_dim).fade(0.45 * t)),
                    .figure => {
                        const fr = Rect{ .x = @intFromFloat(mx), .y = @intFromFloat(y + 2), .w = @intFromFloat(l.width * sx), .h = @max(3, @as(i32, @intFromFloat(h - 4))) };
                        cv.fillRect(fr, theme.get(.accent).fade(0.18 * t));
                        cv.hairlineRect(fr, theme.get(.accent).fade(0.6 * t));
                    },
                }
            }
        }

        // Footprints on the map's left edge.
        for (self.sections.items, 0..) |s, i| {
            if (s.read_s < 3) continue;
            const end = if (i + 1 < self.sections.items.len) self.sections.items[i + 1].y else self.content_h;
            const ya = my + (s.y - v.top) * v.scale;
            const yb = my + (end - v.top) * v.scale;
            cv.fillRect(.{ .x = mr.x + 2, .y = @intFromFloat(ya), .w = 3, .h = @max(2, @as(i32, @intFromFloat(yb - ya))) }, theme.get(.footprint).fade(t));
        }

        // Viewport marker: two lines with a faint band between them.
        if (self.markers.enabled) {
            const va = my + (self.scroller.pos - v.top) * v.scale;
            const vb = my + (self.scroller.pos + page - v.top) * v.scale;
            const orange = theme.get(.viewport_marker);
            if (self.markers.viewport_band) cv.fillRect(.{ .x = mr.x + 1, .y = @intFromFloat(va), .w = mr.w - 2, .h = @intFromFloat(@max(1, vb - va)) }, orange.withAlpha(28).fade(t));
            cv.fillRect(.{ .x = mr.x + 1, .y = @intFromFloat(va), .w = mr.w - 2, .h = 1 }, orange.fade(t));
            cv.fillRect(.{ .x = mr.x + 1, .y = @intFromFloat(vb), .w = mr.w - 2, .h = 1 }, orange.fade(t));
            const cy = my + (self.scroller.pos + page / 2 - v.top) * v.scale;
            const green = theme.get(.center_marker).fade(t);
            cv.fillRect(.{ .x = mr.x + 1, .y = @intFromFloat(cy), .w = mr.w - 7, .h = 1 }, green);
            cv.triangleRight(@floatFromInt(mr.right() - 1), cy + 0.5, 5, green);
        }

        return if (over) v.doc_y else null;
    }

    fn drawMagnifier(self: *DocView, cv: *Canvas, theme: *const Theme, doc_y: f32, now: i64) void {
        const r = self.rect;
        const mr = self.mapRect(now);
        const content_w: f32 = @floatFromInt(r.w - gutter - map_w);
        const w: i32 = @intFromFloat(@min(content_w * 0.66, 520));
        const header: i32 = 20;
        const body_h: i32 = @intFromFloat(self.line_h * 6);
        const h = header + body_h;
        var box = Rect{ .x = mr.x - w - 8, .y = @as(i32, @intFromFloat(self.py)) - @divTrunc(h, 2), .w = w, .h = h };
        box = box.clampInto(r.inset(4));

        cv.fillRoundRect(box.translate(0, 3), 8, theme.get(.shadow));
        cv.fillRoundRect(box, 8, theme.get(.surface));
        cv.strokeRoundRect(box, 8, 0, theme.get(.border));

        // Section title, small, at the top.
        const title = if (self.sectionAt(doc_y)) |s| self.blocks[s.block].text else "";
        _ = cv.textEllipsis(@floatFromInt(box.x + 12), @floatFromInt(box.y + 4), title, @floatFromInt(box.w - 24), small_semibold, theme.get(.text_dim));
        cv.hairlineH(box.x + 8, box.y + header, box.w - 16, theme.get(.hairline));

        const inner = Rect{ .x = box.x + 1, .y = box.y + header + 1, .w = box.w - 2, .h = body_h - 2 };
        const c2 = cv.pushClip(inner);
        defer cv.popClip(c2);
        const center_y: f32 = @floatFromInt(inner.y + @divTrunc(inner.h, 2));
        // Center the whole line under the pointer, so no line is cut in half.
        const anchor = if (self.lineAt(doc_y)) |i| self.lines.items[i].y + self.lines.items[i].h / 2 else doc_y;
        const oy = center_y - anchor;
        self.drawLines(cv, theme, doc_y - @as(f32, @floatFromInt(body_h)), doc_y + @as(f32, @floatFromInt(body_h)), @floatFromInt(box.x + 14), oy);
        // Which line a click lands on.
        cv.fillRect(.{ .x = box.x + 4, .y = @intFromFloat(center_y - self.line_h / 2), .w = 2, .h = @intFromFloat(self.line_h) }, theme.get(.accent));
    }
};
