//! App icons for the desktop: txdesk draws each installed app's icon file
//! (from its desktop entry, resolved by the scanner) as pixels at the sizes
//! the desktop uses, and keeps them in icons.krkde (txcore/src/icons.zig).
//! The compositor reads the pixels; it never decodes an image file, which
//! comes from packages Kuroko does not control.
//!
//!   PNG: decoded here (every color type and depth; interlaced files are
//!        skipped and the app keeps its letter tile).
//!   SVG: drawn by rsvg-convert (librsvg, installed by setup.sh) to a PNG.
//!
//! Each icon is fitted into a square, centered, with good scaling (an area
//! average when shrinking, bilinear when growing, on premultiplied colors
//! so edges never get dark fringes).

const std = @import("std");
const core = @import("txcore");
const store_mod = @import("apps/store.zig");
const flate = std.compress.flate;

pub const Image = struct {
    w: u32,
    h: u32,
    /// 0xAARRGGBB, straight alpha.
    pixels: []u32,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

const max_side = 4096;

// ---------------------------------------------------------------- PNG

pub fn decodePng(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    const sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len < sig.len or !std.mem.eql(u8, bytes[0..sig.len], sig)) return error.NotPng;
    var pos: usize = sig.len;
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    var key: ?[3]u16 = null; // tRNS for gray and RGB
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var have_header = false;

    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (len > bytes.len - pos - 12) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadPng;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            if (data[12] != 0) return error.Interlaced;
            if (w == 0 or h == 0 or w > max_side or h > max_side) return error.BadSize;
            const ok = switch (color) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                2, 4, 6 => depth == 8 or depth == 16,
                else => false,
            };
            if (!ok) return error.BadPng;
            have_header = true;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = @min(256, len / 3);
            for (0..palette_len) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                3 => for (data[0..@min(len, 256)], 0..) |a, i| {
                    palette[i][3] = a;
                },
                0 => if (len >= 2) {
                    const g = std.mem.readInt(u16, data[0..2], .big);
                    key = .{ g, g, g };
                },
                2 => if (len >= 6) {
                    key = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (!have_header) return error.BadPng;
    if (color == 3 and palette_len == 0) return error.BadPng;

    const channels: u32 = switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        else => 4,
    };
    const bits = channels * depth;
    const stride: usize = (@as(usize, w) * bits + 7) / 8;
    const bpp: usize = @max(1, bits / 8);
    const need = (stride + 1) * h;

    var in: std.Io.Reader = .fixed(idat.items);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, .zlib, &window);
    const raw = dec.reader.allocRemaining(gpa, .limited(need + 1)) catch return error.BadData;
    defer gpa.free(raw);
    if (raw.len < need) return error.BadData;

    // Undo the row filters in place.
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const ft = raw[y * (stride + 1)];
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) raw[(y - 1) * (stride + 1) + 1 ..][0..stride] else null;
        for (row, 0..) |*b, i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            b.* +%= switch (ft) {
                0 => 0,
                1 => a,
                2 => up,
                3 => @intCast((@as(u16, a) + up) / 2),
                4 => paeth(a, up, c),
                else => return error.BadFilter,
            };
        }
    }

    const px = try gpa.alloc(u32, @as(usize, w) * h);
    errdefer gpa.free(px);
    const max_v: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
    y = 0;
    while (y < h) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var rgba: [4]u8 = .{ 0, 0, 0, 255 };
            switch (color) {
                3 => rgba = palette[sample(row, x, 0, 1, depth)],
                0 => {
                    const v = sample(row, x, 0, 1, depth);
                    const g: u8 = @intCast(if (depth == 16) v >> 8 else v * 255 / max_v);
                    rgba = .{ g, g, g, 255 };
                    if (key) |k| if (v == k[0]) {
                        rgba[3] = 0;
                    };
                },
                2 => {
                    const r = sample(row, x, 0, 3, depth);
                    const g = sample(row, x, 1, 3, depth);
                    const b = sample(row, x, 2, 3, depth);
                    rgba = .{ to8(r, depth), to8(g, depth), to8(b, depth), 255 };
                    if (key) |k| if (r == k[0] and g == k[1] and b == k[2]) {
                        rgba[3] = 0;
                    };
                },
                4 => {
                    const g = to8(sample(row, x, 0, 2, depth), depth);
                    rgba = .{ g, g, g, to8(sample(row, x, 1, 2, depth), depth) };
                },
                else => rgba = .{
                    to8(sample(row, x, 0, 4, depth), depth),
                    to8(sample(row, x, 1, 4, depth), depth),
                    to8(sample(row, x, 2, 4, depth), depth),
                    to8(sample(row, x, 3, 4, depth), depth),
                },
            }
            px[y * w + x] = pack(rgba);
        }
    }
    return .{ .w = w, .h = h, .pixels = px };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Channel `ch` of pixel `x` in a row, as stored (up to 16 bits).
