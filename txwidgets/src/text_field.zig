//! Single-line text field (Look and Controls, "Text field and text area").
//!
//! v0: read/write, read-only and disabled states with shape cues; size in
//! `lt` with `min`/`max` (min always wins); end ellipsis when unfocused;
//! Home/End with smart Home, Ctrl+←/→ by words, Shift extends selection.
//! TODO: fill helper, marquee and other overflow policies, bidi alignment
//! by the first strong character, clipboard.

const std = @import("std");
const core = @import("txcore");
const font = @import("font.zig");
const Canvas = @import("canvas.zig").Canvas;

const Rect = core.Rect;
const Theme = core.Theme;
const Key = core.input.Key;
const Mods = core.input.Mods;

pub const State = enum { read_write, read_only, disabled };

pub const Params = struct {
    /// Wanted width in letters (`lt`).
    length_lt: i32 = 24,
    /// Floor in logical px; always wins.
    min_px: i32 = 120,
    max_px: ?i32 = null,
    placeholder: []const u8 = "",
    state: State = .read_write,
    password: bool = false,
    /// A search field (Widget Framework, "Mobile first"): a pill with a
    /// magnifier at the start and a clear button at the end.
    search: bool = false,
};

pub const height = 30;
const pad_x = 8;
/// Room for a search field's magnifier and clear button.
const search_lead = 28;
pub const clear_w = 26;
const style: font.Style = .{ .size = .body };

pub const KeyResult = enum { ignored, handled, changed, submit };

