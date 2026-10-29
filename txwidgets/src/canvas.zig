//! CPU rasterizer into a 32-bit ARGB pixel buffer, or a recorder of the
//! same drawing into a draw list (draw_list.zig) for the GPU renderer.
//!
//! Every drawing call takes logical coordinates; the canvas multiplies by
//! its integer scale. `hairline*` calls draw one physical pixel, which is
//! half a logical pixel at 2× (Look and Controls, Borders).
//!
//! Each call is reduced to a few physical-pixel primitives (`Op`) that go
//! through `emit`: rasterized at once, or recorded with the current clip.
//! Replaying a recording rasterizes the same primitives with the same code,
//! so a recorded frame drawn on the CPU is identical to one drawn directly.
//!
//! Open question (Widget Framework): own rasterizer or a library (pixman,
//! Cairo, a pure-Zig 2D library). This one covers what v0 needs.

const std = @import("std");
const core = @import("txcore");
const font = @import("font.zig");
const bidi = @import("bidi.zig");
const draw_list = @import("draw_list.zig");

const Rect = core.Rect;
const Color = core.Color;
pub const DrawList = draw_list.DrawList;
pub const Op = draw_list.Op;
pub const Image = draw_list.Image;

pub const Canvas = struct {
    pixels: []u32,
    /// Physical size.
    width: i32,
    height: i32,
    stride: i32,
    scale: i32,
    /// Physical clip rect.
    clip: Rect,
    /// Logical translation applied to every call.
    ox: i32 = 0,
    oy: i32 = 0,
    /// Recording: drawing calls append to this list instead of touching
    /// `pixels` (which is empty).
    list: ?*DrawList = null,

    pub fn init(pixels: []u32, width: i32, height: i32, stride: i32, scale: i32) Canvas {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = stride,
            .scale = scale,
            .clip = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }

    /// A canvas of the given physical size that records into `list`.
    pub fn recorder(list: *DrawList, width: i32, height: i32, scale: i32) Canvas {
        var cv = init(&.{}, width, height, width, scale);
        cv.list = list;
        return cv;
    }

    pub fn recording(self: *const Canvas) bool {
        return self.list != null;
    }

    fn emit(self: *Canvas, op: Op, c: Color) void {
        if (self.list) |l| {
            l.add(.{ .clip = self.clip, .color = c, .op = op });
            return;
        }
        self.exec(op, c);
    }

    fn exec(self: *Canvas, op: Op, c: Color) void {
        switch (op) {
            .fill => |r| self.rasterFill(r, c),
            .round => |o| if (o.stroke > 0) self.rasterRoundStroke(o.r, o.rad, o.stroke, c) else self.rasterRoundFill(o.r, o.rad, c),
            .circle => |o| self.rasterCircle(o.cx, o.cy, o.r, c),
            .line => |o| self.rasterLine(o.x0, o.y0, o.x1, o.y1, o.hw, c),
            .glyph => |o| self.glyphMask(o.x, o.y, o.glyph, c),
            .image => |o| if (o.blend) self.rasterImageAlpha(o.img, o.dst, o.alpha) else if (o.exact) self.rasterBlit(o.img, o.dst.x, o.dst.y) else self.rasterBlitScaled(o.img, o.dst, o.alpha),
        }
    }

    /// Draws a recording into this (pixel) canvas, each primitive under
    /// its recorded clip.
    pub fn replay(self: *Canvas, list: *const DrawList) void {
        std.debug.assert(self.list == null);
        const old = self.clip;
        defer self.clip = old;
        for (list.cmds.items) |cmd| {
            self.clip = cmd.clip.intersect(old);
            if (self.clip.isEmpty()) continue;
            self.exec(cmd.op, cmd.color);
        }
    }

    pub fn logicalWidth(self: *const Canvas) i32 {
        return @divTrunc(self.width, self.scale);
    }
    pub fn logicalHeight(self: *const Canvas) i32 {
        return @divTrunc(self.height, self.scale);
    }

    fn phys(self: *const Canvas, r: Rect) Rect {
        return .{
            .x = (r.x + self.ox) * self.scale,
            .y = (r.y + self.oy) * self.scale,
            .w = r.w * self.scale,
            .h = r.h * self.scale,
        };
    }

    /// Narrows the clip to a logical rect; returns the previous clip.
    pub fn pushClip(self: *Canvas, r: Rect) Rect {
        const old = self.clip;
        self.clip = self.clip.intersect(self.phys(r));
        return old;
    }
    pub fn popClip(self: *Canvas, old: Rect) void {
        self.clip = old;
    }

    inline fn blendPixel(self: *Canvas, x: i32, y: i32, c: Color, coverage: u8) void {
        if (x < self.clip.x or y < self.clip.y or x >= self.clip.right() or y >= self.clip.bottom()) return;
        const a: u32 = (@as(u32, c.a) * coverage + 127) / 255;
        if (a == 0) return;
        const idx: usize = @intCast(y * self.stride + x);
        if (a == 255) {
            self.pixels[idx] = c.toU32() | 0xFF000000;
            return;
        }
        self.pixels[idx] = blend(self.pixels[idx], c, a);
    }

    fn blend(dst: u32, c: Color, a: u32) u32 {
        const inv = 255 - a;
        const dr = (dst >> 16) & 0xFF;
        const dg = (dst >> 8) & 0xFF;
        const db = dst & 0xFF;
        const r = (@as(u32, c.r) * a + dr * inv + 127) / 255;
        const g = (@as(u32, c.g) * a + dg * inv + 127) / 255;
        const b = (@as(u32, c.b) * a + db * inv + 127) / 255;
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    fn fillPhys(self: *Canvas, pr: Rect, c: Color) void {
        if (pr.intersect(self.clip).isEmpty() or c.a == 0) return;
        self.emit(.{ .fill = pr }, c);
    }

    fn rasterFill(self: *Canvas, pr: Rect, c: Color) void {
        const r = pr.intersect(self.clip);
        if (r.isEmpty() or c.a == 0) return;
        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            const row: usize = @intCast(y * self.stride);
            const span = self.pixels[row + @as(usize, @intCast(r.x)) ..][0..@intCast(r.w)];
            if (c.a == 255) {
                @memset(span, c.toU32());
            } else {
                for (span) |*p| p.* = blend(p.*, c, c.a);
            }
        }
    }

    pub fn clear(self: *Canvas, c: Color) void {
        self.fillPhys(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, c.withAlpha(255));
    }

    pub fn fillRect(self: *Canvas, r: Rect, c: Color) void {
        self.fillPhys(self.phys(r), c);
    }

    /// A 1-physical-pixel line along the top or left edge of a logical rect.
    pub fn hairlineH(self: *Canvas, x: i32, y: i32, w: i32, c: Color) void {
        const p = self.phys(.{ .x = x, .y = y, .w = w, .h = 1 });
        self.fillPhys(.{ .x = p.x, .y = p.y, .w = p.w, .h = 1 }, c);
    }
    pub fn hairlineV(self: *Canvas, x: i32, y: i32, h: i32, c: Color) void {
        const p = self.phys(.{ .x = x, .y = y, .w = 1, .h = h });
        self.fillPhys(.{ .x = p.x, .y = p.y, .w = 1, .h = p.h }, c);
    }
    /// Hairline on the bottom/right physical pixel of a logical row/column.
    pub fn hairlineHBottom(self: *Canvas, x: i32, y: i32, w: i32, c: Color) void {
        const p = self.phys(.{ .x = x, .y = y, .w = w, .h = 1 });
        self.fillPhys(.{ .x = p.x, .y = p.y + self.scale - 1, .w = p.w, .h = 1 }, c);
    }
    pub fn hairlineVRight(self: *Canvas, x: i32, y: i32, h: i32, c: Color) void {
        const p = self.phys(.{ .x = x, .y = y, .w = 1, .h = h });
        self.fillPhys(.{ .x = p.x + self.scale - 1, .y = p.y, .w = 1, .h = p.h }, c);
    }

    /// Hairline outline of a logical rect.
    pub fn hairlineRect(self: *Canvas, r: Rect, c: Color) void {
        self.hairlineH(r.x, r.y, r.w, c);
        self.hairlineHBottom(r.x, r.bottom() - 1, r.w, c);
        self.hairlineV(r.x, r.y, r.h, c);
        self.hairlineVRight(r.right() - 1, r.y, r.h, c);
    }

    pub fn strokeRect(self: *Canvas, r: Rect, t: i32, c: Color) void {
        self.fillRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = t }, c);
        self.fillRect(.{ .x = r.x, .y = r.bottom() - t, .w = r.w, .h = t }, c);
        self.fillRect(.{ .x = r.x, .y = r.y + t, .w = t, .h = r.h - 2 * t }, c);
        self.fillRect(.{ .x = r.right() - t, .y = r.y + t, .w = t, .h = r.h - 2 * t }, c);
    }

    /// Dashed horizontal line, `t` logical px thick (error state: shape as
    /// well as red).
    pub fn dashedH(self: *Canvas, x: i32, y: i32, w: i32, t: i32, dash: i32, gap: i32, c: Color) void {
        var px = x;
        while (px < x + w) : (px += dash + gap) {
            self.fillRect(.{ .x = px, .y = y, .w = @min(dash, x + w - px), .h = t }, c);
        }
    }

    /// Dashed vertical line.
    pub fn dashedV(self: *Canvas, x: i32, y: i32, h: i32, t: i32, dash: i32, gap: i32, c: Color) void {
        var py = y;
        while (py < y + h) : (py += dash + gap) {
            self.fillRect(.{ .x = x, .y = py, .w = t, .h = @min(dash, y + h - py) }, c);
        }
    }

    /// Dashed outline of a rect (a ghost: shape as well as faded color).
    pub fn dashedRect(self: *Canvas, r: Rect, t: i32, dash: i32, gap: i32, c: Color) void {
        self.dashedH(r.x, r.y, r.w, t, dash, gap, c);
        self.dashedH(r.x, r.bottom() - t, r.w, t, dash, gap, c);
        self.dashedV(r.x, r.y, r.h, t, dash, gap, c);
        self.dashedV(r.right() - t, r.y, r.h, t, dash, gap, c);
    }

    // ------------------------------------------------ anti-aliased shapes

    fn cov(d: f32) u8 {
        // d: signed distance in physical px, negative inside.
        const v = std.math.clamp(0.5 - d, 0, 1);
        return @intFromFloat(@round(v * 255));
    }

    fn roundRectDist(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32, rad: f32) f32 {
        const cx = (x0 + x1) / 2;
        const cy = (y0 + y1) / 2;
        const hx = (x1 - x0) / 2 - rad;
        const hy = (y1 - y0) / 2 - rad;
        const qx = @abs(px - cx) - hx;
        const qy = @abs(py - cy) - hy;
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
    }

    /// Filled rounded rect with anti-aliased corners. Interior rows are
    /// filled as spans; only the corner bands are shaded per pixel.
    pub fn fillRoundRect(self: *Canvas, r: Rect, radius: f32, c: Color) void {
        if (r.isEmpty()) return;
        const p = self.phys(r);
        const s: f32 = @floatFromInt(self.scale);
        const rad = @min(radius * s, @as(f32, @floatFromInt(@min(p.w, p.h))) / 2);
        if (p.intersect(self.clip).isEmpty()) return;
        self.emit(.{ .round = .{ .r = p, .rad = rad, .stroke = 0 } }, c);
    }

    fn rasterRoundFill(self: *Canvas, p: Rect, rad: f32, c: Color) void {
        const band: i32 = @intFromFloat(@ceil(rad));
        // Middle band: plain fill.
        self.rasterFill(.{ .x = p.x, .y = p.y + band, .w = p.w, .h = p.h - 2 * band }, c);
        const x0: f32 = @floatFromInt(p.x);
        const y0: f32 = @floatFromInt(p.y);
        const x1: f32 = @floatFromInt(p.right());
        const y1: f32 = @floatFromInt(p.bottom());
        var y = p.y;
        while (y < p.bottom()) : (y += 1) {
            if (y >= p.y + band and y < p.bottom() - band) continue;
            var x = p.x;
            while (x < p.right()) : (x += 1) {
                if (x >= p.x + band and x < p.right() - band) {
                    self.blendPixel(x, y, c, 255);
                    continue;
                }
                const d = roundRectDist(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, x0, y0, x1, y1, rad);
                self.blendPixel(x, y, c, cov(d));
            }
        }
    }

    /// Rounded outline, `t` logical px wide (use t <= 0 for a hairline).
    pub fn strokeRoundRect(self: *Canvas, r: Rect, radius: f32, t: f32, c: Color) void {
        if (r.isEmpty()) return;
        const p = self.phys(r);
        const s: f32 = @floatFromInt(self.scale);
        const w: f32 = if (t <= 0) 1 else t * s;
        const rad = @min(radius * s, @as(f32, @floatFromInt(@min(p.w, p.h))) / 2);
        if (p.intersect(self.clip).isEmpty()) return;
        self.emit(.{ .round = .{ .r = p, .rad = rad, .stroke = w } }, c);
    }

    fn rasterRoundStroke(self: *Canvas, p: Rect, rad: f32, w: f32, c: Color) void {
        const band: i32 = @as(i32, @intFromFloat(@ceil(@max(rad, w)))) + 1;
        const x0: f32 = @floatFromInt(p.x);
        const y0: f32 = @floatFromInt(p.y);
        const x1: f32 = @floatFromInt(p.right());
        const y1: f32 = @floatFromInt(p.bottom());
        var y = p.y;
        while (y < p.bottom()) : (y += 1) {
            const edge_row = y < p.y + band or y >= p.bottom() - band;
            var x = p.x;
            while (x < p.right()) : (x += 1) {
                if (!edge_row and x >= p.x + band and x < p.right() - band) {
                    x = p.right() - band - 1;
                    continue;
                }
                const d = roundRectDist(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, x0, y0, x1, y1, rad);
                const outer = std.math.clamp(0.5 - d, 0, 1);
                const inner = std.math.clamp(0.5 - (d + w), 0, 1);
                const v = outer - inner;
                if (v > 0) self.blendPixel(x, y, c, @intFromFloat(@round(v * 255)));
            }
        }
    }

    pub fn fillCircle(self: *Canvas, cx: f32, cy: f32, radius: f32, c: Color) void {
        const s: f32 = @floatFromInt(self.scale);
        const pcx = (cx + @as(f32, @floatFromInt(self.ox))) * s;
        const pcy = (cy + @as(f32, @floatFromInt(self.oy))) * s;
        self.emit(.{ .circle = .{ .cx = pcx, .cy = pcy, .r = radius * s } }, c);
    }

    fn rasterCircle(self: *Canvas, pcx: f32, pcy: f32, pr: f32, c: Color) void {
        const x0: i32 = @intFromFloat(@floor(pcx - pr - 1));
        const x1: i32 = @intFromFloat(@ceil(pcx + pr + 1));
        const y0: i32 = @intFromFloat(@floor(pcy - pr - 1));
        const y1: i32 = @intFromFloat(@ceil(pcy + pr + 1));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - pcx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - pcy;
                self.blendPixel(x, y, c, cov(@sqrt(dx * dx + dy * dy) - pr));
            }
        }
    }

    /// Anti-aliased line segment with round caps, width in logical px.
    pub fn line(self: *Canvas, ax: f32, ay: f32, bx: f32, by: f32, width: f32, c: Color) void {
        const s: f32 = @floatFromInt(self.scale);
        const ox: f32 = @floatFromInt(self.ox);
        const oy: f32 = @floatFromInt(self.oy);
        const x0 = (ax + ox) * s;
        const y0 = (ay + oy) * s;
        const x1 = (bx + ox) * s;
        const y1 = (by + oy) * s;
        self.emit(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .hw = width * s / 2 } }, c);
    }

    fn rasterLine(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, hw: f32, c: Color) void {
        const minx: i32 = @intFromFloat(@floor(@min(x0, x1) - hw - 1));
        const maxx: i32 = @intFromFloat(@ceil(@max(x0, x1) + hw + 1));
        const miny: i32 = @intFromFloat(@floor(@min(y0, y1) - hw - 1));
        const maxy: i32 = @intFromFloat(@ceil(@max(y0, y1) + hw + 1));
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = @max(dx * dx + dy * dy, 0.0001);
        var y = miny;
        while (y < maxy) : (y += 1) {
            var x = minx;
            while (x < maxx) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const t = std.math.clamp(((px - x0) * dx + (py - y0) * dy) / len2, 0, 1);
                const qx = x0 + dx * t - px;
                const qy = y0 + dy * t - py;
                self.blendPixel(x, y, c, cov(@sqrt(qx * qx + qy * qy) - hw));
            }
        }
    }

    /// Small filled triangle pointing right, its tip at (x, y).
    pub fn triangleRight(self: *Canvas, x: f32, y: f32, size: f32, c: Color) void {
        var i: f32 = 0;
        const step = 0.5 / @as(f32, @floatFromInt(self.scale));
        while (i <= size) : (i += step) {
            const half = (size - i) * 0.6;
            self.line(x - size + i, y - half, x - size + i, y + half, step * 1.5, c);
        }
    }

    // ------------------------------------------------------------- text

    /// Draws text with its top at `y`, in visual order (right-to-left runs
    /// reversed, `bidi.zig`); returns the advance in logical px.
    pub fn text(self: *Canvas, x: f32, y: f32, str: []const u8, style: font.Style, c: Color) f32 {
        const atlas = font.Fonts.get().atlas(style, self.scale);
        const s: f32 = @floatFromInt(self.scale);
        var pen = (x + @as(f32, @floatFromInt(self.ox))) * s;
        const top: i32 = @intFromFloat(@round((y + @as(f32, @floatFromInt(self.oy))) * s));
        const baseline = top + atlas.ascent;
        const start = pen;
        var buf: [bidi.max]u21 = undefined;
        var visual = bidi.Line.of(str, &buf);
        while (visual.next()) |cp| {
            const g = atlas.glyph(cp);
            if (g.w > 0) {
                const gx: i32 = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
                const gy: i32 = baseline - g.bearing_y;
                self.emit(.{ .glyph = .{ .x = gx, .y = gy, .glyph = g } }, c);
            }
            pen += g.advance;
        }
        return (pen - start) / s;
    }

    fn glyphMask(self: *Canvas, gx: i32, gy: i32, g: *const font.Glyph, c: Color) void {
        const x0 = @max(gx, self.clip.x);
        const y0 = @max(gy, self.clip.y);
        const x1 = @min(gx + g.w, self.clip.right());
        const y1 = @min(gy + g.h, self.clip.bottom());
        var y = y0;
        while (y < y1) : (y += 1) {
            const row: usize = @intCast((y - gy) * @as(i32, g.w));
            var x = x0;
            while (x < x1) : (x += 1) {
                const m = g.bitmap[row + @as(usize, @intCast(x - gx))];
                if (m != 0) self.blendPixel(x, y, c, m);
            }
        }
    }

    /// Text cut to `max_w` with an ellipsis at the (logical) end: on the
    /// right, or on the left in right-to-left text.
    pub fn textEllipsis(self: *Canvas, x: f32, y: f32, str: []const u8, max_w: f32, style: font.Style, c: Color) f32 {
        const m = font.Metrics.of(style, self.scale);
        if (m.width(str) <= max_w) return self.text(x, y, str, style, c);
        const ell = "\u{2026}";
        const avail = max_w - m.width(ell);
        var end: usize = 0;
        var it = font.codepoints(str);
        var w: f32 = 0;
        while (it.next()) |cp| {
            const adv = m.atlas.glyph(cp).advance / @as(f32, @floatFromInt(self.scale));
            if (w + adv > avail) break;
            w += adv;
            end = it.i;
        }
        if (bidi.Line.of(str, &.{}).rtl) {
            const e = self.text(x, y, ell, style, c);
            return e + self.text(x + e, y, str[0..end], style, c);
        }
        const a = self.text(x, y, str[0..end], style, c);
        return a + self.text(x + a, y, ell, style, c);
    }

    // -------------------------------------------------------- compositing

    /// Copies an opaque image to a physical position, clipped.
    pub fn blit(self: *Canvas, img: Image, dx: i32, dy: i32) void {
        const dst = Rect{ .x = dx, .y = dy, .w = img.w, .h = img.h };
        if (img.pixels.len == 0 or dst.intersect(self.clip).isEmpty()) return;
        self.emit(.{ .image = .{ .img = img, .dst = dst, .alpha = 255, .exact = true } }, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    }

    fn rasterBlit(self: *Canvas, img: Image, dx: i32, dy: i32) void {
        const src = img.pixels;
        const src_w = img.w;
        const dst = (Rect{ .x = dx, .y = dy, .w = img.w, .h = img.h }).intersect(self.clip);
        if (dst.isEmpty()) return;
        var y = dst.y;
        while (y < dst.bottom()) : (y += 1) {
            const sy = y - dy;
            const s_off: usize = @intCast(sy * src_w + (dst.x - dx));
            const d_off: usize = @intCast(y * self.stride + dst.x);
            const n: usize = @intCast(dst.w);
            @memcpy(self.pixels[d_off..][0..n], src[s_off..][0..n]);
        }
    }

    /// Nearest-neighbour scaled copy into a logical rect (thumbnails). The
    /// image is opaque; `alpha` fades all of it.
    pub fn blitScaled(self: *Canvas, img: Image, r: Rect, alpha: u8) void {
        if (img.w <= 0 or img.h <= 0 or img.pixels.len == 0 or alpha == 0) return;
        const p = self.phys(r);
        if (p.isEmpty() or p.intersect(self.clip).isEmpty()) return;
        self.emit(.{ .image = .{ .img = img, .dst = p, .alpha = alpha, .exact = false } }, .{ .r = 0, .g = 0, .b = 0, .a = alpha });
    }

    /// An image with its own alpha (an icon), scaled (nearest) into a
    /// logical rect and faded by `alpha`.
    pub fn drawImage(self: *Canvas, img: Image, r: Rect, alpha: u8) void {
        if (img.w <= 0 or img.h <= 0 or img.pixels.len < @as(usize, @intCast(img.w * img.h)) or alpha == 0) return;
        const p = self.phys(r);
        if (p.isEmpty() or p.intersect(self.clip).isEmpty()) return;
        self.emit(.{ .image = .{ .img = img, .dst = p, .alpha = alpha, .exact = false, .blend = true } }, .{ .r = 0, .g = 0, .b = 0, .a = alpha });
    }

    fn rasterImageAlpha(self: *Canvas, img: Image, p: Rect, alpha: u8) void {
        const d = p.intersect(self.clip);
        if (d.isEmpty()) return;
        var y = d.y;
        while (y < d.bottom()) : (y += 1) {
            const sy: i32 = @divTrunc((y - p.y) * img.h, p.h);
            var x = d.x;
            while (x < d.right()) : (x += 1) {
                const sx: i32 = @divTrunc((x - p.x) * img.w, p.w);
                const v = img.pixels[@intCast(sy * img.w + sx)];
                const a = ((v >> 24) * alpha + 127) / 255;
                if (a == 0) continue;
                const idx: usize = @intCast(y * self.stride + x);
                self.pixels[idx] = if (a == 255) v | 0xFF000000 else blend(self.pixels[idx], @bitCast(v), a);
            }
        }
    }

    fn rasterBlitScaled(self: *Canvas, img: Image, p: Rect, alpha: u8) void {
        const src = img.pixels;
        const src_w = img.w;
        const src_h = img.h;
        const d = p.intersect(self.clip);
        if (d.isEmpty()) return;
        var y = d.y;
        while (y < d.bottom()) : (y += 1) {
            const sy: i32 = @divTrunc((y - p.y) * src_h, p.h);
            var x = d.x;
            while (x < d.right()) : (x += 1) {
                const sx: i32 = @divTrunc((x - p.x) * src_w, p.w);
                const v = src[@intCast(sy * src_w + sx)];
                const idx: usize = @intCast(y * self.stride + x);
                if (alpha == 255) self.pixels[idx] = v else self.pixels[idx] = blend(self.pixels[idx], @bitCast(v), alpha);
            }
        }
    }
};

test "fill, clip and blend" {
    var px: [16]u32 = @splat(0xFF000000);
    var cv = Canvas.init(&px, 4, 4, 4, 1);
    const old = cv.pushClip(.{ .x = 0, .y = 0, .w = 2, .h = 4 });
    cv.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, Color.rgb(0xFFFFFF));
    cv.popClip(old);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2]);
    cv.fillRect(.{ .x = 0, .y = 1, .w = 1, .h = 1 }, Color.rgba(0xFFFFFF, 128));
    try std.testing.expectEqual(@as(u32, 0xFF808080), px[4]);
}

test "text draws something" {
    var px: [64 * 32]u32 = @splat(0xFFFFFFFF);
    var cv = Canvas.init(&px, 64, 32, 64, 1);
    const w = cv.text(2, 2, "Hi", .{}, Color.rgb(0x000000));
    try std.testing.expect(w > 5);
    var dark: usize = 0;
    for (px) |p| {
        if (p != 0xFFFFFFFF) dark += 1;
    }
    try std.testing.expect(dark > 10);
}
