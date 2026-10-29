//! Controls: the app that shows every widget's behavior, so each one can be
//! checked as it is built. It grows with the widget library: every new
//! widget or behavior gets a place here.
//!
//! Five windows, to exercise the window behavior with three growable and
//! two small fixed-size apps:
//!  - Controls     buttons, toggles, checkboxes, progress, text fields,
//!                 window status, hover enlargement (fixed size)
//!  - Scroll Lab   the document view: wheel bands, map, markers, back
//!  - Notes        a second document, takes any size (growable)
//!  - Reader       a third document, takes any size (growable)
//!  - Stopwatch    a small app (fixed size)

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");

const Window = tw.Window;
const NodeId = tw.NodeId;
const ms = std.time.ns_per_ms;

// ================================================================ Controls

const Controls = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    clicked: NodeId = 0,
    clicks: u32 = 0,
    task_bar: NodeId = 0,
    task_label: NodeId = 0,
    task_start: ?i64 = null,
    toggles_label: NodeId = 0,
    field_echo: NodeId = 0,
    name_field: NodeId = 0,
    buf: [128]u8 = undefined,

    fn onButton(self: *Controls, win: *Window, id: NodeId) void {
        self.clicks += 1;
        const t = std.fmt.bufPrint(&self.buf, "Clicked: {s} ({d})", .{ win.node(id).text, self.clicks }) catch return;
        win.setText(self.clicked, t);
    }

    fn onToggle(self: *Controls, win: *Window, id: NodeId) void {
        const t = std.fmt.bufPrint(&self.buf, "{s}: {s}", .{ win.node(id).text, if (win.isOn(id)) "on" else "off" }) catch return;
        win.setText(self.toggles_label, t);
    }

    fn onRunTask(self: *Controls, win: *Window, _: NodeId) void {
        self.task_start = win.now;
    }

    fn onStatus(self: *Controls, win: *Window, id: NodeId) void {
        _ = self;
        const label = win.node(id).text;
        if (std.mem.eql(u8, label, "Normal")) win.setStatus(.normal, 0);
        if (std.mem.eql(u8, label, "Progress")) win.setStatus(.progress, 0.6);
        if (std.mem.eql(u8, label, "Working")) win.setStatus(.working, 0);
        if (std.mem.eql(u8, label, "Error")) win.setStatus(.failed, 0);
    }

    fn onSubmit(self: *Controls, win: *Window, id: NodeId) void {
        const t = std.fmt.bufPrint(&self.buf, "Submitted: {s}", .{win.fieldText(id)}) catch return;
        win.setText(self.field_echo, t);
    }

    fn tick(p: *anyopaque, win: *Window, now: i64) void {
        const self: *Controls = @ptrCast(@alignCast(p));
        const start = self.task_start orelse return;
        const f: f32 = @as(f32, @floatFromInt(now - start)) / @as(f32, @floatFromInt(4000 * ms));
        if (f >= 1) {
            self.task_start = null;
            win.setValue(self.task_bar, 1);
            win.setText(self.task_label, "Task finished");
            win.setStatus(.normal, 0);
            return;
        }
        win.setValue(self.task_bar, f);
        // The window's bottom border shows the same progress.
        win.setStatus(.progress, f);
        const t = std.fmt.bufPrint(&self.buf, "Running: {d:.0}%", .{f * 100}) catch return;
        win.setText(self.task_label, t);
    }

    fn free(p: *anyopaque) void {
        const self: *Controls = @ptrCast(@alignCast(p));
        self.gpa.destroy(self);
    }
};

fn sectionTitle(win: *Window, parent: NodeId, text: []const u8) !void {
    _ = try win.label(parent, text, .{ .style = .{ .size = .small, .weight = .semibold }, .role = .text_dim });
}

fn card(win: *Window, parent: NodeId, title: []const u8) !NodeId {
    const c = try win.column(parent, .{ .padding = 14, .spacing = 10, .card = true });
    try sectionTitle(win, c, title);
    return c;
}

