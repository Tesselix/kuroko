//! App icons as pixels (icons.tslx): txdesk draws each installed app's
//! icon file (PNG, SVG) at the sizes the desktop uses and writes them here;
//! the compositor reads pixels and never decodes an image format.
//!
//! Pure: encodes to and decodes from bytes.

const std = @import("std");
const types = @import("types.zig");
const format = @import("format.zig");

/// The sizes drawn: the launcher's 64 logical px at scale 1 and 2.
pub const sizes = [_]u16{ 64, 128 };

pub const Icon = struct {
    key: []const u8,
    w: u16,
    h: u16,
    source_mtime_ns: i64 = 0,
    /// 0xAARRGGBB, straight alpha.
    pixels: []const u32,
};

pub fn append(gpa: std.mem.Allocator, out: *std.ArrayList(u8), icon: Icon) !void {
    if (icon.key.len > std.math.maxInt(u16)) return;
    const n = @as(usize, icon.w) * icon.h;
    if (icon.pixels.len < n) return error.ShortIcon;
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    try extra.ensureTotalCapacity(gpa, icon.key.len + n * 4);
    extra.appendSliceAssumeCapacity(icon.key);
    for (icon.pixels[0..n]) |p| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, p, .little);
        extra.appendSliceAssumeCapacity(&b);
    }
    try format.appendStruct(gpa, out, types.icon_image, 1, types.IconImage{
        .w = icon.w,
        .h = icon.h,
        .key_len = @intCast(icon.key.len),
        .source_mtime_ns = icon.source_mtime_ns,
    }, extra.items);
}

/// Icons read from a file. Keys and pixels are owned.
pub const Set = struct {
    gpa: std.mem.Allocator,
    icons: std.ArrayList(Icon) = .empty,

    pub fn init(gpa: std.mem.Allocator) Set {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Set) void {
        self.clear();
        self.icons.deinit(self.gpa);
    }

    pub fn clear(self: *Set) void {
        for (self.icons.items) |ic| {
            self.gpa.free(ic.key);
            self.gpa.free(ic.pixels);
        }
        self.icons.clearRetainingCapacity();
    }

    /// The icon for `key` whose size is closest to `want` and not smaller
    /// when one exists.
    pub fn find(self: *const Set, key: []const u8, want: u16) ?*const Icon {
        var best: ?*const Icon = null;
        for (self.icons.items) |*ic| {
            if (!std.mem.eql(u8, ic.key, key)) continue;
            if (best == null) {
                best = ic;
                continue;
            }
            const b = best.?.w;
            const better = if (b < want) ic.w > b else ic.w >= want and ic.w < b;
            if (better) best = ic;
        }
        return best;
    }

    /// Replaces the set with a file's icons. Damaged records are skipped.
    pub fn decode(self: *Set, bytes: []const u8) !void {
        self.clear();
        var reader = format.Reader.init(bytes, &types.known);
        while (reader.next()) |rec| {
            if (rec.swapped or rec.type_id != types.icon_image) continue;
            const m = format.readStruct(types.IconImage, rec);
            const t = format.trailing(types.IconImage, rec);
            const n = @as(usize, m.w) * m.h;
            if (m.w == 0 or m.h == 0 or m.w > 512 or m.h > 512 or t.len != m.key_len + n * 4 or m.key_len == 0) continue;
            const key = try self.gpa.dupe(u8, t[0..m.key_len]);
            errdefer self.gpa.free(key);
            const px = try self.gpa.alloc(u32, n);
            errdefer self.gpa.free(px);
            for (px, 0..) |*p, i| p.* = std.mem.readInt(u32, t[m.key_len + i * 4 ..][0..4], .little);
            try self.icons.append(self.gpa, .{ .key = key, .w = m.w, .h = m.h, .source_mtime_ns = m.source_mtime_ns, .pixels = px });
        }
    }
};

test "icons survive a round trip and the right size is found" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var small: [4]u32 = @splat(0x80FF0000);
    var large: [16]u32 = @splat(0xFF00FF00);
    try append(gpa, &out, .{ .key = "/opt/app/app", .w = 2, .h = 2, .pixels = &small });
    try append(gpa, &out, .{ .key = "/opt/app/app", .w = 4, .h = 4, .pixels = &large });
    var set = Set.init(gpa);
    defer set.deinit();
    try set.decode(out.items);
    try std.testing.expectEqual(@as(usize, 2), set.icons.items.len);
    try std.testing.expectEqual(@as(u16, 2), set.find("/opt/app/app", 2).?.w);
    try std.testing.expectEqual(@as(u16, 4), set.find("/opt/app/app", 3).?.w);
    try std.testing.expectEqual(@as(u16, 4), set.find("/opt/app/app", 64).?.w);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), set.find("/opt/app/app", 4).?.pixels[15]);
    try std.testing.expect(set.find("/other", 4) == null);
}
