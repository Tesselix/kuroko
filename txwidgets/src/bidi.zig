//! Bidirectional text for one line: the logical order of codepoints (as
//! typed and stored) turned into the visual order they are drawn in, left
//! to right. Hebrew and other right-to-left scripts read right to left;
//! numbers and Latin inside them still read left to right.
//!
//! A subset of UAX #9, enough for titles and labels:
//!  - the paragraph direction is that of the first strong letter (P2, P3)
//!  - European digits after a left-to-right letter count as one (W7)
//!  - neutrals (spaces, punctuation) take the direction around them when
//!    both sides agree, else the paragraph's (N1, N2; digits count as
//!    right-to-left there)
//!  - levels (I1, I2), then runs reversed from the highest level down (L2)
//!  - brackets in right-to-left runs are mirrored (L4)
//! Not handled: explicit embeddings and isolates (U+202A–U+2069), Arabic
//! digits as their own class, and line breaking (one line at a time).
//! TODO(text): the full algorithm, with shaping, when the text stack is
//! chosen (Widget Framework, open question).

const std = @import("std");
const font = @import("font.zig");

/// Codepoints reordered at once; a longer line is drawn as stored.
pub const max = 512;

pub const Class = enum { l, r, en, n };

pub fn class(cp: u21) Class {
    return switch (cp) {
        '0'...'9' => .en,
        'A'...'Z', 'a'...'z' => .l,
        0...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0xBF, 0xD7, 0xF7 => .n,
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF => .r,
        0x2000...0x2BFF, 0x3000...0x303F, 0xFE30...0xFE4F, 0xFFF0...0xFFFF => .n,
        0x10800...0x10FFF, 0x1E800...0x1EFFF => .r,
        else => .l,
    };
}

/// True when the text has a right-to-left letter (only then is there
/// anything to reorder).
pub fn hasRtl(cps: []const u21) bool {
    for (cps) |cp| {
        if (class(cp) == .r) return true;
    }
    return false;
}

/// The paragraph direction: that of the first strong letter, else
/// left to right.
pub fn baseIsRtl(cps: []const u21) bool {
    for (cps) |cp| {
        switch (class(cp)) {
            .l => return false,
            .r => return true,
            else => {},
        }
    }
    return false;
}

/// Reorders `cps` (at most `max`) from logical to visual order in place.
pub fn reorder(cps: []u21) void {
    const n = cps.len;
    if (n == 0 or n > max or !hasRtl(cps)) return;
    const base: Class = if (baseIsRtl(cps)) .r else .l;

    var t: [max]Class = undefined;
    for (cps, 0..) |cp, i| t[i] = class(cp);

    // W7: digits after a left-to-right letter (or at the start of a
    // left-to-right paragraph) are left to right.
    var last = base;
    for (t[0..n]) |*c| switch (c.*) {
        .l, .r => last = c.*,
        .en => if (last == .l) {
            c.* = .l;
        },
        .n => {},
    };

    // N1, N2: a run of neutrals takes the direction on both sides when
    // they agree, else the paragraph's. Digits count as right to left.
    var i: usize = 0;
    while (i < n) {
        if (t[i] != .n) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and t[j] == .n) j += 1;
        const before = if (i == 0) base else strong(t[i - 1]);
        const after = if (j == n) base else strong(t[j]);
        @memset(t[i..j], if (before == after) before else base);
        i = j;
    }

    // I1, I2: embedding levels.
    const base_level: u8 = if (base == .r) 1 else 0;
    var levels: [max]u8 = undefined;
    var top: u8 = 0;
    for (t[0..n], 0..) |c, k| {
        levels[k] = if (base_level == 0) switch (c) {
            .r => 1,
            .en => 2,
            else => 0,
        } else switch (c) {
            .l, .en => 2,
            else => 1,
        };
        top = @max(top, levels[k]);
    }

    // L4: mirrored brackets in right-to-left text.
    for (cps, 0..) |*cp, k| {
        if (levels[k] % 2 == 1) cp.* = mirror(cp.*);
    }

    // L2: from the highest level down to the lowest odd one, reverse
    // every run at that level or higher.
    var level = top;
    while (level >= 1) : (level -= 1) {
        var a: usize = 0;
        while (a < n) {
            if (levels[a] < level) {
                a += 1;
                continue;
            }
            var b = a;
            while (b < n and levels[b] >= level) b += 1;
            std.mem.reverse(u21, cps[a..b]);
            std.mem.reverse(u8, levels[a..b]);
            a = b;
        }
    }
}

/// A line of UTF-8 text in visual order, one codepoint at a time.
pub const Line = struct {
    /// The reordered codepoints; null when the line is longer than the
    /// buffer, and is then given as stored.
    visual: ?[]const u21,
    stored: font.CodepointIterator,
    i: usize = 0,
    /// The paragraph reads right to left.
    rtl: bool,

    pub fn of(str: []const u8, buf: []u21) Line {
        var it = font.codepoints(str);
        var n: usize = 0;
        var rtl = false;
        var decided = false;
        while (it.next()) |cp| : (n += 1) {
            if (!decided) switch (class(cp)) {
                .l, .r => |c| {
                    rtl = c == .r;
                    decided = true;
                },
                else => {},
            };
            if (n < buf.len) buf[n] = cp;
        }
        const fits = n <= buf.len and n <= max;
        if (fits) reorder(buf[0..n]);
        return .{ .visual = if (fits) buf[0..n] else null, .stored = font.codepoints(str), .rtl = rtl };
    }

    pub fn next(self: *Line) ?u21 {
        const v = self.visual orelse return self.stored.next();
        if (self.i == v.len) return null;
        defer self.i += 1;
        return v[self.i];
    }
};

fn strong(c: Class) Class {
    return if (c == .l) .l else .r;
}

fn mirror(cp: u21) u21 {
    return switch (cp) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        0xAB => 0xBB,
        0xBB => 0xAB,
        else => cp,
    };
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn check(logical: []const u8, visual: []const u8) !void {
    var buf: [max]u21 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(logical)).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) buf[n] = cp;
    reorder(buf[0..n]);
    var out: [max * 4]u8 = undefined;
    var len: usize = 0;
    for (buf[0..n]) |cp| len += try std.unicode.utf8Encode(cp, out[len..]);
    try testing.expectEqualStrings(visual, out[0..len]);
}

test "left-to-right text is unchanged" {
    try check("Hello, world (1)", "Hello, world (1)");
}

test "Hebrew reads right to left" {
    try check("שלום", "םולש");
}

test "Hebrew in a left-to-right line" {
    try check("Inbox - שלום עולם - Chrome", "Inbox - םלוע םולש - Chrome");
}

test "Latin and numbers inside Hebrew keep their order" {
    try check("גרסה 16 של Zig", "Zig לש 16 הסרג");
}

test "a line too long to reorder is given as stored" {
    var buf: [2]u21 = undefined;
    var line = Line.of("שלום", &buf);
    try testing.expect(line.rtl);
    try testing.expectEqual(@as(?u21, 0x05E9), line.next());
}

test "brackets are mirrored in right-to-left text" {
    try check("שלום (עולם)", "(םלוע) םולש");
}
