//! Pre-rendered font atlases (Inter, OFL-1.1) stored as Tesselix records.
//!
//! Stopgap until the text stack is chosen (Widget Framework, open question).
//! No shaping and no bidi yet: text is drawn glyph by glyph, left to right.
//! TODO(text): HarfBuzz/FreeType or pure Zig, UAX #9 bidi, Hebrew.

const std = @import("std");
const core = @import("txcore");
const format = core.format;
const types = core.types;

pub const Weight = enum(u1) { regular, semibold };

/// Logical sizes the UI uses. Each exists at scale 1 and 2.
pub const Size = enum(u8) {
    small = 11,
    body = 13,
    large = 15,
    title = 20,

    pub fn px(self: Size) i32 {
        return @intFromEnum(self);
    }
};

pub const Style = struct {
    size: Size = .body,
    weight: Weight = .regular,
};

const pixel_sizes = [_]u16{ 11, 13, 15, 20, 22, 26, 30, 40 };

const files = struct {
    const regular = [_][]const u8{
        @embedFile("fonts/regular-11.txf"), @embedFile("fonts/regular-13.txf"),
        @embedFile("fonts/regular-15.txf"), @embedFile("fonts/regular-20.txf"),
        @embedFile("fonts/regular-22.txf"), @embedFile("fonts/regular-26.txf"),
        @embedFile("fonts/regular-30.txf"), @embedFile("fonts/regular-40.txf"),
    };
    const semibold = [_][]const u8{
        @embedFile("fonts/semibold-11.txf"), @embedFile("fonts/semibold-13.txf"),
        @embedFile("fonts/semibold-15.txf"), @embedFile("fonts/semibold-20.txf"),
        @embedFile("fonts/semibold-22.txf"), @embedFile("fonts/semibold-26.txf"),
        @embedFile("fonts/semibold-30.txf"), @embedFile("fonts/semibold-40.txf"),
    };
};

pub const Glyph = struct {
    advance: f32, // physical px
    w: u8,
    h: u8,
    bearing_x: i8,
    bearing_y: i8,
    bitmap: []const u8,
};

const max_glyphs = 128;

pub const Atlas = struct {
    pixel_size: u16 = 0,
    ascent: i32 = 0,
    descent: i32 = 0,
    line_height: i32 = 0,
    count: usize = 0,
    codepoints: [max_glyphs]u32 = undefined,
    glyphs: [max_glyphs]Glyph = undefined,
    ascii: [95]?u8 = @splat(null),

    fn load(self: *Atlas, bytes: []const u8) !void {
        var reader = format.Reader.init(bytes, &types.known);
        const rec = reader.next() orelse return error.BadFontAtlas;
        if (rec.type_id != types.font_atlas or rec.swapped) return error.BadFontAtlas;
        const head = format.readStruct(types.FontAtlas, rec);
        const rest = format.trailing(types.FontAtlas, rec);
        const table_len = @as(usize, head.glyph_count) * @sizeOf(types.FontGlyph);
        if (head.glyph_count > max_glyphs or rest.len < table_len) return error.BadFontAtlas;
        const bitmap = rest[table_len..];

        self.pixel_size = head.pixel_size;
        self.ascent = head.ascent;
        self.descent = head.descent;
        self.line_height = head.line_height;
        self.count = head.glyph_count;
        for (0..head.glyph_count) |i| {
            var g: types.FontGlyph = undefined;
            @memcpy(std.mem.asBytes(&g), rest[i * @sizeOf(types.FontGlyph) ..][0..@sizeOf(types.FontGlyph)]);
            const size = @as(usize, g.w) * g.h;
            if (g.offset + size > bitmap.len) return error.BadFontAtlas;
            self.codepoints[i] = g.codepoint;
            self.glyphs[i] = .{
                .advance = @as(f32, @floatFromInt(g.advance)) / 64.0,
                .w = g.w,
                .h = g.h,
                .bearing_x = g.bearing_x,
                .bearing_y = g.bearing_y,
                .bitmap = bitmap[g.offset..][0..size],
            };
            if (g.codepoint >= 32 and g.codepoint < 127) self.ascii[g.codepoint - 32] = @intCast(i);
        }
    }

    pub fn glyph(self: *const Atlas, cp: u21) *const Glyph {
        if (cp >= 32 and cp < 127) {
            if (self.ascii[cp - 32]) |i| return &self.glyphs[i];
        } else {
            for (self.codepoints[0..self.count], 0..) |c, i| {
                if (c == cp) return &self.glyphs[i];
            }
        }
        return &self.glyphs[self.ascii['?' - 32].?];
    }

    /// Width of `text` in physical pixels.
    pub fn measure(self: *const Atlas, text: []const u8) f32 {
        var w: f32 = 0;
        var it = codepoints(text);
        while (it.next()) |cp| w += self.glyph(cp).advance;
        return w;
    }
};

