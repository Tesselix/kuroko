//! Places glyph bitmaps in one texture, row by row (shelf packing), the
//! first time each glyph is drawn. Glyphs are found by pointer: the font
//! atlases are loaded once and never move. Pure logic; the renderer does
//! the uploads.

const std = @import("std");
const tw = @import("krkwidgets");

pub const Slot = struct { x: u16, y: u16 };

pub const GlyphPack = struct {
    gpa: std.mem.Allocator,
    size: u16,
    x: u16 = 0,
    y: u16 = 0,
    row_h: u16 = 0,
    slots: std.AutoHashMapUnmanaged(*const tw.font.Glyph, Slot) = .empty,

    /// One empty pixel between glyphs, so linear sampling never bleeds.
    const pad = 1;

    pub fn init(gpa: std.mem.Allocator, size: u16) GlyphPack {
        return .{ .gpa = gpa, .size = size };
    }

    pub fn deinit(self: *GlyphPack) void {
        self.slots.deinit(self.gpa);
    }

    pub const Found = struct { slot: Slot, new: bool };

    /// Where the glyph is; `new` means it must be uploaded there now. Null
    /// when the texture is full (the glyph is not drawn).
    pub fn find(self: *GlyphPack, g: *const tw.font.Glyph) ?Found {
        if (self.slots.get(g)) |s| return .{ .slot = s, .new = false };
        const w: u16 = g.w;
        const h: u16 = g.h;
        if (w + pad > self.size or h + pad > self.size) return null;
        if (self.x + w + pad > self.size) {
            self.x = 0;
            self.y += self.row_h;
            self.row_h = 0;
        }
        if (self.y + h + pad > self.size) return null;
        const s: Slot = .{ .x = self.x, .y = self.y };
        self.slots.put(self.gpa, g, s) catch return null;
        self.x += w + pad;
        self.row_h = @max(self.row_h, h + pad);
        return .{ .slot = s, .new = true };
    }
};

test "glyphs get distinct places, once each" {
    var pack = GlyphPack.init(std.testing.allocator, 128);
    defer pack.deinit();
    const a = tw.font.Fonts.get().atlas(.{ .size = .title }, 2);
    var seen: [128]Slot = undefined;
    var n: usize = 0;
    for (a.glyphs[0..a.count]) |*g| {
        if (g.w == 0) continue;
        const f = pack.find(g) orelse break; // 128x128 fills up
        try std.testing.expect(f.new);
        try std.testing.expect(f.slot.x + g.w <= 128 and f.slot.y + g.h <= 128);
        for (seen[0..n]) |s| try std.testing.expect(s.x != f.slot.x or s.y != f.slot.y);
        seen[n] = f.slot;
        n += 1;
        const again = pack.find(g).?;
        try std.testing.expect(!again.new);
        try std.testing.expectEqual(f.slot, again.slot);
    }
    try std.testing.expect(n > 3);
}