fn sample(row: []const u8, x: usize, ch: usize, channels: usize, depth: u8) u32 {
    switch (depth) {
        16 => {
            const i = (x * channels + ch) * 2;
            return std.mem.readInt(u16, row[i..][0..2], .big);
        },
        8 => return row[x * channels + ch],
        else => {
            // Packed, first pixel in the high bits.
            const bit = x * depth;
            const byte = row[bit / 8];
            const shift: u3 = @intCast(8 - depth - bit % 8);
            return (byte >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
        },
    }
}

fn to8(v: u32, depth: u8) u8 {
    return @intCast(if (depth == 16) v >> 8 else v);
}

fn pack(c: [4]u8) u32 {
    return (@as(u32, c[3]) << 24) | (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
}

// ------------------------------------------------------------- scaling

/// The image fitted into a `size` x `size` square, centered, the rest
/// transparent.
pub fn toSquare(gpa: std.mem.Allocator, img: Image, size: u32) ![]u32 {
    const out = try gpa.alloc(u32, size * size);
    @memset(out, 0);
    const k = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(@max(img.w, img.h)));
    const tw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.w)) * k))));
    const th: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.h)) * k))));
    const ox = (size - @min(size, tw)) / 2;
    const oy = (size - @min(size, th)) / 2;
    const sx = @as(f32, @floatFromInt(img.w)) / @as(f32, @floatFromInt(tw));
    const sy = @as(f32, @floatFromInt(img.h)) / @as(f32, @floatFromInt(th));
    var y: u32 = 0;
    while (y < th and y + oy < size) : (y += 1) {
        var x: u32 = 0;
        while (x < tw and x + ox < size) : (x += 1) {
            const v = if (sx > 1 or sy > 1)
                areaAverage(img, @as(f32, @floatFromInt(x)) * sx, @as(f32, @floatFromInt(y)) * sy, sx, sy)
            else
                bilinear(img, (@as(f32, @floatFromInt(x)) + 0.5) * sx - 0.5, (@as(f32, @floatFromInt(y)) + 0.5) * sy - 0.5);
            out[(y + oy) * size + x + ox] = v;
        }
    }
    return out;
}

/// Premultiplied channels of a pixel, 0..1.
fn premul(p: u32) [4]f32 {
    const a = @as(f32, @floatFromInt(p >> 24)) / 255;
    return .{
        @as(f32, @floatFromInt((p >> 16) & 0xff)) / 255 * a,
        @as(f32, @floatFromInt((p >> 8) & 0xff)) / 255 * a,
        @as(f32, @floatFromInt(p & 0xff)) / 255 * a,
        a,
    };
}