pub fn createControls(gpa: std.mem.Allocator) !tw.Surface {
    const win = try Window.create(gpa, .{
        .title = "Controls",
        .app_id = "org.kuroko.controls",
        // Measured from the widgets, so the window is only as wide as needed.
        .optimal = .{ .w = 0, .h = 0 },
    });
    errdefer win.destroy();
    const app = try gpa.create(Controls);
    app.* = .{ .gpa = gpa, .win = win };
    win.on_destroy = .{ .ctx = app, .func = Controls.free };
    win.on_tick = .{ .ctx = app, .func = Controls.tick };

    const root = try win.column(null, .{ .padding = 20, .spacing = 14 });
    _ = try win.label(root, "Controls", .{ .style = .{ .size = .title, .weight = .semibold } });
    _ = try win.label(root, "Every widget, as it is built. Rest the pointer on small text for a second to enlarge it.", .{ .style = .{ .size = .small }, .role = .text_dim });

    const cols = try win.row(root, .{ .spacing = 14 });
    const left = try win.column(cols, .{ .spacing = 14 });
    const right = try win.column(cols, .{ .spacing = 14 });

    // Buttons.
    {
        const c = try card(win, left, "BUTTONS");
        const r = try win.row(c, .{ .spacing = 8 });
        _ = try win.button(r, "Save", .{ .primary = true, .on_click = tw.callback(app, Controls.onButton) });
        _ = try win.button(r, "Cancel", .{ .on_click = tw.callback(app, Controls.onButton) });
        const d = try win.button(r, "Unavailable", .{});
        win.setEnabled(d, false);
        app.clicked = try win.label(c, "Clicked: nothing yet", .{ .style = .{ .size = .small }, .role = .text_dim });
    }
    // Toggles and checkboxes.
    {
        const c = try card(win, left, "TOGGLES AND CHECKBOXES");
        _ = try win.toggle(c, "Wi-Fi", .{ .on = true, .on_change = tw.callback(app, Controls.onToggle) });
        _ = try win.toggle(c, "Bluetooth", .{ .on_change = tw.callback(app, Controls.onToggle) });
        _ = try win.checkbox(c, "Show hidden files", .{ .on_change = tw.callback(app, Controls.onToggle) });
        _ = try win.checkbox(c, "Remember this choice", .{ .on = true, .on_change = tw.callback(app, Controls.onToggle) });
        app.toggles_label = try win.label(c, "Space toggles the focused one; Tab moves focus", .{ .style = .{ .size = .small }, .role = .text_dim });
    }
    // Progress.
    {
        const c = try card(win, left, "PROGRESS");
        app.task_bar = try win.progress(c, 0);
        const r = try win.row(c, .{ .spacing = 10 });
        _ = try win.button(r, "Run task", .{ .on_click = tw.callback(app, Controls.onRunTask) });
        app.task_label = try win.label(r, "Also drives the window's bottom border", .{ .style = .{ .size = .small }, .role = .text_dim });
        _ = try win.label(c, "Unknown length: a slow segment, never blinking", .{ .style = .{ .size = .small }, .role = .text_dim });
        _ = try win.progress(c, null);
    }
    // Text fields.
    {
        const c = try card(win, right, "TEXT FIELDS");
        app.name_field = try win.textField(c, "", .{ .placeholder = "Your name (Enter submits)", .length_lt = 28, .min_px = 220 });
        win.node(app.name_field).on_submit = tw.callback(app, Controls.onSubmit);
        _ = try win.textField(c, "  indented: try Home twice", .{ .length_lt = 28, .min_px = 220 });
        _ = try win.textField(c, "Read-only: selectable, not editable", .{ .length_lt = 28, .min_px = 220, .state = .read_only });
        _ = try win.textField(c, "Disabled", .{ .length_lt = 28, .min_px = 220, .state = .disabled });
        _ = try win.textField(c, "secret", .{ .length_lt = 28, .min_px = 220, .password = true });
        _ = try win.textField(c, "A long value that does not fit in the field is cut with an ellipsis at the end", .{ .length_lt = 28, .min_px = 220 });
        app.field_echo = try win.label(c, "Ctrl+\u{2190}/\u{2192} words, Shift extends, Ctrl+A all", .{ .style = .{ .size = .small }, .role = .text_dim });
    }
    // Window status on the bottom border.
    {
        const c = try card(win, right, "WINDOW STATUS (BOTTOM BORDER)");
        // Rows do not wrap yet, so two rows of two.
        for ([_][2][]const u8{ .{ "Normal", "Progress" }, .{ "Working", "Error" } }) |pair| {
            const r = try win.row(c, .{ .spacing = 8 });
            for (pair) |s| _ = try win.button(r, s, .{ .on_click = tw.callback(app, Controls.onStatus) });
        }
        _ = try win.label(c, "Error is red and dashed, with an icon in the title bar", .{ .style = .{ .size = .small }, .role = .text_dim });
    }
    return win.surface();
}

