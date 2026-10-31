//! The influence file for the launcher (focus.krkde): the Focus and Recent
//! lists, written by a predictor (krkdesk now, the AI later) and read by the
//! compositor (Top-Level Design, "Influence files").
//!
//! Pure: encodes to and decodes from bytes. Decoded strings point into the
//! bytes, so the reader keeps the bytes as long as it uses the picks.

const std = @import("std");
const types = @import("types.zig");
const format = @import("format.zig");

pub const List = types.InfluenceList;
pub const Reason = types.InfluenceReason;

/// One entry: an app (its binary, or its app id for Kuroko's own apps),
/// optionally with an object (a file) open in it.
pub const Pick = struct {
    list: List,
    reason: Reason,
    value: i64 = 0,
    app: []const u8,
    object: []const u8 = "",
};

/// Most entries per list (Top-Level Design, launcher: 3–4).
pub const max_per_list = 4;

pub fn encode(gpa: std.mem.Allocator, picks: []const Pick, written_s: i64, source: types.InfluenceSource) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    try format.appendStruct(gpa, &out, types.influence_header, 1, types.InfluenceHeader{ .written_s = written_s, .source = source }, "");
    for (picks) |p| {
        if (p.app.len == 0 or p.app.len > std.math.maxInt(u16) or p.object.len > std.math.maxInt(u16)) continue;
        extra.clearRetainingCapacity();
        try extra.appendSlice(gpa, p.app);
        try extra.appendSlice(gpa, p.object);
        try format.appendStruct(gpa, &out, types.influence_entry, 1, types.InfluenceEntry{
            .list = p.list,
            .reason = p.reason,
            .app_len = @intCast(p.app.len),
            .object_len = @intCast(p.object.len),
            .value = p.value,
        }, extra.items);
    }
    return out.toOwnedSlice(gpa);
}

pub const Decoded = struct {
    written_s: i64 = 0,
    source: types.InfluenceSource = .predictor,
    /// Entries of lists this build does not know are left out.
    picks: std.ArrayList(Pick) = .empty,

    pub fn deinit(self: *Decoded, gpa: std.mem.Allocator) void {
        self.picks.deinit(gpa);
    }
};

/// Reads a file's bytes. Damaged entries are skipped; a file without a
/// header is not an influence file.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, out: *Decoded) !void {
    out.picks.clearRetainingCapacity();
    var have_header = false;
    var reader = format.Reader.init(bytes, &types.known);
    while (reader.next()) |rec| {
        if (rec.swapped) continue;
        switch (rec.type_id) {
            types.influence_header => {
                const h = format.readStruct(types.InfluenceHeader, rec);
                out.written_s = h.written_s;
                out.source = h.source;
                have_header = true;
            },
            types.influence_entry => {
                const e = format.readStruct(types.InfluenceEntry, rec);
                const t = format.trailing(types.InfluenceEntry, rec);
                if (@as(usize, e.app_len) + e.object_len != t.len or e.app_len == 0) continue;
                switch (e.list) {
                    .focus, .recent => {},
                    _ => continue,
                }
                try out.picks.append(gpa, .{
                    .list = e.list,
                    .reason = e.reason,
                    .value = e.value,
                    .app = t[0..e.app_len],
                    .object = t[e.app_len..],
                });
            },
            else => {},
        }
    }
    if (!have_header) return error.NotInfluence;
}

test "the lists survive a round trip; damaged entries are dropped" {
    const gpa = std.testing.allocator;
    const picks = [_]Pick{
        .{ .list = .focus, .reason = .cycle, .value = 5, .app = "/usr/bin/alacritty" },
        .{ .list = .focus, .reason = .used, .value = 42, .app = "org.kuroko.notes", .object = "/home/u/plan.txt" },
        .{ .list = .recent, .reason = .opened, .value = 1_760_000_000, .app = "/opt/google/chrome/chrome" },
    };
    const bytes = try encode(gpa, &picks, 1_760_000_100, .predictor);
    defer gpa.free(bytes);
    var d: Decoded = .{};
    defer d.deinit(gpa);
    try decode(gpa, bytes, &d);
    try std.testing.expectEqual(@as(i64, 1_760_000_100), d.written_s);
    try std.testing.expectEqual(@as(usize, 3), d.picks.items.len);
    try std.testing.expectEqualStrings("/home/u/plan.txt", d.picks.items[1].object);
    try std.testing.expectEqual(Reason.opened, d.picks.items[2].reason);

    bytes[std.mem.indexOf(u8, bytes, "chrome").?] ^= 0xff;
    try decode(gpa, bytes, &d);
    try std.testing.expectEqual(@as(usize, 2), d.picks.items.len);
    try std.testing.expectError(error.NotInfluence, decode(gpa, "", &d));
}