fn unpremul(c: [4]f32) u32 {
    if (c[3] <= 0.0001) return 0;
    const q = struct {
        fn ch(v: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.ch;
    return (q(c[3]) << 24) | (q(c[0] / c[3]) << 16) | (q(c[1] / c[3]) << 8) | q(c[2] / c[3]);
}

/// The average over the source area [x0, x0+w) x [y0, y0+h).
fn areaAverage(img: Image, x0: f32, y0: f32, w: f32, h: f32) u32 {
    var acc: [4]f32 = @splat(0);
    var total: f32 = 0;
    var yy: u32 = @intFromFloat(@floor(y0));
    while (@as(f32, @floatFromInt(yy)) < y0 + h and yy < img.h) : (yy += 1) {
        const fy0 = @max(y0, @as(f32, @floatFromInt(yy)));
        const fy1 = @min(y0 + h, @as(f32, @floatFromInt(yy + 1)));
        var xx: u32 = @intFromFloat(@floor(x0));
        while (@as(f32, @floatFromInt(xx)) < x0 + w and xx < img.w) : (xx += 1) {
            const fx0 = @max(x0, @as(f32, @floatFromInt(xx)));
            const fx1 = @min(x0 + w, @as(f32, @floatFromInt(xx + 1)));
            const wt = (fx1 - fx0) * (fy1 - fy0);
            if (wt <= 0) continue;
            const c = premul(img.pixels[yy * img.w + xx]);
            for (&acc, c) |*s, v| s.* += v * wt;
            total += wt;
        }
    }
    if (total <= 0) return 0;
    for (&acc) |*s| s.* /= total;
    return unpremul(acc);
}

fn bilinear(img: Image, fx: f32, fy: f32) u32 {
    const x = std.math.clamp(fx, 0, @as(f32, @floatFromInt(img.w - 1)));
    const y = std.math.clamp(fy, 0, @as(f32, @floatFromInt(img.h - 1)));
    const x0: u32 = @intFromFloat(@floor(x));
    const y0: u32 = @intFromFloat(@floor(y));
    const x1 = @min(x0 + 1, img.w - 1);
    const y1 = @min(y0 + 1, img.h - 1);
    const tx = x - @as(f32, @floatFromInt(x0));
    const ty = y - @as(f32, @floatFromInt(y0));
    const a = premul(img.pixels[y0 * img.w + x0]);
    const b = premul(img.pixels[y0 * img.w + x1]);
    const c = premul(img.pixels[y1 * img.w + x0]);
    const d = premul(img.pixels[y1 * img.w + x1]);
    var out: [4]f32 = undefined;
    for (&out, 0..) |*o, i| o.* = (a[i] * (1 - tx) + b[i] * tx) * (1 - ty) + (c[i] * (1 - tx) + d[i] * tx) * ty;
    return unpremul(out);
}

// --------------------------------------------------------------- files

const rsvg = "/usr/bin/rsvg-convert";

/// An icon file as pixels, `size` wide for an SVG.
fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, size: u32) !Image {
    if (std.mem.endsWith(u8, path, ".svg") or std.mem.endsWith(u8, path, ".svgz")) {
        std.Io.Dir.accessAbsolute(io, rsvg, .{}) catch return error.NoSvgRenderer;
        var sbuf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&sbuf, "{d}", .{size});
        const res = try std.process.run(gpa, io, .{ .argv = &.{ rsvg, "--keep-aspect-ratio", "-w", s, "-h", s, path }, .stdout_limit = .limited(16 * 1024 * 1024) });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        return decodePng(gpa, res.stdout);
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    return decodePng(gpa, bytes);
}

fn mtimeOf(io: std.Io, path: []const u8) i64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @intCast(st.mtime.nanoseconds);
}

/// Draws the icons of installed apps that are new or whose icon file
/// changed; keeps the rest. Returns true when the set changed.
pub fn refresh(gpa: std.mem.Allocator, io: std.Io, set: *core.icons.Set, apps: []const store_mod.App) !bool {
    var next = core.icons.Set.init(gpa);
    errdefer next.deinit();
    var changed = false;
    for (apps) |a| {
        if (a.status != .installed or a.icon.len == 0 or a.binary.len == 0) continue;
        const mtime = mtimeOf(io, a.icon);
        if (mtime == 0) continue;
        // Unchanged: keep what was drawn.
        var kept: usize = 0;
        for (set.icons.items) |ic| {
            if (!std.mem.eql(u8, ic.key, a.binary) or ic.source_mtime_ns != mtime) continue;
            const key = try gpa.dupe(u8, ic.key);
            errdefer gpa.free(key);
            const px = try gpa.dupe(u32, ic.pixels);
            errdefer gpa.free(px);
            try next.icons.append(gpa, .{ .key = key, .w = ic.w, .h = ic.h, .source_mtime_ns = mtime, .pixels = px });
            kept += 1;
        }
        if (kept == core.icons.sizes.len) continue;
        // Drop a partial set, draw both sizes again.
        while (kept > 0) : (kept -= 1) {
            const ic = next.icons.pop().?;
            gpa.free(ic.key);
            gpa.free(ic.pixels);
        }
        changed = true;
        for (core.icons.sizes) |size| {
            const img = load(gpa, io, a.icon, size) catch continue;
            defer img.deinit(gpa);
            const px = try toSquare(gpa, img, size);
            errdefer gpa.free(px);
            const key = try gpa.dupe(u8, a.binary);
            errdefer gpa.free(key);
            try next.icons.append(gpa, .{ .key = key, .w = size, .h = size, .source_mtime_ns = mtime, .pixels = px });
        }
    }
    if (next.icons.items.len != set.icons.items.len) changed = true;
    set.deinit();
    set.* = next;
    return changed;
}

pub fn encode(gpa: std.mem.Allocator, set: *const core.icons.Set) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (set.icons.items) |ic| try core.icons.append(gpa, &out, ic);
    return out.toOwnedSlice(gpa);
}