// ============================================================== Scroll Lab

const ScrollLab = struct {
    gpa: std.mem.Allocator,
    blocks: []tw.Block,
    strings: std.ArrayList([]u8) = .empty,
    doc: NodeId = 0,
    stats: NodeId = 0,
    buf: [160]u8 = undefined,

    fn tick(p: *anyopaque, win: *Window, _: i64) void {
        const self: *ScrollLab = @ptrCast(@alignCast(p));
        const d = win.doc(self.doc);
        const pps = d.scroller.pagesPerSecond();
        const t = if (d.scroller.screenTime()) |st|
            std.fmt.bufPrint(&self.buf, "Band: {s}   {d:.2} pages/s   screen time {d:.2} s", .{ @tagName(d.band()), pps, st }) catch return
        else
            std.fmt.bufPrint(&self.buf, "Band: {s}   at rest   line {d:.0} of {d:.0}", .{ @tagName(d.band()), d.scroller.pos / d.line_h + 1, d.content_h / d.line_h }) catch return;
        win.setText(self.stats, t);
    }

    fn free(p: *anyopaque) void {
        const self: *ScrollLab = @ptrCast(@alignCast(p));
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
        self.gpa.free(self.blocks);
        self.gpa.destroy(self);
    }
};

const words = [_][]const u8{
    "window", "layout", "screen", "focus",   "attention", "reading", "pointer", "scroll",  "content", "habit",
    "glance", "context", "desktop", "memory", "prediction", "line", "page", "section", "border", "status",
    "calm", "quick", "steady", "simple",   "visible",  "stable", "small", "large", "near", "far",
    "the", "a", "of", "and", "to", "in", "is", "with", "for", "on", "that", "as", "it", "by", "every", "each",
};

const topics = [_][]const u8{
    "Reading width", "Attention tiling", "Speed bands", "The document map", "Footprints", "Screen time",
    "Viewport marker", "Center marker", "Jumping back", "Stable positions", "Shift to run", "Hover enlargement",
};

fn sentence(gpa: std.mem.Allocator, rng: std.Random, list: *std.ArrayList([]u8), n_sent: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..n_sent) |s| {
        const n = rng.intRangeAtMost(usize, 7, 16);
        for (0..n) |i| {
            const w = words[rng.uintLessThan(usize, words.len)];
            if (i == 0) {
                try out.append(gpa, std.ascii.toUpper(w[0]));
                try out.appendSlice(gpa, w[1..]);
            } else try out.appendSlice(gpa, w);
            try out.append(gpa, if (i + 1 == n) '.' else ' ');
        }
        if (s + 1 < n_sent) try out.append(gpa, ' ');
    }
    const owned = try out.toOwnedSlice(gpa);
    try list.append(gpa, owned);
    return owned;
}

