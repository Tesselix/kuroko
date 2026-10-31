//! Languages: Kuroko's dialog for choosing the user's languages, built with
//! the widget library like any other app (Top-Level Design, "Top bar and
//! control center", Language). It opens as a modal desktop dialog: a
//! search field, every language the system offers with a check mark on
//! the user's, at least one always checked; Cancel, or Done to apply.
//!
//! It knows nothing of the compositor: it gets the languages and a
//! callback for Done (krkdesk on Linux, the simulator's backend here).

const std = @import("std");
const tw = @import("krkwidgets");

const Window = tw.Window;
const NodeId = tw.NodeId;

pub const Language = struct {
    /// What the top bar shows: "EN".
    code: []const u8,
    name: []const u8,
    /// One of the user's languages.
    on: bool,
};

pub const max = 16;

/// Done: which languages are checked, in the order they were given.
pub const OnDone = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, []const bool) void,
};

const Dialog = struct {
    gpa: std.mem.Allocator,
    rows: [max]NodeId = undefined,
    len: usize = 0,
    search: NodeId = 0,
    none: NodeId = 0,
    on_done: OnDone,

    fn checked(self: *const Dialog, win: *Window) usize {
        var n: usize = 0;
        for (self.rows[0..self.len]) |r| n += @intFromBool(win.isOn(r));
        return n;
    }

    /// At least one language stays: when one is left, its row cannot be
    /// changed (gray, the footer says why).
    fn keepOne(self: *Dialog, win: *Window) void {
        const last = self.checked(win) == 1;
        for (self.rows[0..self.len]) |r| win.setEnabled(r, !(last and win.isOn(r)));
    }

    fn onCheck(self: *Dialog, win: *Window, _: NodeId) void {
        self.keepOne(win);
    }

    /// Shows the rows whose name or code holds the typed text (any case).
    fn onSearch(self: *Dialog, win: *Window, _: NodeId) void {
        const q = win.fieldText(self.search);
        var shown: usize = 0;
        for (self.rows[0..self.len]) |r| {
            const n = win.node(r);
            const match = q.len == 0 or std.ascii.indexOfIgnoreCase(n.text, q) != null or std.ascii.indexOfIgnoreCase(n.badge, q) != null;
            win.setHidden(r, !match);
            shown += @intFromBool(match);
        }
        win.setHidden(self.none, shown > 0);
    }

    fn onCancel(_: *Dialog, win: *Window, _: NodeId) void {
        win.requestClose();
    }

    fn onDoneClick(self: *Dialog, win: *Window, _: NodeId) void {
        var on: [max]bool = undefined;
        for (self.rows[0..self.len], 0..) |r, i| on[i] = win.isOn(r);
        self.on_done.func(self.on_done.ctx, on[0..self.len]);
        win.requestClose();
    }

    fn free(p: *anyopaque) void {
        const self: *Dialog = @ptrCast(@alignCast(p));
        self.gpa.destroy(self);
    }
};

pub fn create(gpa: std.mem.Allocator, languages: []const Language, on_done: OnDone) !tw.Surface {
    const win = try Window.create(gpa, .{
        .title = "Languages",
        .app_id = "org.kuroko.languages",
        .optimal = .{ .w = 380, .h = 0 },
        .background = .surface_alt,
    });
    errdefer win.destroy();
    const app = try gpa.create(Dialog);
    app.* = .{ .gpa = gpa, .on_done = on_done };
    win.on_destroy = .{ .ctx = app, .func = Dialog.free };

    const root = try win.column(null, .{ .spacing = 0 });
    _ = try win.headerBar(root, .{
        .title = "Languages",
        .leading = "Cancel",
        .trailing = "Done",
        .on_leading = tw.callback(app, Dialog.onCancel),
        .on_trailing = tw.callback(app, Dialog.onDoneClick),
    });
    const top = try win.column(root, .{ .padding = 12, .spacing = 0 });
    app.search = try win.searchField(top, "Search languages", tw.callback(app, Dialog.onSearch));
    const body = try win.scrollArea(root, 420, .{ .padding = 12, .spacing = 10 });
    const list = try win.list(body, .{
        .header = "LANGUAGES",
        .footer = "At least one stays checked.",
    });
    for (languages[0..@min(languages.len, max)]) |l| {
        app.rows[app.len] = try win.listRow(list, l.name, .{
            .badge = l.code,
            .accessory = .check,
            .toggles = true,
            .on = l.on,
            .on_change = tw.callback(app, Dialog.onCheck),
        });
        app.len += 1;
    }
    app.none = try win.label(body, "No language matches.", .{ .style = .{ .size = .small }, .role = .text_dim });
    win.setHidden(app.none, true);
    app.keepOne(win);
    return win.surface();
}

test "the last checked language cannot be unchecked; Done hands back the checks" {
    const gpa = std.testing.allocator;
    const Got = struct {
        on: [max]bool = undefined,
        len: usize = 0,
        fn f(p: *anyopaque, on: []const bool) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            @memcpy(self.on[0..on.len], on);
            self.len = on.len;
        }
    };
    var got: Got = .{};
    const s = try create(gpa, &.{
        .{ .code = "EN", .name = "English", .on = true },
        .{ .code = "HE", .name = "Hebrew", .on = false },
    }, .{ .ctx = &got, .func = Got.f });
    defer s.destroy();
    const win: *Window = @ptrCast(@alignCast(s.ptr));
    const app: *Dialog = @ptrCast(@alignCast(win.on_destroy.?.ctx));
    // English is the only one: its row is locked.
    try std.testing.expect(!win.node(app.rows[0]).enabled);
    // Checking Hebrew unlocks English.
    win.setOn(app.rows[1], true);
    app.onCheck(win, app.rows[1]);
    try std.testing.expect(win.node(app.rows[0]).enabled);
    // Search hides what does not match.
    _ = win.node(app.search).field.?.insert("heb");
    app.onSearch(win, app.search);
    try std.testing.expect(win.node(app.rows[0]).hidden);
    try std.testing.expect(!win.node(app.rows[1]).hidden);
    app.onDoneClick(win, 0);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got.on[0] and got.on[1]);
}
