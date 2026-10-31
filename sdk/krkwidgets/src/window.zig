//! A framework window: widget tree, layout, input, drawing (Mode A).
//!
//! Widget model (Widget Framework): parameters (plain data), a controller
//! (the node ID: commands, state, events) and policies from a fixed set.
//! Events are notifications, never vetoes; the library acknowledges every
//! action itself within the frame.

const std = @import("std");
const core = @import("krkcore");
const font = @import("font.zig");
const Canvas = @import("canvas.zig").Canvas;
const surface_mod = @import("surface.zig");
const TextField = @import("text_field.zig").TextField;
const text_field = @import("text_field.zig");
const doc_view = @import("doc_view.zig");
const DocView = doc_view.DocView;
const Scroller = @import("scroll.zig").Scroller;

const Rect = core.Rect;
const Size = core.Size;
const Theme = core.Theme;
const Role = core.theme.Role;
const Tween = core.anim.Tween;
const Event = core.input.Event;
const ms = std.time.ns_per_ms;

pub const NodeId = u32;

/// Mode A event handler: a context pointer and a function.
pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, *Window, NodeId) void,

    pub fn call(self: Callback, win: *Window, id: NodeId) void {
        self.func(self.ctx, win, id);
    }
};

/// Wraps `f(ctx, win, id)` into a Callback.
pub fn callback(ctx: anytype, comptime f: fn (@TypeOf(ctx), *Window, NodeId) void) Callback {
    const P = @TypeOf(ctx);
    return .{ .ctx = @ptrCast(ctx), .func = struct {
        fn call(p: *anyopaque, w: *Window, id: NodeId) void {
            f(@as(P, @ptrCast(@alignCast(p))), w, id);
        }
    }.call };
}

pub const TickCallback = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, *Window, i64) void,
};

pub const Kind = enum { column, row, label, button, toggle, checkbox, progress, text_field, doc_view, separator, spacer, list, list_row, scroll };

pub const BoxParams = struct {
    padding: i32 = 0,
    spacing: i32 = 8,
    /// Card: a rounded panel with a hairline border.
    card: bool = false,
    /// Center children on the cross axis.
    center: bool = false,
    /// A row of three: the first at the start, the last at the end, the
    /// middle one centered on the whole row (a header bar).
    balance: bool = false,
    /// A hairline under the box.
    rule: bool = false,
};

pub const LabelParams = struct {
    style: font.Style = .{},
    role: Role = .text,
};

pub const ButtonParams = struct {
    primary: bool = false,
    /// Text only, in the accent color (a header bar's actions); with
    /// `primary`, semibold.
    plain: bool = false,
    on_click: ?Callback = null,
};

/// What a list row shows at its end (Widget Framework, "Mobile first").
pub const Accessory = enum { none, check, chevron, toggle, value };

pub const RowParams = struct {
    subtitle: []const u8 = "",
    /// A short code in an outlined key at the start ("EN").
    badge: []const u8 = "",
    accessory: Accessory = .none,
    /// Shown at the end with `.value`.
    value: []const u8 = "",
    /// The check mark or the switch.
    on: bool = false,
    /// A click flips `on` and calls on_change; otherwise it calls on_click.
    toggles: bool = false,
    on_change: ?Callback = null,
    on_click: ?Callback = null,
};

/// A grouped list: rows on a rounded card, a small heading above and a
/// note below.
pub const ListParams = struct {
    header: []const u8 = "",
    footer: []const u8 = "",
};

pub const HeaderParams = struct {
    title: []const u8,
    /// The plain action at the start ("Cancel"); none when empty.
    leading: []const u8 = "",
    /// The main action at the end ("Done"); none when empty. It is the
    /// window's default button (Enter).
    trailing: []const u8 = "",
    on_leading: ?Callback = null,
    on_trailing: ?Callback = null,
};

pub const HeaderBar = struct {
    bar: NodeId,
    title: NodeId,
    leading: ?NodeId,
    trailing: ?NodeId,
};

pub const ToggleParams = struct {
    on: bool = false,
    on_change: ?Callback = null,
};

pub const Node = struct {
    kind: Kind,
    parent: ?NodeId = null,
    first: ?NodeId = null,
    last: ?NodeId = null,
    next: ?NodeId = null,
    rect: Rect = .{},
    /// Takes the leftover space on the parent's main axis.
    grow: bool = false,
    /// Stretches across the parent's cross axis.
    fill: bool = false,
    enabled: bool = true,
    text: []u8 = &.{},

    box: BoxParams = .{},
    label: LabelParams = .{},
    button: ButtonParams = .{},
    toggle: ToggleParams = .{},
    value: ?f32 = 0, // progress; null = unknown length
    spacer: Size = .{ .w = 0, .h = 0 },
    on_submit: ?Callback = null,
    /// A text field's text changed (typing, clearing).
    on_text: ?Callback = null,
    field: ?*TextField = null,
    doc: ?*DocView = null,
    /// Not shown and takes no room (a row a search filtered out).
    hidden: bool = false,
    /// A list row's subtitle, badge and value (owned).
    subtitle: []u8 = &.{},
    badge: []u8 = &.{},
    value_text: []u8 = &.{},
    accessory: Accessory = .none,
    toggles: bool = false,
    /// A scroll area's position and physics.
    scroller: Scroller = .{},
    last_tick: i64 = 0,

    knob: Tween = Tween.init(0),
};

pub const Options = struct {
    title: []const u8,
    app_id: []const u8,
    optimal: Size,
    menu: []const []const u8 = &.{ "File", "Edit", "View", "Help" },
    dark: bool = false,
    /// What the window is filled with; a grouped list's cards take the
    /// other of surface and surface_alt.
    background: Role = .surface,
};

/// Hover enlargement (Look and Controls, "All widgets: hover enlargement").
pub const EnlargeParams = struct {
    enabled: bool = true,
    threshold_px: i32 = 15,
    dwell_ms: i64 = 1000,
    size: font.Size = .title,
};