pub fn createScrollLab(gpa: std.mem.Allocator) !tw.Surface {
    const app = try gpa.create(ScrollLab);
    errdefer gpa.destroy(app);
    app.* = .{ .gpa = gpa, .blocks = &.{} };

    // A long generated document: 48 sections with paragraphs and figures.
    var prng = std.Random.DefaultPrng.init(0x7E55E11C);
    const rng = prng.random();
    var blocks: std.ArrayList(tw.Block) = .empty;
    errdefer blocks.deinit(gpa);
    for (0..48) |s| {
        const title = try std.fmt.allocPrint(gpa, "{d}. {s}", .{ s + 1, topics[s % topics.len] });
        try app.strings.append(gpa, title);
        try blocks.append(gpa, .{ .kind = .heading, .text = title });
        const paras = rng.intRangeAtMost(usize, 2, 5);
        for (0..paras) |p| {
            try blocks.append(gpa, .{ .kind = .paragraph, .text = try sentence(gpa, rng, &app.strings, rng.intRangeAtMost(usize, 3, 7)) });
            if (s % 3 == 1 and p == 0) {
                const cap = try std.fmt.allocPrint(gpa, "Figure {d}: a shape the eye can find on the map", .{s + 1});
                try app.strings.append(gpa, cap);
                try blocks.append(gpa, .{ .kind = .figure, .text = cap, .lines = 9 });
            }
        }
    }
    app.blocks = try blocks.toOwnedSlice(gpa);

    const win = try Window.create(gpa, .{
        .title = "Scroll Lab",
        .app_id = "org.kuroko.scroll-lab",
        .optimal = .{ .w = 720, .h = 1400 },
        .menu = &.{ "File", "View", "Go", "Help" },
    });
    win.on_destroy = .{ .ctx = app, .func = ScrollLab.free };
    win.on_tick = .{ .ctx = app, .func = ScrollLab.tick };

    const root = try win.column(null, .{ .spacing = 0 });
    win.node(root).grow = true;
    const head = try win.column(root, .{ .padding = 12, .spacing = 4 });
    app.stats = try win.label(head, "Band: slow", .{ .style = .{ .size = .body, .weight = .semibold } });
    _ = try win.label(head, "Notch: 3 lines. Keep turning: fast. Shift: run. Rest at the right edge: map. Alt+\u{2190}: back. Home/End: top/bottom.", .{ .style = .{ .size = .small }, .role = .text_dim });
    _ = try win.separator(root);
    app.doc = try win.docView(root, app.blocks);
    win.focus = app.doc;
    return win.surface();
}

// ========================================================= Notes, Reader

/// A plain document window that takes any size it is given.
const DocApp = struct {
    gpa: std.mem.Allocator,
    blocks: []tw.Block,
    strings: std.ArrayList([]u8) = .empty,

    fn free(p: *anyopaque) void {
        const self: *DocApp = @ptrCast(@alignCast(p));
        for (self.strings.items) |x| self.gpa.free(x);
        self.strings.deinit(self.gpa);
        self.gpa.free(self.blocks);
        self.gpa.destroy(self);
    }
};

fn createDoc(gpa: std.mem.Allocator, title: []const u8, app_id: []const u8, seed: u64, heads: []const []const u8, sections: usize) !tw.Surface {
    const app = try gpa.create(DocApp);
    errdefer gpa.destroy(app);
    app.* = .{ .gpa = gpa, .blocks = &.{} };
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var blocks: std.ArrayList(tw.Block) = .empty;
    errdefer blocks.deinit(gpa);
    for (0..sections) |i| {
        const h = try std.fmt.allocPrint(gpa, "{s}", .{heads[i % heads.len]});
        try app.strings.append(gpa, h);
        try blocks.append(gpa, .{ .kind = .heading, .text = h });
        for (0..rng.intRangeAtMost(usize, 1, 4)) |_|
            try blocks.append(gpa, .{ .kind = .paragraph, .text = try sentence(gpa, rng, &app.strings, rng.intRangeAtMost(usize, 2, 6)) });
    }
    app.blocks = try blocks.toOwnedSlice(gpa);

    const win = try Window.create(gpa, .{
        .title = title,
        .app_id = app_id,
        .optimal = .{ .w = 640, .h = 1000 },
        .menu = &.{ "File", "Edit", "View" },
    });
    win.on_destroy = .{ .ctx = app, .func = DocApp.free };
    const root = try win.column(null, .{ .spacing = 0 });
    win.node(root).grow = true;
    const d = try win.docView(root, app.blocks);
    win.focus = d;
    return win.surface();
}