pub const TextField = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    anchor: usize = 0,
    scroll_x: f32 = 0,
    params: Params,

    pub fn create(gpa: std.mem.Allocator, params: Params, initial: []const u8) !*TextField {
        const tf = try gpa.create(TextField);
        tf.* = .{ .gpa = gpa, .params = params };
        try tf.buf.appendSlice(gpa, initial);
        tf.caret = initial.len;
        tf.anchor = tf.caret;
        return tf;
    }

    pub fn destroy(self: *TextField) void {
        self.buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn text(self: *const TextField) []const u8 {
        return self.buf.items;
    }

    pub fn setText(self: *TextField, t: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, t);
        self.caret = t.len;
        self.anchor = t.len;
    }

    /// Resolution: start from length, limit by max, then raise to min.
    pub fn measure(self: *const TextField, scale: i32) core.Size {
        const m = font.Metrics.of(style, scale);
        var w: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(self.params.length_lt)) * m.letterWidth()));
        w += self.padLeft() + self.padRight();
        if (self.params.max_px) |mx| w = @min(w, mx);
        w = @max(w, self.params.min_px);
        return .{ .w = w, .h = height };
    }

    fn selection(self: *const TextField) struct { a: usize, b: usize } {
        return .{ .a = @min(self.caret, self.anchor), .b = @max(self.caret, self.anchor) };
    }

    fn display(self: *const TextField, buf: []u8) []const u8 {
        if (!self.params.password) return self.buf.items;
        // One dot per code point.
        var n: usize = 0;
        var it = font.codepoints(self.buf.items);
        while (it.next()) |_| {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], "\u{2022}");
            n += 3;
        }
        return buf[0..n];
    }

    fn padLeft(self: *const TextField) i32 {
        return if (self.params.search) search_lead else pad_x;
    }

    fn padRight(self: *const TextField) i32 {
        return if (self.params.search and self.buf.items.len > 0) clear_w else pad_x;
    }

    /// The clear button of a search field with text, at local x.
    pub fn onClear(self: *const TextField, local_x: f32, w: i32) bool {
        return self.params.search and self.buf.items.len > 0 and local_x >= @as(f32, @floatFromInt(w - clear_w));
    }

    pub fn draw(self: *TextField, cv: *Canvas, r: Rect, theme: *const Theme, focused: bool) void {
        const st = self.params.state;
        const box = r;
        if (self.params.search) {
            const rad: f32 = @floatFromInt(@divTrunc(box.h, 2));
            cv.fillRoundRect(box, rad, theme.get(.surface_sunken));
            if (focused) cv.strokeRoundRect(box.inset(-2), rad + 2, 2, theme.get(.focus_ring).withAlpha(90));
            // The magnifier: a ring and its handle.
            const mx: f32 = @floatFromInt(box.x + 14);
            const my: f32 = @as(f32, @floatFromInt(box.y)) + @as(f32, @floatFromInt(box.h)) / 2 - 1;
            const dim = theme.get(.text_dim);
            cv.fillCircle(mx, my, 5.5, dim);
            cv.fillCircle(mx, my, 4, theme.get(.surface_sunken));
            cv.line(mx + 4, my + 4, mx + 7, my + 7, 1.8, dim);
            if (self.buf.items.len > 0) {
                // Clear: an x in a filled circle.
                const cx: f32 = @floatFromInt(box.right() - @divTrunc(clear_w, 2));
                cv.fillCircle(cx, my + 1, 7, dim);
                const bg = theme.get(.surface_sunken);
                cv.line(cx - 2.5, my - 1.5, cx + 2.5, my + 3.5, 1.5, bg);
                cv.line(cx - 2.5, my + 3.5, cx + 2.5, my - 1.5, 1.5, bg);
            }
        } else switch (st) {
            .read_write => {
                cv.fillRoundRect(box, 5, theme.get(.surface));
                cv.strokeRoundRect(box, 5, 0, theme.get(if (focused) .accent else .border));
                if (focused) cv.strokeRoundRect(box.inset(-2), 7, 2, theme.get(.focus_ring).withAlpha(90));
            },
            .read_only => {
                // No box: a bottom line only (shape differs from read/write).
                cv.hairlineHBottom(box.x, box.bottom() - 1, box.w, theme.get(.border));
                if (focused) cv.strokeRoundRect(box.inset(-2), 7, 2, theme.get(.focus_ring).withAlpha(90));
            },
            .disabled => {
                cv.fillRoundRect(box, 5, theme.get(.surface_alt));
                cv.dashedH(box.x + 4, box.bottom() - 2, box.w - 8, 1, 3, 3, theme.get(.text_disabled));
            },
        }

        var dots: [256]u8 = undefined;
        const shown = self.display(&dots);
        const m = font.Metrics.of(style, cv.scale);
        const inner = Rect{ .x = box.x + self.padLeft(), .y = box.y, .w = box.w - self.padLeft() - self.padRight(), .h = box.h };
        const ty: f32 = @as(f32, @floatFromInt(box.y)) + @as(f32, @floatFromInt(box.h - m.lineHeight())) / 2;
        const text_role: core.theme.Role = if (st == .disabled) .text_disabled else .text;

        const old = cv.pushClip(inner);
        defer cv.popClip(old);
        if (shown.len == 0 and !focused) {
            _ = cv.text(@floatFromInt(inner.x), ty, self.params.placeholder, style, theme.get(.text_dim));
            return;
        }
        if (!focused) {
            self.scroll_x = 0;
            _ = cv.textEllipsis(@floatFromInt(inner.x), ty, shown, @floatFromInt(inner.w), style, theme.get(text_role));
            return;
        }

        // Keep the caret visible.
        const caret_disp = self.displayIndex(self.caret);
        const caret_x = m.width(shown[0..caret_disp]);
        const iw: f32 = @floatFromInt(inner.w);
        if (caret_x - self.scroll_x > iw - 2) self.scroll_x = caret_x - iw + 2;
        if (caret_x - self.scroll_x < 0) self.scroll_x = caret_x;
        const x0 = @as(f32, @floatFromInt(inner.x)) - self.scroll_x;

        const sel = self.selection();
        if (sel.a != sel.b) {
            const sa = m.width(shown[0..self.displayIndex(sel.a)]);
            const sb = m.width(shown[0..self.displayIndex(sel.b)]);
            cv.fillRect(.{
                .x = @intFromFloat(@floor(x0 + sa)),
                .y = box.y + 6,
                .w = @intFromFloat(@ceil(sb - sa)),
                .h = box.h - 12,
            }, theme.get(.accent).withAlpha(70));
        }
        _ = cv.text(x0, ty, shown, style, theme.get(text_role));
        if (st == .read_write) {
            // Steady caret: no blinking (epilepsy rule, and calmer).
            cv.fillRect(.{ .x = @intFromFloat(@round(x0 + caret_x)), .y = box.y + 7, .w = 1, .h = box.h - 14 }, theme.get(.text));
        }
    }

    /// Maps a byte index in the real text to one in the displayed text.
    fn displayIndex(self: *const TextField, i: usize) usize {
        if (!self.params.password) return i;
        var n: usize = 0;
        var it = font.codepoints(self.buf.items[0..i]);
        while (it.next()) |_| n += 3;
        return n;
    }

    fn prev(self: *const TextField, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }
    fn next(self: *const TextField, i: usize) usize {
        if (i >= self.buf.items.len) return self.buf.items.len;
        var j = i + 1;
        while (j < self.buf.items.len and (self.buf.items[j] & 0xC0) == 0x80) j += 1;
        return j;
    }
    fn wordLeft(self: *const TextField, i: usize) usize {
        var j = i;
        while (j > 0 and self.buf.items[j - 1] == ' ') j -= 1;
        while (j > 0 and self.buf.items[j - 1] != ' ') j -= 1;
        return j;
    }
    fn wordRight(self: *const TextField, i: usize) usize {
        var j = i;
        const t = self.buf.items;
        while (j < t.len and t[j] != ' ') j += 1;
        while (j < t.len and t[j] == ' ') j += 1;
        return j;
    }
    /// Smart Home: first non-space, then the very start.
    fn homeTarget(self: *const TextField) usize {
        var first: usize = 0;
        while (first < self.buf.items.len and self.buf.items[first] == ' ') first += 1;
        return if (self.caret == first) 0 else first;
    }

    fn moveTo(self: *TextField, i: usize, extend: bool) void {
        self.caret = i;
        if (!extend) self.anchor = i;
    }

    fn deleteSelection(self: *TextField) bool {
        const sel = self.selection();
        if (sel.a == sel.b) return false;
        self.buf.replaceRange(self.gpa, sel.a, sel.b - sel.a, &.{}) catch return false;
        self.caret = sel.a;
        self.anchor = sel.a;
        return true;
    }

    pub fn key(self: *TextField, k: Key, mods: Mods) KeyResult {
        const editable = self.params.state == .read_write;
        if (self.params.state == .disabled) return .ignored;
        switch (k) {
            .left => {
                const sel = self.selection();
                if (!mods.shift and sel.a != sel.b) self.moveTo(sel.a, false) else self.moveTo(if (mods.ctrl) self.wordLeft(self.caret) else self.prev(self.caret), mods.shift);
            },
            .right => {
                const sel = self.selection();
                if (!mods.shift and sel.a != sel.b) self.moveTo(sel.b, false) else self.moveTo(if (mods.ctrl) self.wordRight(self.caret) else self.next(self.caret), mods.shift);
            },
            // Single line: Ctrl+Home/End are the same as Home/End.
            .home => self.moveTo(if (mods.ctrl) 0 else self.homeTarget(), mods.shift),
            .end => self.moveTo(self.buf.items.len, mods.shift),
            .a => {
                if (!mods.ctrl) return .ignored;
                self.anchor = 0;
                self.caret = self.buf.items.len;
            },
            .backspace => {
                if (!editable) return .ignored;
                if (!self.deleteSelection()) {
                    const from = if (mods.ctrl) self.wordLeft(self.caret) else self.prev(self.caret);
                    self.buf.replaceRange(self.gpa, from, self.caret - from, &.{}) catch return .ignored;
                    self.caret = from;
                    self.anchor = from;
                }
                return .changed;
            },
            .delete => {
                if (!editable) return .ignored;
                if (!self.deleteSelection()) {
                    const to = if (mods.ctrl) self.wordRight(self.caret) else self.next(self.caret);
                    self.buf.replaceRange(self.gpa, self.caret, to - self.caret, &.{}) catch return .ignored;
                }
                return .changed;
            },
            .enter => return .submit,
            else => return .ignored,
        }
        return .handled;
    }

    pub fn insert(self: *TextField, t: []const u8) bool {
        if (self.params.state != .read_write) return false;
        _ = self.deleteSelection();
        self.buf.insertSlice(self.gpa, self.caret, t) catch return false;
        self.caret += t.len;
        self.anchor = self.caret;
        return true;
    }

    /// Pointer press at x local to the field box.
    pub fn press(self: *TextField, local_x: f32, scale: i32, extend: bool) void {
        if (self.params.state == .disabled) return;
        const m = font.Metrics.of(style, scale);
        var i = m.indexAt(self.buf.items, local_x - @as(f32, @floatFromInt(self.padLeft())) + self.scroll_x);
        if (self.params.password) i = self.buf.items.len;
        self.moveTo(i, extend);
    }
};