pub const Window = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    title_buf: []u8,
    nodes: std.ArrayList(Node) = .empty,
    root: NodeId = 0,
    theme: Theme,

    size: Size = .{ .w = 0, .h = 0 },
    scale: i32 = 1,
    laid_out: bool = false,
    dirty: bool = true,

    pointer: ?struct { x: f32, y: f32 } = null,
    hover: ?NodeId = null,
    pressed: ?NodeId = null,
    capture: ?NodeId = null,
    focus: ?NodeId = null,
    focus_visible: bool = false,
    /// Enter clicks it when the focus is not on a widget that takes Enter.
    default_button: ?NodeId = null,

    status_value: surface_mod.Status = .{},
    close_requested: bool = false,
    /// A dialog this window asked to open, until the compositor takes it.
    pending_dialog: ?surface_mod.Surface.DialogRequest = null,
    on_tick: ?TickCallback = null,
    /// Called when the compositor destroys the window, so the app can free
    /// its own state.
    on_destroy: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,
    now: i64 = 0,

    enlarge: EnlargeParams = .{},
    enl_node: ?NodeId = null,
    enl_since: i64 = 0,
    enl_shown: bool = false,
    enl_t: Tween = Tween.init(0),
    enl_rect: Rect = .{},
    enl_text: []const u8 = "",

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Window {
        const w = try gpa.create(Window);
        errdefer gpa.destroy(w);
        w.* = .{
            .gpa = gpa,
            .opts = opts,
            .title_buf = try gpa.dupe(u8, opts.title),
            .theme = if (opts.dark) Theme.darkTheme() else Theme.light(),
        };
        w.opts.title = w.title_buf;
        w.root = try w.add(null, .{ .kind = .column, .box = .{ .padding = 0, .spacing = 0 }, .fill = true });
        return w;
    }

    pub fn destroy(self: *Window) void {
        if (self.on_destroy) |cb| cb.func(cb.ctx);
        if (self.pending_dialog) |d| d.surface.destroy();
        for (self.nodes.items) |*n| {
            self.gpa.free(n.text);
            self.gpa.free(n.subtitle);
            self.gpa.free(n.badge);
            self.gpa.free(n.value_text);
            if (n.field) |f| f.destroy();
            if (n.doc) |d| d.destroy();
        }
        self.nodes.deinit(self.gpa);
        self.gpa.free(self.title_buf);
        self.gpa.destroy(self);
    }

    pub fn node(self: *Window, id: NodeId) *Node {
        return &self.nodes.items[id];
    }

    fn add(self: *Window, parent: ?NodeId, n: Node) !NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        var nn = n;
        nn.parent = parent;
        try self.nodes.append(self.gpa, nn);
        if (parent) |p| {
            const pn = &self.nodes.items[p];
            if (pn.last) |l| self.nodes.items[l].next = id else pn.first = id;
            pn.last = id;
        }
        self.laid_out = false;
        self.dirty = true;
        return id;
    }

    // ----------------------------------------------------------- builders

    /// A column; at the top level it takes the window's whole height, so
    /// a scroll area in it gets the room that is left.
    pub fn column(self: *Window, parent: ?NodeId, p: BoxParams) !NodeId {
        return self.add(parent orelse self.root, .{ .kind = .column, .box = p, .fill = true, .grow = parent == null });
    }
    pub fn row(self: *Window, parent: ?NodeId, p: BoxParams) !NodeId {
        return self.add(parent orelse self.root, .{ .kind = .row, .box = p, .fill = true });
    }
    pub fn label(self: *Window, parent: NodeId, text: []const u8, p: LabelParams) !NodeId {
        return self.add(parent, .{ .kind = .label, .label = p, .text = try self.gpa.dupe(u8, text) });
    }
    pub fn button(self: *Window, parent: NodeId, text: []const u8, p: ButtonParams) !NodeId {
        return self.add(parent, .{ .kind = .button, .button = p, .text = try self.gpa.dupe(u8, text) });
    }
    pub fn toggle(self: *Window, parent: NodeId, text: []const u8, p: ToggleParams) !NodeId {
        const id = try self.add(parent, .{ .kind = .toggle, .toggle = p, .text = try self.gpa.dupe(u8, text) });
        self.node(id).knob.snap(if (p.on) 1 else 0);
        return id;
    }
    pub fn checkbox(self: *Window, parent: NodeId, text: []const u8, p: ToggleParams) !NodeId {
        return self.add(parent, .{ .kind = .checkbox, .toggle = p, .text = try self.gpa.dupe(u8, text) });
    }
    pub fn progress(self: *Window, parent: NodeId, value: ?f32) !NodeId {
        return self.add(parent, .{ .kind = .progress, .value = value, .fill = true });
    }
    pub fn separator(self: *Window, parent: NodeId) !NodeId {
        return self.add(parent, .{ .kind = .separator, .fill = true });
    }
    pub fn spacer(self: *Window, parent: NodeId, w: i32, h: i32) !NodeId {
        return self.add(parent, .{ .kind = .spacer, .spacer = .{ .w = w, .h = h } });
    }
    pub fn textField(self: *Window, parent: NodeId, initial: []const u8, p: text_field.Params) !NodeId {
        const f = try TextField.create(self.gpa, p, initial);
        errdefer f.destroy();
        return self.add(parent, .{ .kind = .text_field, .field = f, .enabled = p.state != .disabled });
    }
    /// A search field: filters as the user types (`on_change` after each
    /// change, including the clear button).
    pub fn searchField(self: *Window, parent: NodeId, placeholder: []const u8, on_change: ?Callback) !NodeId {
        const id = try self.textField(parent, "", .{ .search = true, .placeholder = placeholder, .min_px = 160 });
        self.node(id).fill = true;
        self.node(id).on_text = on_change;
        return id;
    }

    /// A header bar: a plain action at the start, the title in the
    /// middle, the main action at the end (the default button).
    pub fn headerBar(self: *Window, parent: NodeId, p: HeaderParams) !HeaderBar {
        const bar = try self.add(parent, .{ .kind = .row, .box = .{ .padding = 8, .spacing = 8, .balance = true, .rule = true }, .fill = true });
        const lead: ?NodeId = if (p.leading.len > 0) try self.button(bar, p.leading, .{ .plain = true, .on_click = p.on_leading }) else null;
        if (lead == null) _ = try self.spacer(bar, 0, 0);
        const title = try self.label(bar, p.title, .{ .style = .{ .weight = .semibold } });
        const trail: ?NodeId = if (p.trailing.len > 0) try self.button(bar, p.trailing, .{ .plain = true, .primary = true, .on_click = p.on_trailing }) else null;
        if (trail == null) _ = try self.spacer(bar, 0, 0);
        if (trail) |t| self.default_button = t;
        return .{ .bar = bar, .title = title, .leading = lead, .trailing = trail };
    }

    /// A grouped list; returns the card that holds the rows.
    pub fn list(self: *Window, parent: NodeId, p: ListParams) !NodeId {
        const wrap = try self.add(parent, .{ .kind = .column, .box = .{ .spacing = 6 }, .fill = true });
        const note: LabelParams = .{ .style = .{ .size = .small }, .role = .text_dim };
        if (p.header.len > 0) {
            const r = try self.add(wrap, .{ .kind = .row, .box = .{ .padding = 0, .spacing = 0 }, .fill = true });
            _ = try self.spacer(r, 14, 0);
            _ = try self.label(r, p.header, .{ .style = .{ .size = .small, .weight = .semibold }, .role = .text_dim });
        }
        const card = try self.add(wrap, .{ .kind = .list, .box = .{ .spacing = 0 }, .fill = true });
        if (p.footer.len > 0) {
            const r = try self.add(wrap, .{ .kind = .row, .box = .{ .padding = 0, .spacing = 0 }, .fill = true });
            _ = try self.spacer(r, 14, 0);
            _ = try self.label(r, p.footer, note);
        }
        return card;
    }

    /// A row of a grouped list.
    pub fn listRow(self: *Window, parent: NodeId, title: []const u8, p: RowParams) !NodeId {
        const text = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(text);
        const sub = try self.gpa.dupe(u8, p.subtitle);
        errdefer self.gpa.free(sub);
        const badge = try self.gpa.dupe(u8, p.badge);
        errdefer self.gpa.free(badge);
        const value = try self.gpa.dupe(u8, p.value);
        errdefer self.gpa.free(value);
        const id = try self.add(parent, .{
            .kind = .list_row,
            .fill = true,
            .text = text,
            .subtitle = sub,
            .badge = badge,
            .value_text = value,
            .accessory = p.accessory,
            .toggles = p.toggles,
            .toggle = .{ .on = p.on, .on_change = p.on_change },
            .button = .{ .on_click = p.on_click },
        });
        self.node(id).knob.snap(if (p.on) 1 else 0);
        return id;
    }

    /// A scroll area that takes the room left; returns the column inside
    /// it. `max_h` caps the height it asks for (0: all of its content).
    pub fn scrollArea(self: *Window, parent: NodeId, max_h: i32, p: BoxParams) !NodeId {
        const sc = try self.add(parent, .{ .kind = .scroll, .fill = true, .grow = true, .spacer = .{ .w = 0, .h = max_h } });
        return self.add(sc, .{ .kind = .column, .box = p, .fill = true });
    }

    pub fn docView(self: *Window, parent: NodeId, blocks: []const doc_view.Block) !NodeId {
        const d = try DocView.create(self.gpa, blocks);
        errdefer d.destroy();
        return self.add(parent, .{ .kind = .doc_view, .doc = d, .fill = true, .grow = true });
    }

    // ---------------------------------------------------------- controller

    pub fn setText(self: *Window, id: NodeId, text: []const u8) void {
        const n = self.node(id);
        if (std.mem.eql(u8, n.text, text)) return;
        const copy = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(n.text);
        n.text = copy;
        self.laid_out = false;
        self.dirty = true;
    }
    pub fn setValue(self: *Window, id: NodeId, v: ?f32) void {
        self.node(id).value = v;
        self.dirty = true;
    }
    pub fn setOn(self: *Window, id: NodeId, on: bool) void {
        const n = self.node(id);
        n.toggle.on = on;
        n.knob.set(if (on) 1 else 0, self.now, 150);
        self.dirty = true;
    }
    pub fn isOn(self: *Window, id: NodeId) bool {
        return self.node(id).toggle.on;
    }
    /// Hides a node (it takes no room), or shows it again.
    pub fn setHidden(self: *Window, id: NodeId, hidden: bool) void {
        const n = self.node(id);
        if (n.hidden == hidden) return;
        n.hidden = hidden;
        if (hidden and self.focus == id) self.focus = null;
        self.laid_out = false;
        self.dirty = true;
    }
    pub fn setEnabled(self: *Window, id: NodeId, on: bool) void {
        self.node(id).enabled = on;
        if (!on and self.focus == id) self.focus = null;
        self.dirty = true;
    }
    pub fn fieldText(self: *Window, id: NodeId) []const u8 {
        return self.node(id).field.?.text();
    }
    pub fn doc(self: *Window, id: NodeId) *DocView {
        return self.node(id).doc.?;
    }
    /// Window status for the compositor's bottom border.
    pub fn setStatus(self: *Window, kind: core.types.Status, value: f32) void {
        self.status_value = .{ .kind = kind, .progress = value };
        self.dirty = true;
    }
    pub fn requestClose(self: *Window) void {
        self.close_requested = true;
    }
    /// Opens a dialog over this window (Top-Level Design, "Dialogs"); the
    /// compositor owns it from then on. A second request before the first
    /// is taken replaces it, and the first is destroyed.
    pub fn openDialog(self: *Window, s: surface_mod.Surface, modal: bool) void {
        if (self.pending_dialog) |old| old.surface.destroy();
        self.pending_dialog = .{ .surface = s, .modal = modal };
    }

    // ------------------------------------------------------------- layout

    fn children(self: *Window, id: NodeId) ChildIter {
        return .{ .win = self, .cur = self.nodes.items[id].first };
    }

    const ChildIter = struct {
        win: *Window,
        cur: ?NodeId,
        fn next(it: *ChildIter) ?NodeId {
            while (it.cur) |c| {
                it.cur = it.win.nodes.items[c].next;
                if (!it.win.nodes.items[c].hidden) return c;
            }
            return null;
        }
    };

    fn textSize(self: *Window, text: []const u8, style: font.Style) Size {
        const m = font.Metrics.of(style, self.scale);
        return .{ .w = @intFromFloat(@ceil(m.width(text))), .h = m.lineHeight() };
    }

    fn measure(self: *Window, id: NodeId, avail_w: i32) Size {
        const n = self.nodes.items[id];
        return switch (n.kind) {
            .column => blk: {
                var w: i32 = 0;
                var h: i32 = 0;
                var count: i32 = 0;
                const inner = avail_w - 2 * n.box.padding;
                var it = self.children(id);
                while (it.next()) |c| {
                    const s = self.measure(c, inner);
                    w = @max(w, s.w);
                    h += s.h;
                    count += 1;
                }
                if (count > 1) h += (count - 1) * n.box.spacing;
                break :blk .{ .w = w + 2 * n.box.padding, .h = h + 2 * n.box.padding };
            },
            .row => blk: {
                var w: i32 = 0;
                var h: i32 = 0;
                var count: i32 = 0;
                var side: i32 = 0;
                var it = self.children(id);
                while (it.next()) |c| {
                    const s = self.measure(c, avail_w);
                    w += s.w;
                    h = @max(h, s.h);
                    if (count != 1) side = @max(side, s.w);
                    count += 1;
                }
                if (count > 1) w += (count - 1) * n.box.spacing;
                // Balanced: the middle is centered, so both sides take the
                // wider one's room.
                if (n.box.balance and count == 3) w = 2 * side + self.middleWidth(id) + 2 * n.box.spacing;
                break :blk .{ .w = w + 2 * n.box.padding, .h = h + 2 * n.box.padding };
            },
            .list => blk: {
                var w: i32 = 0;
                var h: i32 = 0;
                var it = self.children(id);
                while (it.next()) |c| {
                    const s = self.measure(c, avail_w);
                    w = @max(w, s.w);
                    h += s.h;
                }
                break :blk .{ .w = w, .h = h };
            },
            .list_row => blk: {
                var w: i32 = 32 + self.textSize(n.text, .{}).w;
                if (n.badge.len > 0) w += 40;
                w += switch (n.accessory) {
                    .none => 0,
                    .check, .chevron => 28,
                    .toggle => 50,
                    .value => self.textSize(n.value_text, .{}).w + 36,
                };
                if (n.subtitle.len > 0) w = @max(w, 32 + self.textSize(n.subtitle, .{ .size = .small }).w);
                break :blk .{ .w = w, .h = if (n.subtitle.len > 0) 54 else 44 };
            },
            .scroll => blk: {
                const c = self.measure(n.first orelse break :blk .{ .w = 0, .h = 0 }, avail_w);
                break :blk .{ .w = c.w, .h = if (n.spacer.h > 0) @min(c.h, n.spacer.h) else c.h };
            },
            .label => self.textSize(n.text, n.label.style),
            .button => blk: {
                const t = self.textSize(n.text, if (n.button.plain and n.button.primary) .{ .weight = .semibold } else .{});
                break :blk .{ .w = t.w + if (n.button.plain) @as(i32, 16) else 28, .h = 30 };
            },
            .toggle => .{ .w = 34 + 10 + self.textSize(n.text, .{}).w, .h = 24 },
            .checkbox => .{ .w = 16 + 8 + self.textSize(n.text, .{}).w, .h = 24 },
            .progress => .{ .w = 160, .h = 8 },
            .separator => .{ .w = 1, .h = 9 },
            .spacer => n.spacer,
            .text_field => n.field.?.measure(self.scale),
            .doc_view => .{ .w = avail_w, .h = 200 },
        };
    }

    fn arrange(self: *Window, id: NodeId, r: Rect) void {
        self.nodes.items[id].rect = r;
        const n = self.nodes.items[id];
        switch (n.kind) {
            .column, .list => self.arrangeBox(id, r, true),
            .row => self.arrangeBox(id, r, false),
            .scroll => {
                const c = n.first orelse return;
                const content_h = self.measure(c, r.w).h;
                const sn = &self.nodes.items[id];
                sn.scroller.setExtent(@floatFromInt(content_h), @floatFromInt(r.h), 44);
                self.arrange(c, .{ .x = r.x, .y = r.y - @as(i32, @intFromFloat(@round(sn.scroller.pos))), .w = r.w, .h = content_h });
            },
            .doc_view => n.doc.?.arrange(r, self.scale),
            else => {},
        }
    }

    fn arrangeBox(self: *Window, id: NodeId, r: Rect, vertical: bool) void {
        const n = self.nodes.items[id];
        const inner = r.inset(n.box.padding);
        var fixed: i32 = 0;
        var grow_count: i32 = 0;
        var count: i32 = 0;
        var it = self.children(id);
        while (it.next()) |c| {
            const s = self.measure(c, inner.w);
            if (self.nodes.items[c].grow) grow_count += 1 else fixed += if (vertical) s.h else s.w;
            count += 1;
        }
        if (count == 0) return;
        if (!vertical and n.box.balance and count == 3) return self.arrangeBalanced(id, inner);
        const main = if (vertical) inner.h else inner.w;
        const free = @max(0, main - fixed - (count - 1) * n.box.spacing);
        const per_grow = if (grow_count > 0) @divTrunc(free, grow_count) else 0;
        var pos: i32 = if (vertical) inner.y else inner.x;
        it = self.children(id);
        while (it.next()) |c| {
            const cn = self.nodes.items[c];
            const s = self.measure(c, inner.w);
            var cr: Rect = undefined;
            if (vertical) {
                const h = if (cn.grow) per_grow else s.h;
                const w = if (cn.fill) inner.w else @min(s.w, inner.w);
                const x = if (n.box.center and !cn.fill) inner.x + @divTrunc(inner.w - w, 2) else inner.x;
                cr = .{ .x = x, .y = pos, .w = w, .h = h };
                pos += h + n.box.spacing;
            } else {
                const w = if (cn.grow) per_grow else s.w;
                const h = if (cn.fill and (cn.kind == .column or cn.kind == .row or cn.kind == .doc_view)) inner.h else s.h;
                cr = .{ .x = pos, .y = inner.y + @divTrunc(inner.h - h, 2), .w = w, .h = h };
                pos += w + n.box.spacing;
            }
            self.arrange(c, cr);
        }
    }

    fn middleWidth(self: *Window, id: NodeId) i32 {
        var it = self.children(id);
        _ = it.next();
        const mid = it.next() orelse return 0;
        return self.measure(mid, 4000).w;
    }

    /// A balanced row of three: first at the start, last at the end, the
    /// middle centered on the row, never over the sides.
    fn arrangeBalanced(self: *Window, id: NodeId, inner: Rect) void {
        const sp = self.nodes.items[id].box.spacing;
        var it = self.children(id);
        const a = it.next().?;
        const b = it.next().?;
        const c = it.next().?;
        const sa = self.measure(a, inner.w);
        const sb = self.measure(b, inner.w);
        const sc = self.measure(c, inner.w);
        const cy = struct {
            fn f(in: Rect, h: i32) i32 {
                return in.y + @divTrunc(in.h - h, 2);
            }
        }.f;
        self.arrange(a, .{ .x = inner.x, .y = cy(inner, sa.h), .w = sa.w, .h = sa.h });
        self.arrange(c, .{ .x = inner.right() - sc.w, .y = cy(inner, sc.h), .w = sc.w, .h = sc.h });
        const lo = inner.x + sa.w + sp;
        const hi = inner.right() - sc.w - sp;
        const w = @min(sb.w, @max(0, hi - lo));
        const x = std.math.clamp(inner.x + @divTrunc(inner.w - w, 2), lo, @max(lo, hi - w));
        self.arrange(b, .{ .x = x, .y = cy(inner, sb.h), .w = w, .h = sb.h });
    }

    fn layout(self: *Window) void {
        self.arrange(self.root, .{ .x = 0, .y = 0, .w = self.size.w, .h = self.size.h });
        self.laid_out = true;
    }

    // -------------------------------------------------------------- input

    fn interactive(k: Kind) bool {
        return switch (k) {
            .button, .toggle, .checkbox, .text_field, .doc_view, .list_row => true,
            else => false,
        };
    }

    fn focusable(n: Node) bool {
        return interactive(n.kind) and n.enabled and !n.hidden;
    }

    /// Deepest node at a point that satisfies `pred`.
    fn hit(self: *Window, id: NodeId, x: f32, y: f32, comptime pred: fn (Node) bool) ?NodeId {
        const n = self.nodes.items[id];
        if (!n.rect.contains(x, y)) return null;
        var best: ?NodeId = if (pred(n)) id else null;
        var it = self.children(id);
        while (it.next()) |c| {
            if (self.hit(c, x, y, pred)) |h| best = h;
        }
        return best;
    }

    fn isInteractive(n: Node) bool {
        return interactive(n.kind) and n.enabled;
    }

    fn isEnlargeable(n: Node) bool {
        return switch (n.kind) {
            .label => n.label.style.size.px() < 15 and n.text.len > 0,
            .button, .toggle, .checkbox => n.text.len > 0, // body text, 13 px
            else => false,
        };
    }

    fn click(self: *Window, id: NodeId) void {
        const n = self.node(id);
        if (!n.enabled) return;
        switch (n.kind) {
            .button => if (n.button.on_click) |cb| cb.call(self, id),
            .toggle, .checkbox => {
                self.setOn(id, !n.toggle.on);
                if (self.node(id).toggle.on_change) |cb| cb.call(self, id);
            },
            .list_row => if (n.toggles) {
                self.setOn(id, !n.toggle.on);
                if (self.node(id).toggle.on_change) |cb| cb.call(self, id);
            } else if (n.button.on_click) |cb| cb.call(self, id),
            else => {},
        }
    }

    /// The scroll area around a node, if any.
    fn scrollOf(self: *Window, id: NodeId) ?NodeId {
        var cur = self.nodes.items[id].parent;
        while (cur) |c| : (cur = self.nodes.items[c].parent) {
            if (self.nodes.items[c].kind == .scroll) return c;
        }
        return null;
    }

    /// Scrolls the focused widget into view.
    fn revealFocus(self: *Window) void {
        const f = self.focus orelse return;
        const sid = self.scrollOf(f) orelse return;
        const fr = self.nodes.items[f].rect;
        const sn = &self.nodes.items[sid];
        const sr = sn.rect;
        const pos = sn.scroller.pos;
        if (fr.y < sr.y) sn.scroller.jumpTo(pos - @as(f32, @floatFromInt(sr.y - fr.y)), self.now);
        if (fr.bottom() > sr.bottom()) sn.scroller.jumpTo(pos + @as(f32, @floatFromInt(fr.bottom() - sr.bottom())), self.now);
    }

    fn moveFocus(self: *Window, backward: bool) void {
        const count = self.nodes.items.len;
        if (count == 0) return;
        var i: usize = if (self.focus) |f| f else if (backward) 0 else count - 1;
        for (0..count) |_| {
            i = if (backward) (i + count - 1) % count else (i + 1) % count;
            if (focusable(self.nodes.items[i])) {
                self.focus = @intCast(i);
                self.focus_visible = true;
                self.revealFocus();
                return;
            }
        }
    }

    fn dismissEnlargement(self: *Window) void {
        if (self.enl_shown) self.enl_t.set(0, self.now, 120);
        self.enl_shown = false;
        self.enl_node = null;
    }

    pub fn handleInput(self: *Window, ev: Event, now: i64) void {
        self.now = now;
        self.dirty = true;
        switch (ev) {
            .pointer_motion => |m| {
                self.pointer = .{ .x = m.x, .y = m.y };
                for (self.nodes.items) |n| {
                    if (n.doc) |d| d.pointerMotion(m.x, m.y, now);
                }
                if (self.capture) |c| {
                    const n = self.node(c);
                    if (n.field) |f| f.press(m.x - @as(f32, @floatFromInt(n.rect.x)), self.scale, true);
                    return;
                }
                self.hover = self.hit(self.root, m.x, m.y, isInteractive);
                // Enlargement starts only when the pointer moves into a widget.
                const cand = if (self.enlarge.enabled) self.hit(self.root, m.x, m.y, isEnlargeable) else null;
                if (cand != self.enl_node) {
                    self.dismissEnlargement();
                    self.enl_node = cand;
                    self.enl_since = now;
                }
            },
            .pointer_leave => {
                self.pointer = null;
                self.hover = null;
                self.dismissEnlargement();
                for (self.nodes.items) |n| {
                    if (n.doc) |d| d.pointerLeave(now);
                }
            },
            .pointer_button => |b| {
                if (b.button != .left) return;
                if (b.pressed) {
                    self.focus_visible = false;
                    self.dismissEnlargement();
                    const target = self.hit(self.root, b.x, b.y, isInteractive);
                    self.pressed = target;
                    if (target) |t| {
                        const n = self.node(t);
                        self.focus = t;
                        if (n.field) |f| {
                            const lx = b.x - @as(f32, @floatFromInt(n.rect.x));
                            if (f.onClear(lx, n.rect.w)) {
                                f.setText("") catch {};
                                self.laid_out = false;
                                if (n.on_text) |cb| cb.call(self, t);
                            } else {
                                f.press(lx, self.scale, false);
                                self.capture = t;
                            }
                        }
                        if (n.doc) |d| {
                            if (d.press(b.x, b.y, now)) self.capture = t;
                        }
                    } else self.focus = null;
                } else {
                    if (self.capture) |c| {
                        if (self.node(c).doc) |d| d.release(now);
                    }
                    self.capture = null;
                    if (self.pressed) |p| {
                        if (self.node(p).rect.contains(b.x, b.y)) self.click(p);
                    }
                    self.pressed = null;
                }
            },
            .wheel => |w| {
                self.dismissEnlargement();
                const p = self.pointer orelse return;
                const target = self.hit(self.root, p.x, p.y, struct {
                    fn f(n: Node) bool {
                        return n.kind == .doc_view or n.kind == .scroll;
                    }
                }.f);
                const t = target orelse return;
                const tn = self.node(t);
                if (tn.doc) |d| d.wheel(w, now) else if (w.dy != 0) switch (w.source) {
                    .touchpad => tn.scroller.pixels(w.dy),
                    .wheel => tn.scroller.wheel(w.dy, w.band, w.rate),
                };
            },
            .key => |k| {
                if (!k.pressed) return;
                if (k.key == .escape) {
                    self.dismissEnlargement();
                    return;
                }
                if (k.key == .tab) {
                    self.moveFocus(k.mods.shift);
                    return;
                }
                // Enter: the default button, unless the focus takes Enter.
                const takes_enter = if (self.focus) |f| switch (self.nodes.items[f].kind) {
                    .button, .toggle, .checkbox, .list_row, .doc_view => true,
                    .text_field => self.nodes.items[f].on_submit != null,
                    else => false,
                } else false;
                if (k.key == .enter and !takes_enter) {
                    if (self.default_button) |d| self.click(d);
                    return;
                }
                const f = self.focus orelse return;
                const n = self.node(f);
                switch (n.kind) {
                    .text_field => switch (n.field.?.key(k.key, k.mods)) {
                        .submit => if (n.on_submit) |cb| cb.call(self, f),
                        .changed => if (n.on_text) |cb| cb.call(self, f),
                        else => {},
                    },
                    .doc_view => _ = n.doc.?.key(k.key, k.mods, now),
                    .button, .toggle, .checkbox, .list_row => if (k.key == .space or k.key == .enter) self.click(f),
                    else => {},
                }
                self.focus_visible = true;
            },
            .text => |t| {
                const f = self.focus orelse return;
                if (self.node(f).field) |field| {
                    if (field.insert(t.slice())) {
                        self.laid_out = false;
                        if (self.node(f).on_text) |cb| cb.call(self, f);
                    }
                }
            },
        }
    }

    pub fn tick(self: *Window, now: i64) bool {
        self.now = now;
        var animating = false;
        for (self.nodes.items) |*n| {
            if (n.doc) |d| {
                if (d.tick(now)) animating = true;
            }
            if (!n.knob.done(now)) animating = true;
            if (n.kind == .progress and n.value == null) animating = true;
            if (n.kind == .scroll) {
                const dt: f32 = if (n.last_tick == 0) 0 else @as(f32, @floatFromInt(@min(now - n.last_tick, 100 * ms))) / std.time.ns_per_s;
                n.last_tick = now;
                const before = n.scroller.pos;
                if (n.scroller.update(dt, now)) animating = true;
                if (n.scroller.pos != before) {
                    self.laid_out = false;
                    self.dirty = true;
                }
            }
        }
        if (self.enl_node) |id| {
            if (!self.enl_shown and now - self.enl_since >= self.enlarge.dwell_ms * ms) {
                self.enl_shown = true;
                self.enl_text = self.nodes.items[id].text;
                self.enl_rect = self.nodes.items[id].rect;
                self.enl_t.set(1, now, 200);
            }
            if (!self.enl_shown) animating = true; // keep the dwell clock running
        }
        if (!self.enl_t.done(now)) animating = true;
        if (self.on_tick) |cb| cb.func(cb.ctx, self, now);
        const d = self.dirty;
        self.dirty = false;
        return d or animating;
    }

    // --------------------------------------------------------------- draw

    pub fn draw(self: *Window, cv: *Canvas) void {
        if (!self.laid_out) self.layout();
        cv.clear(self.theme.get(self.opts.background));
        self.drawNode(cv, self.root);
        self.drawEnlargement(cv);
    }

    fn drawNode(self: *Window, cv: *Canvas, id: NodeId) void {
        const n = &self.nodes.items[id];
        const th = &self.theme;
        const r = n.rect;
        const hovered = self.hover == id;
        const pressed = self.pressed == id and hovered;
        const focused = self.focus == id;
        switch (n.kind) {
            .column, .row => {
                if (n.box.card) {
                    cv.fillRoundRect(r, 8, th.get(.surface_alt));
                    cv.strokeRoundRect(r, 8, 0, th.get(.border));
                }
                if (n.box.rule) cv.hairlineHBottom(r.x, r.bottom() - 1, r.w, th.get(.hairline));
                var it = self.children(id);
                while (it.next()) |c| self.drawNode(cv, c);
            },
            .list => {
                // A rounded card in the other surface color; a hairline
                // between rows, from where the text starts.
                const card: Role = if (self.opts.background == .surface) .surface_alt else .surface;
                cv.fillRoundRect(r, 10, th.get(card));
                var it = self.children(id);
                var prev: ?NodeId = null;
                while (it.next()) |c| {
                    if (prev) |p| {
                        const pr = self.nodes.items[p].rect;
                        const indent: i32 = if (self.nodes.items[p].badge.len > 0) 56 else 16;
                        cv.hairlineH(r.x + indent, pr.bottom(), r.w - indent, th.get(.hairline).fade(0.7));
                    }
                    self.drawNode(cv, c);
                    prev = c;
                }
            },
            .list_row => self.drawRow(cv, n, hovered, pressed, focused),
            .scroll => {
                const old = cv.pushClip(r);
                var it = self.children(id);
                while (it.next()) |c| self.drawNode(cv, c);
                cv.popClip(old);
                // A thin bar at the edge says how much is hidden and where.
                const sc = n.scroller;
                if (sc.max > 0) {
                    const total = sc.max + @as(f32, @floatFromInt(r.h));
                    const hh: f32 = @max(24, @as(f32, @floatFromInt(r.h)) * @as(f32, @floatFromInt(r.h)) / total);
                    const ty = @as(f32, @floatFromInt(r.y)) + (@as(f32, @floatFromInt(r.h)) - hh) * sc.pos / sc.max;
                    cv.fillRoundRect(.{ .x = r.right() - 5, .y = @intFromFloat(ty), .w = 3, .h = @intFromFloat(hh) }, 1.5, th.get(.text_dim).fade(0.35));
                }
            },
            .label => {
                const role: Role = if (n.enabled) n.label.role else .text_disabled;
                _ = cv.textEllipsis(@floatFromInt(r.x), @floatFromInt(r.y), n.text, @floatFromInt(r.w + 1), n.label.style, th.get(role));
            },
            .button => self.drawButton(cv, n, hovered, pressed, focused),
            .toggle => self.drawToggle(cv, n, hovered, focused),
            .checkbox => self.drawCheckbox(cv, n, hovered, focused),
            .progress => drawProgress(cv, th, r, n.value, self.now),
            .separator => cv.hairlineH(r.x, r.y + @divTrunc(r.h, 2), r.w, th.get(.hairline)),
            .spacer => {},
            .text_field => n.field.?.draw(cv, r, th, focused),
            .doc_view => {
                n.doc.?.draw(cv, th, self.now);
                if (focused and self.focus_visible) cv.strokeRect(r, 2, th.get(.focus_ring).withAlpha(120));
            },
        }
    }

    fn focusRing(self: *Window, cv: *Canvas, r: Rect, radius: f32) void {
        if (!self.focus_visible) return;
        cv.strokeRoundRect(r.inset(-3), radius + 3, 2, self.theme.get(.focus_ring));
    }

    fn drawButton(self: *Window, cv: *Canvas, n: *Node, hovered: bool, pressed: bool, focused: bool) void {
        const th = &self.theme;
        const r = n.rect;
        if (n.button.plain) {
            // Text only: a tint on hover; disabled is gray and struck.
            if (n.enabled and hovered) cv.fillRoundRect(r, 6, th.get(.accent).fade(if (pressed) 0.18 else 0.10));
            const style: font.Style = if (n.button.primary) .{ .weight = .semibold } else .{};
            const ts = self.textSize(n.text, style);
            const tx: f32 = @floatFromInt(r.x + @divTrunc(r.w - ts.w, 2));
            const ty: f32 = @floatFromInt(r.y + @divTrunc(r.h - ts.h, 2));
            _ = cv.text(tx, ty, n.text, style, th.get(if (n.enabled) .accent else .text_disabled));
            if (!n.enabled) cv.line(tx, ty + @as(f32, @floatFromInt(ts.h)) / 2, tx + @as(f32, @floatFromInt(ts.w)), ty + @as(f32, @floatFromInt(ts.h)) / 2, 1, th.get(.text_disabled).withAlpha(140));
            if (focused) self.focusRing(cv, r, 6);
            return;
        }
        var bg = if (n.button.primary) th.get(.accent) else th.get(.surface_alt);
        if (!n.enabled) bg = th.get(.surface_alt);
        if (n.enabled and hovered) bg = if (n.button.primary) th.get(.accent_hover) else bg.mix(th.get(.text), 0.06);
        if (n.enabled and pressed) bg = bg.mix(th.get(.text), 0.12);
        cv.fillRoundRect(r, 6, bg);
        if (!n.button.primary or !n.enabled) cv.strokeRoundRect(r, 6, 0, th.get(.border));
        const role: Role = if (!n.enabled) .text_disabled else if (n.button.primary) .accent_text else .text;
        const ts = self.textSize(n.text, .{});
        const dy: f32 = if (pressed) 1 else 0;
        _ = cv.text(@floatFromInt(r.x + @divTrunc(r.w - ts.w, 2)), @as(f32, @floatFromInt(r.y + @divTrunc(r.h - ts.h, 2))) + dy, n.text, .{}, th.get(role));
        if (!n.enabled) cv.line(@floatFromInt(r.x + 6), @floatFromInt(r.bottom() - 6), @floatFromInt(r.right() - 6), @floatFromInt(r.y + 6), 1, th.get(.text_disabled).withAlpha(90));
        if (focused) self.focusRing(cv, r, 6);
    }

    fn drawRow(self: *Window, cv: *Canvas, n: *Node, hovered: bool, pressed: bool, focused: bool) void {
        const th = &self.theme;
        const r = n.rect;
        const active = n.enabled and (n.toggles or n.button.on_click != null);
        if (active and hovered) cv.fillRoundRect(r.inset(2), 8, th.get(.text).fade(if (pressed) 0.10 else 0.05));
        const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
        const text_role: Role = if (n.enabled) .text else .text_disabled;
        var x: i32 = r.x + 16;
        if (n.badge.len > 0) {
            // The code in an outlined key.
            const bs: font.Style = .{ .size = .small, .weight = .semibold };
            const bw = @max(28, self.textSize(n.badge, bs).w + 10);
            const key = Rect{ .x = x, .y = @as(i32, @intFromFloat(cy)) - 9, .w = bw, .h = 18 };
            cv.strokeRoundRect(key, 4, 1.2, th.get(if (n.enabled) .text_dim else .text_disabled));
            const ts = self.textSize(n.badge, bs);
            _ = cv.text(@floatFromInt(key.x + @divTrunc(key.w - ts.w, 2)), @floatFromInt(key.y + @divTrunc(key.h - ts.h, 2)), n.badge, bs, th.get(text_role));
            x += 40;
        }
        // The end: the accessory.
        var end = r.right() - 16;
        const t = n.knob.value(self.now);
        switch (n.accessory) {
            .none => {},
            .check => {
                // The check mark: a shape, not a color; gray when the row
                // cannot be changed.
                if (n.toggle.on) {
                    const c = th.get(if (n.enabled) .accent else .text_disabled);
                    const ex: f32 = @floatFromInt(end - 8);
                    cv.line(ex - 6, cy, ex - 2, cy + 4, 2, c);
                    cv.line(ex - 2, cy + 4, ex + 6, cy - 5, 2, c);
                }
                end -= 28;
            },
            .chevron => {
                const ex: f32 = @floatFromInt(end - 6);
                const c = th.get(.text_dim);
                cv.line(ex - 2, cy - 5, ex + 3, cy, 1.7, c);
                cv.line(ex + 3, cy, ex - 2, cy + 5, 1.7, c);
                end -= 28;
            },
            .toggle => {
                const track = Rect{ .x = end - 34, .y = @as(i32, @intFromFloat(cy)) - 10, .w = 34, .h = 20 };
                var bg = th.get(.surface_sunken).mix(th.get(.accent), t);
                if (!n.enabled) bg = th.get(.surface_sunken);
                cv.fillRoundRect(track, 10, bg);
                cv.strokeRoundRect(track, 10, 0, th.get(.border).fade(1 - t * 0.7));
                const kx: f32 = @as(f32, @floatFromInt(track.x + 10)) + t * 14;
                cv.fillCircle(kx, cy + 0.5, 8, th.get(.shadow));
                cv.fillCircle(kx, cy, 8, if (th.dark) .rgb(0xE8ECF2) else .rgb(0xFFFFFF));
                end -= 50;
            },
            .value => {
                const ts = self.textSize(n.value_text, .{});
                _ = cv.text(@floatFromInt(end - 16 - ts.w), @floatFromInt(@as(i32, @intFromFloat(cy)) - @divTrunc(ts.h, 2)), n.value_text, .{}, th.get(.text_dim));
                const ex: f32 = @floatFromInt(end - 6);
                cv.line(ex - 2, cy - 5, ex + 3, cy, 1.7, th.get(.text_dim));
                cv.line(ex + 3, cy, ex - 2, cy + 5, 1.7, th.get(.text_dim));
                end -= ts.w + 36;
            },
        }
        const max_w: f32 = @floatFromInt(@max(0, end - x));
        const title_h = self.textSize(n.text, .{}).h;
        if (n.subtitle.len > 0) {
            const sub_h = self.textSize(n.subtitle, .{ .size = .small }).h;
            const top = cy - @as(f32, @floatFromInt(title_h + sub_h)) / 2;
            _ = cv.textEllipsis(@floatFromInt(x), top, n.text, max_w, .{}, th.get(text_role));
            _ = cv.textEllipsis(@floatFromInt(x), top + @as(f32, @floatFromInt(title_h)), n.subtitle, max_w, .{ .size = .small }, th.get(if (n.enabled) .text_dim else .text_disabled));
        } else {
            _ = cv.textEllipsis(@floatFromInt(x), cy - @as(f32, @floatFromInt(title_h)) / 2, n.text, max_w, .{}, th.get(text_role));
        }
        if (focused) self.focusRing(cv, r.inset(2), 8);
    }

    fn drawToggle(self: *Window, cv: *Canvas, n: *Node, hovered: bool, focused: bool) void {
        const th = &self.theme;
        const r = n.rect;
        const track = Rect{ .x = r.x, .y = r.y + 2, .w = 34, .h = 20 };
        const t = n.knob.value(self.now);
        const off_bg = th.get(.surface_sunken);
        var bg = off_bg.mix(th.get(.accent), t);
        if (hovered) bg = bg.mix(th.get(.text), 0.06);
        if (!n.enabled) bg = th.get(.surface_alt);
        cv.fillRoundRect(track, 10, bg);
        cv.strokeRoundRect(track, 10, 0, th.get(.border).fade(1 - t * 0.7));
        // Shape cue besides color: a bar when on, a ring when off.
        const fy: f32 = @floatFromInt(track.y + 10);
        if (t > 0.5) {
            cv.line(@floatFromInt(track.x + 10), fy - 4, @floatFromInt(track.x + 10), fy + 4, 1.5, th.get(.accent_text).fade((t - 0.5) * 2));
        } else {
            const ring = th.get(.text_dim).fade((0.5 - t) * 2);
            cv.fillCircle(@floatFromInt(track.right() - 9), fy, 3.5, ring);
            cv.fillCircle(@floatFromInt(track.right() - 9), fy, 2.2, bg);
        }
        const kx: f32 = @as(f32, @floatFromInt(track.x + 10)) + t * 14;
        cv.fillCircle(kx, fy + 0.5, 8, th.get(.shadow));
        cv.fillCircle(kx, fy, 8, if (th.dark) .rgb(0xE8ECF2) else .rgb(0xFFFFFF));
        const ts = self.textSize(n.text, .{});
        _ = cv.text(@floatFromInt(track.right() + 10), @floatFromInt(r.y + @divTrunc(r.h - ts.h, 2)), n.text, .{}, th.get(if (n.enabled) .text else .text_disabled));
        if (focused) self.focusRing(cv, track, 10);
    }

    fn drawCheckbox(self: *Window, cv: *Canvas, n: *Node, hovered: bool, focused: bool) void {
        const th = &self.theme;
        const r = n.rect;
        const box = Rect{ .x = r.x, .y = r.y + 4, .w = 16, .h = 16 };
        if (n.toggle.on) {
            cv.fillRoundRect(box, 4, th.get(.accent));
            const x: f32 = @floatFromInt(box.x);
            const y: f32 = @floatFromInt(box.y);
            cv.line(x + 4, y + 8.5, x + 7, y + 11.5, 2, th.get(.accent_text));
            cv.line(x + 7, y + 11.5, x + 12, y + 5, 2, th.get(.accent_text));
        } else {
            cv.fillRoundRect(box, 4, if (hovered) th.get(.surface_alt) else th.get(.surface));
            cv.strokeRoundRect(box, 4, 1, th.get(.text_dim));
        }
        const ts = self.textSize(n.text, .{});
        _ = cv.text(@floatFromInt(box.right() + 8), @floatFromInt(r.y + @divTrunc(r.h - ts.h, 2)), n.text, .{}, th.get(if (n.enabled) .text else .text_disabled));
        if (focused) self.focusRing(cv, box, 4);
    }

    fn drawProgress(cv: *Canvas, th: *const Theme, r: Rect, value: ?f32, now: i64) void {
        const track = Rect{ .x = r.x, .y = r.y + @divTrunc(r.h - 6, 2), .w = r.w, .h = 6 };
        cv.fillRoundRect(track, 3, th.get(.surface_sunken));
        if (value) |v| {
            const w: i32 = @intFromFloat(@as(f32, @floatFromInt(track.w)) * std.math.clamp(v, 0, 1));
            if (w > 0) cv.fillRoundRect(.{ .x = track.x, .y = track.y, .w = @max(w, 6), .h = 6 }, 3, th.get(.accent));
        } else {
            // Unknown length: a short segment moving slowly, never blinking.
            const period: i64 = 1800 * ms;
            const f: f32 = @as(f32, @floatFromInt(@mod(now, period))) / @as(f32, @floatFromInt(period));
            const seg = @divTrunc(track.w, 4);
            const x = track.x - seg + @as(i32, @intFromFloat(f * @as(f32, @floatFromInt(track.w + seg))));
            const old = cv.pushClip(track);
            cv.fillRoundRect(.{ .x = x, .y = track.y, .w = seg, .h = 6 }, 3, th.get(.accent));
            cv.popClip(old);
        }
    }

    fn drawEnlargement(self: *Window, cv: *Canvas) void {
        const t = self.enl_t.value(self.now);
        if (t <= 0.01) return;
        const th = &self.theme;
        const style: font.Style = .{ .size = self.enlarge.size };
        const ts = self.textSize(self.enl_text, style);
        const final = Size{ .w = ts.w + 24, .h = ts.h + 14 };
        const src = self.enl_rect;
        // Grow from the widget's own size, centered over it, clamped.
        const w: i32 = src.w + @as(i32, @intFromFloat(@as(f32, @floatFromInt(final.w - src.w)) * t));
        const h: i32 = src.h + @as(i32, @intFromFloat(@as(f32, @floatFromInt(final.h - src.h)) * t));
        var box = Rect{ .x = src.x + @divTrunc(src.w - w, 2), .y = src.y + @divTrunc(src.h - h, 2), .w = w, .h = h };
        box = box.clampInto(.{ .x = 4, .y = 4, .w = self.size.w - 8, .h = self.size.h - 8 });
        cv.fillRoundRect(box.translate(0, 3), 8, th.get(.shadow).fade(t));
        cv.fillRoundRect(box, 8, th.get(.surface).fade(t));
        cv.strokeRoundRect(box, 8, 0, th.get(.border).fade(t));
        if (t > 0.4) {
            const a = (t - 0.4) / 0.6;
            const old = cv.pushClip(box);
            defer cv.popClip(old);
            _ = cv.text(@floatFromInt(box.x + @divTrunc(box.w - ts.w, 2)), @floatFromInt(box.y + @divTrunc(box.h - ts.h, 2)), self.enl_text, style, th.get(.text).fade(a));
        }
    }

    /// The size the content needs (Widget Framework, "Optimal size"): the
    /// app's hint when it gives one (w or h > 0), otherwise measured from
    /// the widget tree, so a window is never wider than its content.
    pub fn optimalSize(self: *Window) Size {
        const hint = self.opts.optimal;
        if (hint.w > 0 and hint.h > 0) return hint;
        const natural = self.measure(self.root, if (hint.w > 0) hint.w else 4000);
        return .{
            .w = if (hint.w > 0) hint.w else natural.w,
            .h = if (hint.h > 0) hint.h else natural.h,
        };
    }

    // ------------------------------------------------------------ surface

    pub fn surface(self: *Window) surface_mod.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: surface_mod.Surface.VTable = .{
        .title = struct {
            fn f(p: *anyopaque) []const u8 {
                return cast(p).opts.title;
            }
        }.f,
        .app_id = struct {
            fn f(p: *anyopaque) []const u8 {
                return cast(p).opts.app_id;
            }
        }.f,
        .menu = struct {
            fn f(p: *anyopaque) []const []const u8 {
                return cast(p).opts.menu;
            }
        }.f,
        .optimal_size = struct {
            fn f(p: *anyopaque) Size {
                return cast(p).optimalSize();
            }
        }.f,
        .growable = struct {
            fn f(p: *anyopaque) bool {
                const w = cast(p);
                // A document view reflows into any width.
                for (w.nodes.items) |n| {
                    if (n.kind == .doc_view) return true;
                }
                return false;
            }
        }.f,
        .configure = struct {
            fn f(p: *anyopaque, size: Size, scale: i32) void {
                const w = cast(p);
                if (w.size.w != size.w or w.size.h != size.h or w.scale != scale) {
                    w.size = size;
                    w.scale = scale;
                    w.laid_out = false;
                    w.dirty = true;
                }
            }
        }.f,
        .set_dark = struct {
            fn f(p: *anyopaque, dark: bool) void {
                const w = cast(p);
                if (w.theme.dark == dark) return;
                w.theme = if (dark) Theme.darkTheme() else Theme.light();
                w.dirty = true;
            }
        }.f,
        .draw = struct {
            fn f(p: *anyopaque, cv: *Canvas) void {
                cast(p).draw(cv);
            }
        }.f,
        .input = struct {
            fn f(p: *anyopaque, ev: Event, now: i64) void {
                cast(p).handleInput(ev, now);
            }
        }.f,
        .tick = struct {
            fn f(p: *anyopaque, now: i64) bool {
                return cast(p).tick(now);
            }
        }.f,
        .status = struct {
            fn f(p: *anyopaque) surface_mod.Status {
                return cast(p).status_value;
            }
        }.f,
        .cursor = struct {
            fn f(p: *anyopaque) core.input.Cursor {
                const w = cast(p);
                const h = w.hover orelse return .arrow;
                return switch (w.nodes.items[h].kind) {
                    .text_field => .text,
                    .button, .toggle, .checkbox => .hand,
                    .list_row => if (w.nodes.items[h].toggles or w.nodes.items[h].button.on_click != null) .hand else .arrow,
                    else => .arrow,
                };
            }
        }.f,
        .wants_close = struct {
            fn f(p: *anyopaque) bool {
                return cast(p).close_requested;
            }
        }.f,
        .destroy = struct {
            fn f(p: *anyopaque) void {
                cast(p).destroy();
            }
        }.f,
        .take_dialog = struct {
            fn f(p: *anyopaque) ?surface_mod.Surface.DialogRequest {
                const w = cast(p);
                const d = w.pending_dialog;
                w.pending_dialog = null;
                return d;
            }
        }.f,
    };

    fn cast(p: *anyopaque) *Window {
        return @ptrCast(@alignCast(p));
    }
};