pub fn createNotes(gpa: std.mem.Allocator) !tw.Surface {
    return createDoc(gpa, "Notes", "org.kuroko.notes", 0x0A11CE, &.{ "Monday", "Ideas", "To check", "Meeting", "Later", "Open questions" }, 24);
}

pub fn createReader(gpa: std.mem.Allocator) !tw.Surface {
    return createDoc(gpa, "Reader", "org.kuroko.reader", 0xB00C, &.{ "Chapter one", "The harbor", "Night shift", "Letters", "The long road", "Return" }, 30);
}

// =============================================================== Stopwatch

const Stopwatch = struct {
    gpa: std.mem.Allocator,
    time: NodeId = 0,
    start_btn: NodeId = 0,
    started: ?i64 = null,
    acc: i64 = 0,
    buf: [32]u8 = undefined,

    fn onStart(self: *Stopwatch, win: *Window, _: NodeId) void {
        if (self.started) |s| {
            self.acc += win.now - s;
            self.started = null;
            win.setText(self.start_btn, "Start");
            win.setStatus(.normal, 0);
        } else {
            self.started = win.now;
            win.setText(self.start_btn, "Stop");
            win.setStatus(.working, 0);
        }
    }
    fn onReset(self: *Stopwatch, win: *Window, _: NodeId) void {
        self.acc = 0;
        if (self.started != null) self.started = win.now;
        win.setText(self.time, "00:00.0");
    }
    fn tick(p: *anyopaque, win: *Window, now: i64) void {
        const self: *Stopwatch = @ptrCast(@alignCast(p));
        const s = self.started orelse return;
        const total = self.acc + now - s;
        const tenths = @divTrunc(total, 100 * ms);
        const t = std.fmt.bufPrint(&self.buf, "{d:0>2}:{d:0>2}.{d}", .{ @divTrunc(tenths, 600), @mod(@divTrunc(tenths, 10), 60), @mod(tenths, 10) }) catch return;
        win.setText(self.time, t);
    }
    fn free(p: *anyopaque) void {
        const self: *Stopwatch = @ptrCast(@alignCast(p));
        self.gpa.destroy(self);
    }
};

pub fn createStopwatch(gpa: std.mem.Allocator) !tw.Surface {
    const win = try Window.create(gpa, .{
        .title = "Stopwatch",
        .app_id = "org.kuroko.stopwatch",
        .optimal = .{ .w = 360, .h = 130 },
        .menu = &.{"Help"},
    });
    errdefer win.destroy();
    const app = try gpa.create(Stopwatch);
    app.* = .{ .gpa = gpa };
    win.on_destroy = .{ .ctx = app, .func = Stopwatch.free };
    win.on_tick = .{ .ctx = app, .func = Stopwatch.tick };
    const root = try win.row(null, .{ .padding = 20, .spacing = 12, .center = true });
    app.time = try win.label(root, "00:00.0", .{ .style = .{ .size = .title, .weight = .semibold } });
    _ = try win.spacer(root, 12, 1);
    app.start_btn = try win.button(root, "Start", .{ .primary = true, .on_click = tw.callback(app, Stopwatch.onStart) });
    _ = try win.button(root, "Reset", .{ .on_click = tw.callback(app, Stopwatch.onReset) });
    return win.surface();
}

test "apps build and draw" {
    const gpa = std.testing.allocator;
    inline for (.{ createControls, createScrollLab, createNotes, createReader, createStopwatch }) |create| {
        const s = try create(gpa);
        defer s.destroy();
        s.configure(.{ .w = 700, .h = 600 }, 1);
        const px = try gpa.alloc(u32, 700 * 600);
        defer gpa.free(px);
        var cv = tw.Canvas.init(px, 700, 600, 700, 1);
        s.draw(&cv);
        _ = s.tick(1000 * ms);
        s.input(.{ .wheel = .{ .dy = 1 } }, 2000 * ms);
        _ = s.tick(2100 * ms);
        s.draw(&cv);
    }
}