test "editing, words, smart home" {
    const gpa = std.testing.allocator;
    var tf = try TextField.create(gpa, .{}, "  hello world");
    defer tf.destroy();
    _ = tf.key(.home, .{});
    try std.testing.expectEqual(@as(usize, 2), tf.caret); // first non-space
    _ = tf.key(.home, .{});
    try std.testing.expectEqual(@as(usize, 0), tf.caret); // then the start
    _ = tf.key(.end, .{});
    _ = tf.key(.backspace, .{ .ctrl = true });
    try std.testing.expectEqualStrings("  hello ", tf.text());
    _ = tf.insert("there");
    try std.testing.expectEqualStrings("  hello there", tf.text());
    _ = tf.key(.left, .{ .ctrl = true, .shift = true });
    _ = tf.insert("you");
    try std.testing.expectEqualStrings("  hello you", tf.text());
}

test "size: min always wins" {
    const gpa = std.testing.allocator;
    var tf = try TextField.create(gpa, .{ .length_lt = 2, .min_px = 200 }, "");
    defer tf.destroy();
    try std.testing.expectEqual(@as(i32, 200), tf.measure(1).w);
    tf.params = .{ .length_lt = 200, .min_px = 50, .max_px = 300 };
    try std.testing.expectEqual(@as(i32, 300), tf.measure(1).w);
}