test "layout and click" {
    const gpa = std.testing.allocator;
    const win = try Window.create(gpa, .{ .title = "t", .app_id = "test", .optimal = .{ .w = 300, .h = 200 } });
    defer win.destroy();
    const col = try win.column(null, .{ .padding = 10 });
    const Ctx = struct {
        clicks: u32 = 0,
        fn onClick(self: *@This(), _: *Window, _: NodeId) void {
            self.clicks += 1;
        }
    };
    var ctx: Ctx = .{};
    const b = try win.button(col, "Press", .{ .on_click = callback(&ctx, Ctx.onClick) });
    const t = try win.toggle(col, "Option", .{});
    win.surface().configure(.{ .w = 300, .h = 200 }, 1);

    var px: [300 * 200]u32 = undefined;
    var cv = Canvas.init(&px, 300, 200, 300, 1);
    win.draw(&cv);

    const br = win.node(b).rect;
    const x: f32 = @floatFromInt(br.x + 5);
    const y: f32 = @floatFromInt(br.y + 5);
    win.handleInput(.{ .pointer_motion = .{ .x = x, .y = y } }, 0);
    win.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, 0);
    win.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, 0);
    try std.testing.expectEqual(@as(u32, 1), ctx.clicks);

    // Keyboard: Tab to the toggle, Space flips it.
    win.handleInput(.{ .key = .{ .key = .tab, .pressed = true, .mods = .{} } }, 0);
    win.handleInput(.{ .key = .{ .key = .space, .pressed = true, .mods = .{} } }, 0);
    try std.testing.expect(win.isOn(t));
}