/// Iterates UTF-8; invalid bytes become U+FFFD (drawn as '?').
pub fn codepoints(text: []const u8) CodepointIterator {
    return .{ .bytes = text };
}

pub const CodepointIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(self: *CodepointIterator) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.bytes.len) {
            self.i = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i..][0..len]) catch 0xFFFD;
        self.i += len;
        return cp;
    }
};

pub const Fonts = struct {
    atlases: [2][pixel_sizes.len]Atlas = undefined,

    var instance: Fonts = .{};
    var loaded = false;

    /// The process-wide font set, loaded on first use. Single-threaded UI.
    pub fn get() *const Fonts {
        if (!loaded) {
            for (files.regular, 0..) |bytes, i| instance.atlases[0][i].load(bytes) catch @panic("bad font atlas");
            for (files.semibold, 0..) |bytes, i| instance.atlases[1][i].load(bytes) catch @panic("bad font atlas");
            loaded = true;
        }
        return &instance;
    }

    /// The atlas for a logical style at an integer scale.
    pub fn atlas(self: *const Fonts, style: Style, scale: i32) *const Atlas {
        const want: i32 = style.size.px() * scale;
        var best: usize = 0;
        var best_d: i32 = std.math.maxInt(i32);
        for (pixel_sizes, 0..) |px, i| {
            const d: i32 = @intCast(@abs(@as(i32, px) - want));
            if (d < best_d) {
                best = i;
                best_d = d;
            }
        }
        return &self.atlases[@intFromEnum(style.weight)][best];
    }
};

/// Text metrics in logical pixels for a style at a scale.
pub const Metrics = struct {
    atlas: *const Atlas,
    scale: i32,

    pub fn of(style: Style, scale: i32) Metrics {
        return .{ .atlas = Fonts.get().atlas(style, scale), .scale = scale };
    }
    fn s(self: Metrics) f32 {
        return @floatFromInt(self.scale);
    }
    pub fn width(self: Metrics, text: []const u8) f32 {
        return self.atlas.measure(text) / self.s();
    }
    pub fn lineHeight(self: Metrics) i32 {
        return @intFromFloat(@ceil(@as(f32, @floatFromInt(self.atlas.line_height)) / self.s()));
    }
    pub fn ascent(self: Metrics) f32 {
        return @as(f32, @floatFromInt(self.atlas.ascent)) / self.s();
    }
    /// Average letter width: the `lt` unit (Look and Controls, Size).
    pub fn letterWidth(self: Metrics) f32 {
        return self.width("abcdefghijklmnopqrstuvwxyz") / 26.0;
    }
    /// Byte index in `text` closest to logical x (for caret placement).
    pub fn indexAt(self: Metrics, text: []const u8, x: f32) usize {
        var pen: f32 = 0;
        var it = codepoints(text);
        var prev: usize = 0;
        while (it.next()) |cp| {
            const adv = self.atlas.glyph(cp).advance / self.s();
            if (x < pen + adv / 2) return prev;
            pen += adv;
            prev = it.i;
        }
        return text.len;
    }
};

test "atlases load and measure" {
    const f = Fonts.get();
    const a = f.atlas(.{ .size = .body }, 1);
    try std.testing.expectEqual(@as(u16, 13), a.pixel_size);
    try std.testing.expect(a.measure("Tesselix") > 30);
    const a2 = f.atlas(.{ .size = .body }, 2);
    try std.testing.expectEqual(@as(u16, 26), a2.pixel_size);
    try std.testing.expect(a.glyph(0x2026).w > 0); // ellipsis present
}