// --------------------------------------------------------------- tests

const testing = std.testing;

// Made with zlib in Python; each uses different row filters.
const rgba_3x3 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x08, 0x06, 0x00, 0x00, 0x00, 0x56, 0x28, 0xb5, 0xbf, 0x00, 0x00, 0x00, 0x2f, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xfc, 0xcf, 0xc0, 0xf0, 0x9f, 0xf1, 0x3f, 0x43, 0x23, 0x03, 0xe3, 0xff, 0x06, 0x26, 0x6e, 0x11, 0x39, 0x4d, 0x23, 0x5b, 0xb7, 0x0b, 0x51, 0x29, 0xf9, 0x15, 0x2c, 0xfb, 0xb6, 0xae, 0x59, 0x6c, 0x09, 0x04, 0x27, 0x5c, 0x0e, 0xae, 0x07, 0x00, 0x0b, 0xcc, 0x0e, 0xb9, 0x0f, 0x86, 0x0d, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const gray_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xdd, 0x52, 0xf8, 0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x66, 0xf8, 0xcf, 0xd0, 0xe0, 0x00, 0x00, 0x05, 0x54, 0x01, 0xc3, 0x19, 0x21, 0x72, 0xed, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const pal_3x1 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00, 0x66, 0x8e, 0xfc, 0x27, 0x00, 0x00, 0x00, 0x09, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0x2d, 0x4a, 0xcd, 0x8a, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0xff, 0x80, 0x08, 0x0f, 0xb3, 0x6a, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x90, 0x00, 0x00, 0x00, 0x1a, 0x00, 0x19, 0x2d, 0x88, 0xf4, 0x36, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
const rgb16_1x1 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x02, 0x00, 0x00, 0x00, 0xc0, 0xe7, 0x8f, 0x9d, 0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x10, 0x32, 0x59, 0x7d, 0xf6, 0xff, 0x7f, 0x00, 0x09, 0x87, 0x03, 0xbd, 0xe5, 0x0c, 0x77, 0x05, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };

test "PNG: RGBA with Sub, Up and Paeth rows" {
    const img = try decodePng(testing.allocator, &rgba_3x3);
    defer img.deinit(testing.allocator);
    const want = [_]u32{ 0xFFFF0000, 0x8000FF00, 0x000000FF, 0x280A141E, 0x50323C46, 0x785A646E, 0xCBC8C9CA, 0x04010203, 0xFFFA8007 };
    try testing.expectEqualSlices(u32, &want, img.pixels);
}

test "PNG: gray with an Average row, palette with transparency, 16 bits" {
    const g = try decodePng(testing.allocator, &gray_2x2);
    defer g.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFF404040 }, g.pixels);
    const p = try decodePng(testing.allocator, &pal_3x1);
    defer p.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0xFFFF0000, 0x8000FF00, 0xFF0000FF }, p.pixels);
    const d = try decodePng(testing.allocator, &rgb16_1x1);
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{0xFF12ABFF}, d.pixels);
}

test "PNG: damaged files are refused, not crashed on" {
    try testing.expectError(error.NotPng, decodePng(testing.allocator, "GIF89a"));
    var cut = rgba_3x3;
    try testing.expect(std.meta.isError(decodePng(testing.allocator, cut[0..40])));
    cut[60] ^= 0xff; // inside the compressed data
    if (decodePng(testing.allocator, &cut)) |img| img.deinit(testing.allocator) else |_| {}
}

test "fitting into a square keeps the aspect and centers" {
    var px: [4 * 2]u32 = @splat(0xFFFF0000);
    const out = try toSquare(testing.allocator, .{ .w = 4, .h = 2, .pixels = &px }, 8);
    defer testing.allocator.free(out);
    // 8 wide, 4 tall, rows 2..5.
    try testing.expectEqual(@as(u32, 0), out[1 * 8 + 3]);
    try testing.expectEqual(@as(u32, 0xFFFF0000), out[2 * 8 + 0]);
    try testing.expectEqual(@as(u32, 0xFFFF0000), out[5 * 8 + 7]);
    try testing.expectEqual(@as(u32, 0), out[6 * 8 + 3]);
    // Shrinking averages: a black and white checkerboard becomes gray.
    var cb: [4]u32 = .{ 0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF000000 };
    const one = try toSquare(testing.allocator, .{ .w = 2, .h = 2, .pixels = &cb }, 1);
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(u32, 0xFF808080), one[0]);
}