test "mobile widgets: header bar, search, grouped list, rows, scrolling" {
    const gpa = std.testing.allocator;
    const win = try Window.create(gpa, .{ .title = "t", .app_id = "test", .optimal = .{ .w = 320, .h = 300 }, .background = .surface_alt });
    defer win.destroy();
    const Ctx = struct {
        done: u32 = 0,
        changes: u32 = 0,
        typed: u32 = 0,
        fn onDone(self: *@This(), _: *Window, _: NodeId) void {
            self.done += 1;
        }
        fn onChange(self: *@This(), _: *Window, _: NodeId) void {
            self.changes += 1;
        }
        fn onType(self: *@This(), _: *Window, _: NodeId) void {
            self.typed += 1;
        }
    };
    var ctx: Ctx = .{};
    const col = try win.column(null, .{ .padding = 0, .spacing = 0 });
    const hb = try win.headerBar(col, .{ .title = "Languages", .leading = "Cancel", .trailing = "Done", .on_trailing = callback(&ctx, Ctx.onDone) });
    const search = try win.searchField(col, "Search", callback(&ctx, Ctx.onType));
    const body = try win.scrollArea(col, 0, .{ .padding = 12, .spacing = 16 });
    const card = try win.list(body, .{ .header = "ALL", .footer = "At least one stays." });
    var rows: [10]NodeId = undefined;
    for (&rows, 0..) |*r, i| r.* = try win.listRow(card, if (i == 0) "English" else "Other", .{ .badge = "EN", .accessory = .check, .toggles = true, .on = i == 0, .on_change = callback(&ctx, Ctx.onChange) });
    win.surface().configure(.{ .w = 320, .h = 300 }, 1);
    var px: [320 * 300]u32 = undefined;
    var cv = Canvas.init(&px, 320, 300, 320, 1);
    win.draw(&cv);

    // The title is centered on the bar.
    const bar = win.node(hb.bar).rect;
    const t = win.node(hb.title).rect;
    try std.testing.expect(@abs((t.x + @divTrunc(t.w, 2)) - (bar.x + @divTrunc(bar.w, 2))) <= 1);

    // A click on a row flips its check mark.
    const r1 = win.node(rows[1]).rect;
    const click = struct {
        fn at(w: *Window, x: i32, y: i32) void {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            w.handleInput(.{ .pointer_motion = .{ .x = fx, .y = fy } }, 0);
            w.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = fx, .y = fy } }, 0);
            w.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = fx, .y = fy } }, 0);
        }
    }.at;
    click(win, r1.x + 40, r1.y + 10);
    try std.testing.expect(win.isOn(rows[1]));
    try std.testing.expectEqual(@as(u32, 1), ctx.changes);

    // Ten rows do not fit: the area scrolls, and the rows move up.
    win.handleInput(.{ .pointer_motion = .{ .x = 100, .y = 200 } }, 0);
    win.handleInput(.{ .wheel = .{ .dy = 2 } }, 0);
    var now: i64 = 0;
    for (0..30) |_| {
        now += 16 * ms;
        _ = win.tick(now);
    }
    win.draw(&cv);
    try std.testing.expect(win.node(rows[1]).rect.y < r1.y);

    // Typing into the search calls back; hidden rows take no room.
    const sr = win.node(search).rect;
    click(win, sr.x + 40, sr.y + 10);
    win.handleInput(.{ .text = core.input.Text.from("en") }, 0);
    try std.testing.expectEqual(@as(u32, 1), ctx.typed);
    for (rows[1..]) |r| win.setHidden(r, true);
    win.draw(&cv);
    try std.testing.expectEqualStrings("en", win.fieldText(search));
    // The clear button empties it and calls back.
    click(win, win.node(search).rect.right() - 8, sr.y + 10);
    try std.testing.expectEqualStrings("", win.fieldText(search));
    try std.testing.expectEqual(@as(u32, 2), ctx.typed);

    // Enter, with the focus on nothing that takes it: Done.
    click(win, 300, 290);
    win.handleInput(.{ .key = .{ .key = .enter, .pressed = true, .mods = .{} } }, 0);
    try std.testing.expectEqual(@as(u32, 1), ctx.done);
}
