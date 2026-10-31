//! Compositor core: window model, attention tiling, focus, chrome, shell UI
//! and input routing. Backend-independent: a backend (the simulator now,
//! Kuroko's own DRM/KMS backend on Linux later) feeds input events and a
//! frame clock, and presents what this core draws: pixels on the CPU, or a
//! draw list for the GPU renderer (krkgl).
//!
//! Guiding rule (Top-Level Design): the compositor owns everything the
//! user can see or touch and never waits on anything else.

const std = @import("std");
const core = @import("krkcore");
const tw = @import("krkwidgets");
const tiling = @import("tiling.zig");
const chrome = @import("chrome.zig");
const shell = @import("shell.zig");
const menus = @import("menus.zig");
const dlg = @import("dialogs.zig");
const Publisher = @import("publish.zig").Publisher;
const installed = @import("apps.zig");

const Rect = core.Rect;
const RectF = core.geom.RectF;
const Size = core.Size;
const Handle = core.Handle;
const Theme = core.Theme;
const Tween = core.anim.Tween;
const Event = core.input.Event;
const Canvas = tw.Canvas;
const Surface = tw.Surface;
const Trust = core.types.Trust;
const ms = std.time.ns_per_ms;

/// An app the compositor can launch. In the simulator apps are linked in
/// and created in-process; on Linux this becomes a desktop entry.
pub const AppEntry = struct {
    name: []const u8,
    app_id: []const u8,
    /// Simulated start-up time, so the launch placeholder can be seen.
    start_ms: u32 = 0,
    create: *const fn (std.mem.Allocator) anyerror!Surface,
};

/// Who a Wayland client is (krkwl: SO_PEERCRED, /proc/<pid>/exe).
pub const Client = struct {
    /// 0 when unknown.
    pid: i32 = 0,
    /// The binary, symlinks resolved; "" when unknown.
    exe: []const u8 = "",
};

/// A window's trust (docs/user-signals.md), for the paste check and the
/// Security menu.
pub const WindowTrust = struct {
    /// The app's part: its mark, else trusted when installed.
    app: Trust,
    /// The app and the object open in the window together.
    window: Trust,
    pid: i32,
    /// The binary the app part was decided by ("" for Kuroko's own apps).
    exe: []const u8,
    object: []const u8,
};

/// How the compositor reads the files krkdesk keeps for it (focus.krkde,
/// icons.krkde), by name. The backend does the reading; the core stays free
/// of I/O. Returns the file's bytes (owned by the caller), or null.
pub const StateReader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8,
};

pub const Params = struct {
    /// Kuroko defaults (Look and Controls, "Scroll direction").
    wheel_natural: bool = false,
    touchpad_natural: bool = true,
    dark: bool = false,
};

const Window = struct {
    app: usize,
    surface: ?Surface = null,

    pixels: []u32 = &.{},
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    /// The picture's identity for a GPU renderer: a new id for each new
    /// buffer, a new version each time it is drawn.
    image_id: u64 = 0,
    version: u64 = 0,
    content: Size = .{ .w = 0, .h = 0 },
    dirty: bool = true,

    target: Rect = .{},
    from: RectF = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    anim_start: i64 = 0,
    placed: bool = false,
    row: u8 = 0,
    shelved: bool = false,
    /// Flying into the panel: where the window was when it was shelved.
    fly_from: RectF = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    fly_start: i64 = -1,
    last_focus: i64 = 0,
    /// In a full-screen space of its own.
    fullscreen: bool = false,
    /// Where in the tiles it was before full screen, to go back there.
    fs_home: usize = 0,
    /// Zooming into full screen: from this frame.
    fs_from: RectF = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    fs_start: i64 = -1,
    /// One flash of the frame when the window is brought up, so the eye
    /// finds it; -1 when not flashing.
    flash_start: i64 = -1,

    launch_start: i64 = 0,
    /// Order of opening, for the panel's stable order.
    seq: u64 = 0,
    ready_at: i64 = 0,
    expected_ns: i64 = 0,

    buttons_t: Tween = Tween.init(0),
    aimed: u8 = 0,
    menu_t: Tween = Tween.init(0),
    menu_rest_since: ?i64 = null,
    menu_leave_since: ?i64 = null,

    status: tw.surface.Status = .{},
    /// An installed app was started and its window has not come yet.
    waiting: bool = false,
    /// The user asked to close; the app closes in its own time.
    closing: bool = false,
    /// The state last told to the surface (focused, maximized, ...).
    told_state: u8 = 0xff,

    /// Who the window belongs to: the client's process and binary (owned;
    /// empty for Kuroko's own in-process apps and before the client
    /// comes).
    pid: i32 = 0,
    exe: []u8 = &.{},
    /// The object open in the window (a file), when known; owned.
    object: []u8 = &.{},
    app_trust: Trust = .unknown,
    trust: Trust = .unknown,

    fn image(w: *const Window) tw.Image {
        return .{ .pixels = w.pixels, .w = w.buf_w, .h = w.buf_h, .id = w.image_id, .version = w.version };
    }

    /// Draws the app's content into the window's buffer if it changed.
    fn paint(w: *Window, scale: i32) void {
        const s = w.surface orelse return;
        if (!w.dirty or w.pixels.len == 0) return;
        var wc = Canvas.init(w.pixels, w.buf_w, w.buf_h, w.buf_w, scale);
        s.draw(&wc);
        w.dirty = false;
        w.version += 1;
    }
};

const anim_ms = 200;
/// An installed app that shows no window this long failed to start.
const wait_ms = 60_000;
/// Flying into the panel takes a little longer: it travels further.
const fly_ms = 260;
/// Zoom into full screen and the slide between spaces.
const space_ms = 250;
/// A drag out of the panel released this fast is a "quick drag": the window
/// goes next to the panel, whatever the drop point.
const quick_drag_ms = 300;
/// While reordering, the pointer rests this long on a tile before its
/// window moves aside, so tiles only crossed on the way stay put.
const reorder_dwell_ms = 120;
/// Two clicks within this time are a double click.
const double_click_ms = 400;
/// The outline that travels from an icon to the window it brings up.
const cue_ms = 320;
/// One flash of the window at the end of the travel (a single pulse, well
/// under the 3 per second limit).
const flash_ms = 450;
/// The slow pulse of a window's border while its enlarged view is pointed.
const pulse_ms = 1200;

/// Travel cue: from a launcher icon (or a chooser thumbnail) to a window.
/// A closed window shrinking to nothing: its last picture, owned here.
const Ghost = struct {
    pixels: []u32,
    buf_w: i32,
    buf_h: i32,
    /// The window's picture identity, kept: a GPU renderer still has it.
    image_id: u64,
    version: u64,
    frame: Rect,
    /// Where the content sits inside the frame (title bar above it).
    content: Rect,
    chrome_bar: bool,
    start: i64,
};

const Cue = struct {
    h: Handle,
    from: RectF,
    start: i64,
};

/// Several windows of one app: they float, scaled down, near the icon so
/// the right one can be picked. A last tile opens a new window.
const Chooser = struct {
    app: usize,
    items: [8]Handle = undefined,
    n: usize = 0,
    rect: Rect = .{},

    const thumb_w = 220;
    const thumb_h = 150;
    const pad = 16;
    const head = 40;

    fn slot(self: *const Chooser, i: usize) Rect {
        return .{
            .x = self.rect.x + pad + @as(i32, @intCast(i)) * (thumb_w + pad),
            .y = self.rect.y + head,
            .w = thumb_w,
            .h = thumb_h,
        };
    }

    /// Index of the tile under the point; `n` is the "New window" tile.
    fn at(self: *const Chooser, x: f32, y: f32) ?usize {
        for (0..self.n + 1) |i| {
            if (self.slot(i).contains(x, y)) return i;
        }
        return null;
    }
};

/// All windows of one app in the panel share one icon.
const Group = struct {
    app: usize,
    /// The window a click brings up: the only one, else the most recently
    /// minimized, else the most recently used one on screen.
    rep: Handle,
    count: u8,
    /// Windows on screen (tiled or full screen); the rest are minimized.
    visible: u8 = 0,
    /// When the app's first window opened: the panel keeps this order.
    first: u64 = 0,
    /// The app icon.
    rect: Rect,

    fn thumb(self: Group) Rect {
        return self.rect;
    }
};

/// The enlarged view of a panel group: one window, or all of an app's
/// windows in a grid over the window area.
const Preview = struct {
    app: usize,
    items: [8]Handle = undefined,
    n: usize = 0,
    /// The group's thumbnail, where the view grows from.
    anchor: Rect,
};

const PanelMenu = struct {
    app: usize,
    count: usize,
    visible: usize = 0,
    rect: Rect,
    const item_h = 30;
    const Item = enum { show_all, minimize_all, close_all };

    fn items(self: PanelMenu, out: *[3]Item) []Item {
        var n: usize = 0;
        if (self.count < 4 and self.visible < self.count) {
            out[n] = .show_all;
            n += 1;
        }
        if (self.visible > 0) {
            out[n] = .minimize_all;
            n += 1;
        }
        out[n] = .close_all;
        n += 1;
        return out[0..n];
    }
};

/// Buttons on the enlarged preview of a panel window.
pub const PreviewButton = enum(u8) { close, restore, maximize, fullscreen, minimize };

fn sameHandle(a: ?Handle, b: ?Handle) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

const Drag = union(enum) {
    none,
    /// Press on the title bar; becomes a reorder once it moves. `want` is
    /// the window whose tile the pointer is on (since `want_since`);
    /// `partner` the one already swapped with the dragged window, as a
    /// preview of the drop.
    title: struct {
        h: Handle,
        x: f32,
        y: f32,
        moved: bool,
        want: ?Handle = null,
        want_since: i64 = 0,
        partner: ?Handle = null,
    },
    /// Dragging a shared border: the boundary follows the pointer from
    /// where it was grabbed.
    col_border: struct { row: u8, start: f32, boundary: f32 },
    row_border: struct { start: f32, boundary: f32 },
    button: struct { h: Handle, which: chrome.Button },
    /// Press on a panel thumbnail: a click swaps or restores, a drag tiles.
    panel: struct { h: Handle, x: f32, y: f32, t0: i64, moved: bool },
    /// Press on a button of the panel preview; acts on release.
    preview_button: struct { h: Handle, which: PreviewButton },
    /// The pointer was pressed in a window's content.
    content: Handle,
    /// Dragging a volume slider in the control center.
    menu_slider: menus.Dir,
    /// The pointer was pressed in a dialog's content (its id).
    dialog: u32,
};

/// Opens Kuroko's own dialogs by name ("languages"): the desktop service
/// does it on Linux, the backend in the simulator.
pub const DesktopDialogs = struct {
    ctx: *anyopaque,
    open: *const fn (*anyopaque, name: []const u8) ?Surface,
};

const LaunchStats = struct {
    times: [5]i64 = @splat(0),
    n: usize = 0,

    fn add(self: *LaunchStats, ns: i64) void {
        self.times[self.n % self.times.len] = ns;
        self.n += 1;
    }
    /// Average of the last few starts, so one glitch has little effect.
    fn expected(self: *const LaunchStats) ?i64 {
        if (self.n == 0) return null;
        const k = @min(self.n, self.times.len);
        var sum: i64 = 0;
        for (self.times[0..k]) |t| sum += t;
        return @divTrunc(sum, @as(i64, @intCast(k)));
    }
};

pub const Compositor = struct {
    gpa: std.mem.Allocator,
    params: Params,
    theme: Theme,
    screen: Size,
    scale: i32,
    apps: []const AppEntry,
    /// The launcher's apps: the built-in ones (`apps`), then the installed
    /// apps from krkdesk's registry (`installed`), in the same order.
    app_infos: std.ArrayList(shell.AppInfo) = .empty,
    installed: installed.Registry,
    /// A snapshot of the registry was asked for and has not come yet.
    apps_asked: bool = false,
    /// See `setChildEnv`.
    child_env: []const []const u8 = &.{},
    stats: []LaunchStats,
    recent: std.ArrayList(usize) = .empty,

    windows: core.Registry(Window),
    /// Last picture id given to a window buffer (Window.image_id).
    image_seq: u64 = 0,
    tiles: std.ArrayList(Handle) = .empty,
    shelf: std.ArrayList(Handle) = .empty,
    focused: ?Handle = null,
    /// Maximized mode: this window fills the work area; the others wait in
    /// the panel.
    maximized: ?Handle = null,
    /// The tiles as they were before maximize; restore brings them back.
    pre_max: std.ArrayList(Handle) = .empty,
    /// Full-screen spaces, each holding one window. Space 0 is the desktop;
    /// space i > 0 is `spaces[i - 1]`.
    spaces: std.ArrayList(Handle) = .empty,
    space: usize = 0,
    space_from: usize = 0,
    /// Start of the slide between spaces; -1 when not sliding.
    space_start: i64 = -1,
    /// The title bar of a full-screen window, revealed at the top edge.
    fs_bar: Tween = Tween.init(0),
    slots: [tiling.max_windows]tiling.Slot = undefined,
    slot_count: usize = 0,
    overrides: tiling.Overrides = .{},

    px: f32 = -1,
    py: f32 = -1,
    mods: core.input.Mods = .{},
    content_hover: ?Handle = null,
    drag: Drag = .none,
    /// The tiles when a reorder began: the pointer is tested against them,
    /// not the previewed layout, so a swap that moves the borders cannot
    /// flip the target back and forth.
    reorder_slots: [tiling.max_windows]tiling.Slot = undefined,
    reorder_tiles: [tiling.max_windows]Handle = undefined,
    reorder_n: usize = 0,
    tracker: core.wheel.Tracker = .{},
    cursor: core.input.Cursor = .arrow,

    launcher: shell.Launcher = .{},
    /// The menu a top-bar icon opens (settings, sound, connectivity,
    /// language).
    top_menu: menus.TopMenu = .{},
    /// What the system reports for the menus: connections, sound,
    /// devices, keyboard layouts.
    system: menus.System = .{},
    /// Floating dialogs (Top-Level Design, "Dialogs"); within each layer,
    /// later ones are on top.
    dialogs: std.ArrayList(dlg.Dialog) = .empty,
    dialog_seq: u32 = 0,
    /// The dialog with the keyboard, when one has it.
    dialog_focus: ?u32 = null,
    /// The dialog under the pointer.
    dialog_hover: ?u32 = null,
    desktop_dialogs: ?DesktopDialogs = null,
    /// Dialogs asked for during a frame, opened at its end.
    pending_dialogs: [4]struct { surface: Surface, opts: dlg.Options } = undefined,
    pending_dialogs_len: usize = 0,
    chooser: ?Chooser = null,
    /// The panel window under the pointer, shown enlarged over the panel
    /// with buttons.
    preview: ?Preview = null,
    /// Right-click menu on a panel group.
    panel_menu: ?PanelMenu = null,
    preview_t: Tween = Tween.init(0),
    cue: ?Cue = null,
    ghosts: std.ArrayList(Ghost) = .empty,
    /// The last click on a title bar, to see a double click.
    last_title: ?struct { h: Handle, t: i64, x: f32, y: f32 } = null,
    /// Frame timing, to tell a slow frame (stall) from the usual pace.
    pace: FramePace = .{},
    launch_seq: u64 = 0,
    /// "Close all" asks for a second click; the time of the first.
    close_all_armed: ?i64 = null,
    super_down: bool = false,
    super_other: bool = false,
    learning: bool = true,
    /// The date and time the top bar shows ("Fri Oct 30  13:35").
    clock: [32]u8 = undefined,
    clock_len: usize = 0,

    publisher: Publisher,
    scratch: std.ArrayList(u8) = .empty,
    full_redraw: bool = true,
    /// The user's trust marks, from krkdesk (DeskTrust), plus marks set here
    /// that krkdesk has not confirmed yet.
    marks: core.trust.Marks,

    /// The launcher's Focus and Recent, from krkdesk's influence file. Read
    /// when the launcher opens after krkdesk said it changed. Without it,
    /// Focus is empty and Recent is this session's launches (`recent`).
    state_reader: ?StateReader = null,
    influence_bytes: []u8 = &.{},
    influence: core.influence.Decoded = .{},
    influence_ok: bool = false,
    influence_stale: bool = true,
    /// Wall clock (Unix seconds), from the backend; 0 when unknown.
    wall_s: i64 = 0,
    /// App icons as pixels (krkdesk's icons.krkde); read again when krkdesk
    /// says they changed. `icon_ids` are the GPU picture ids, one per icon.
    icons: core.icons.Set,
    icon_ids: std.ArrayList(u64) = .empty,
    icons_stale: bool = true,

    pub fn init(gpa: std.mem.Allocator, apps: []const AppEntry, screen: Size, scale: i32, params: Params) !*Compositor {
        const c = try gpa.create(Compositor);
        errdefer gpa.destroy(c);
        var infos: std.ArrayList(shell.AppInfo) = .empty;
        errdefer infos.deinit(gpa);
        for (apps) |a| try infos.append(gpa, .{ .name = a.name });
        const stats = try gpa.alloc(LaunchStats, apps.len);
        @memset(stats, .{});
        c.* = .{
            .gpa = gpa,
            .params = params,
            .theme = if (params.dark) Theme.darkTheme() else Theme.light(),
            .screen = screen,
            .scale = scale,
            .apps = apps,
            .app_infos = infos,
            .installed = .init(gpa),
            .stats = stats,
            .windows = core.Registry(Window).init(gpa),
            .publisher = Publisher.init(gpa),
            .marks = .init(gpa),
            .icons = .init(gpa),
        };
        return c;
    }

    pub fn deinit(self: *Compositor) void {
        const gpa = self.gpa;
        {
            var hs: std.ArrayList(Handle) = .empty;
            defer hs.deinit(gpa);
            self.windows.handles(&hs, gpa) catch {};
            for (hs.items) |h| self.destroyWindow(h);
        }
        while (self.dialogs.items.len > 0) self.destroyDialog(self.dialogs.items.len - 1);
        for (self.pending_dialogs[0..self.pending_dialogs_len]) |p| p.surface.destroy();
        self.dialogs.deinit(gpa);
        self.windows.collect(null);
        self.windows.deinit(null);
        self.tiles.deinit(self.gpa);
        self.shelf.deinit(self.gpa);
        self.pre_max.deinit(self.gpa);
        for (self.ghosts.items) |gh| self.gpa.free(gh.pixels);
        self.ghosts.deinit(self.gpa);
        self.spaces.deinit(self.gpa);
        self.recent.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.marks.deinit();
        self.influence.deinit(self.gpa);
        self.icons.deinit();
        self.icon_ids.deinit(self.gpa);
        self.gpa.free(self.influence_bytes);
        self.publisher.deinit();
        self.app_infos.deinit(self.gpa);
        self.installed.deinit();
        self.gpa.free(self.stats);
        self.gpa.destroy(self);
    }

    pub fn setClock(self: *Compositor, text: []const u8) void {
        const n = @min(text.len, self.clock.len);
        if (n == self.clock_len and std.mem.eql(u8, self.clock[0..n], text[0..n])) return;
        @memcpy(self.clock[0..n], text[0..n]);
        self.clock_len = n;
        self.full_redraw = true;
    }

    /// "Pause learning" (top bar, settings): the recorder stops while
    /// learning is off.
    pub fn setLearning(self: *Compositor, on: bool) void {
        if (self.learning == on) return;
        self.learning = on;
        self.full_redraw = true;
        if (self.publisher.subscriberCount() == 0) return;
        self.scratch.clearRetainingCapacity();
        self.sessionRecord(&self.scratch);
        self.publisher.broadcast(self.scratch.items);
    }

    fn sessionRecord(self: *Compositor, out: *std.ArrayList(u8)) void {
        core.format.appendStruct(self.gpa, out, core.types.scene_session, 1, core.types.SceneSession{ .learning = @intFromBool(self.learning) }, "") catch {};
    }

    /// The wall clock, Unix seconds (the launcher's "5 min ago").
    pub fn setWallTime(self: *Compositor, unix_s: i64) void {
        self.wall_s = unix_s;
    }

    pub fn setScreen(self: *Compositor, size: Size, scale: i32, now: i64) void {
        if (size.w == self.screen.w and size.h == self.screen.h and scale == self.scale) return;
        self.screen = size;
        self.scale = scale;
        self.relayout(now, false);
        self.full_redraw = true;
    }

    /// The panel is always there: wide while it holds windows, a narrow
    /// rail with the apps button when empty.
    fn panelW(self: *const Compositor) i32 {
        _ = self;
        return shell.panel_w;
    }

    /// The apps button at the bottom of the panel.
    fn appsButtonRect(self: *const Compositor) Rect {
        const b = shell.apps_button;
        return .{ .x = @divTrunc(self.panelW() - b, 2), .y = self.screen.h - shell.panel_pad - b, .w = b, .h = b };
    }

    /// The screen below the top bar, right of the panel.
    fn workArea(self: *const Compositor) Rect {
        const left: i32 = self.panelW();
        return .{ .x = left, .y = shell.top_bar_h, .w = self.screen.w - left, .h = self.screen.h - shell.top_bar_h };
    }

    // ------------------------------------------------------- window life

    pub fn launch(self: *Compositor, app: usize, now: i64) !Handle {
        const entry = self.apps[app];
        const expected = self.stats[app].expected() orelse @as(i64, @max(entry.start_ms, 400)) * ms;
        self.launch_seq += 1;
        const h = try self.windows.create(.{
            .app = app,
            .seq = self.launch_seq,
            .launch_start = now,
            .ready_at = now + @as(i64, entry.start_ms) * ms,
            .expected_ns = expected,
        });
        try self.tiles.append(self.gpa, h);
        // Remember launches for the launcher's simple prediction (recency).
        for (self.recent.items, 0..) |a, i| {
            if (a == app) {
                _ = self.recent.orderedRemove(i);
                break;
            }
        }
        try self.recent.insert(self.gpa, 0, app);
        // A new window ends maximized mode: it is tiled with the maximized
        // window; the others stay in the panel. It opens on the desktop.
        self.maximized = null;
        self.pre_max.clearRetainingCapacity();
        if (self.space != 0) self.switchSpace(0, now);
        self.focus(h, now);
        // The placeholder appears at once, at its final place.
        self.enforceLimit(now);
        self.relayout(now, true);
        self.publishWindow(h, .opened);
        return h;
    }

    /// Launches an app straight into the panel, as at login: the app
    /// starts and its window waits minimized, so the desktop stays clean.
    /// Nothing animates and focus does not change.
    pub fn launchMinimized(self: *Compositor, app: usize, now: i64) !Handle {
        const entry = self.apps[app];
        const expected = self.stats[app].expected() orelse @as(i64, @max(entry.start_ms, 400)) * ms;
        self.launch_seq += 1;
        const h = try self.windows.create(.{
            .app = app,
            .seq = self.launch_seq,
            .launch_start = now,
            .ready_at = now + @as(i64, entry.start_ms) * ms,
            .expected_ns = expected,
            .shelved = true,
        });
        try self.shelf.append(self.gpa, h);
        self.relayout(now, false);
        self.publishWindow(h, .opened);
        return h;
    }

    /// Windows on screen and in the panel (for tests and scripts).
    pub fn counts(self: *const Compositor) struct { tiled: usize, shelved: usize } {
        return .{ .tiled = self.tiles.items.len, .shelved = self.shelf.items.len };
    }

    fn attachSurface(self: *Compositor, h: Handle, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        const s = self.apps[w.app].create(self.gpa) catch |err| {
            std.log.err("launch of {s} failed: {s}", .{ self.apps[w.app].name, @errorName(err) });
            w.status = .{ .kind = .failed };
            w.ready_at = std.math.maxInt(i64);
            return;
        };
        w.surface = s;
        s.setDark(self.theme.dark);
        self.stats[w.app].add(now - w.launch_start);
        s.configure(w.content, self.scale);
        w.dirty = true;
    }

    /// The user closes a window. An app that closes in its own time (a
    /// Wayland app may ask to save first) is asked, and the window goes
    /// when the app is done; anything else closes now.
    pub fn requestClose(self: *Compositor, h: Handle, now: i64) void {
        {
            const g = self.windows.acquire(h) orelse return;
            defer g.release();
            if (g.ptr.surface) |s| {
                if (s.requestClose()) {
                    g.ptr.closing = true;
                    return;
                }
            }
        }
        self.close(h, now);
    }

    pub fn close(self: *Compositor, h: Handle, now: i64) void {
        self.closeDialogsOf(h);
        self.publishWindow(h, .closed);
        self.keepGhost(h, now);
        removeHandle(&self.tiles, h);
        removeHandle(&self.shelf, h);
        const was_max = if (self.maximized) |m| m.eql(h) else false;
        removeHandle(&self.pre_max, h);
        self.removeSpace(h);
        if (self.content_hover) |c| {
            if (c.eql(h)) self.content_hover = null;
        }
        if (self.focused) |f| {
            if (f.eql(h)) {
                self.focused = null;
                // Focus the most recently used remaining window.
                var best: ?Handle = null;
                var best_t: i64 = std.math.minInt(i64);
                for (self.tiles.items) |t| {
                    const g = self.windows.acquire(t) orelse continue;
                    defer g.release();
                    if (g.ptr.last_focus > best_t) {
                        best_t = g.ptr.last_focus;
                        best = t;
                    }
                }
                if (best) |b| self.focus(b, now);
            }
        }
        self.destroyWindow(h);
        // Closing the maximized window brings the others back.
        if (was_max) self.exitMaximized(true, now);
        self.relayout(now, true);
    }

    /// Takes the closing window's picture so it can shrink to nothing at
    /// its center after the window itself is gone.
    fn keepGhost(self: *Compositor, h: Handle, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        var frame: Rect = undefined;
        var content: Rect = undefined;
        var bar = true;
        if (w.fullscreen) {
            if (self.activeFs() == null or !self.activeFs().?.eql(h)) return;
            frame = self.screenRect();
            content = frame;
            bar = false;
        } else if (w.shelved) {
            frame = self.panelRectOf(h) orelse return;
            content = frame;
            bar = false;
        } else {
            frame = currentFrame(w, now);
            content = contentRect(frame);
        }
        self.ghosts.append(self.gpa, .{
            .pixels = w.pixels,
            .buf_w = w.buf_w,
            .buf_h = w.buf_h,
            .image_id = w.image_id,
            .version = w.version,
            .frame = frame,
            .content = content,
            .chrome_bar = bar,
            .start = now,
        }) catch return;
        // The ghost owns the pixels now.
        w.pixels = &.{};
    }

    fn drawGhosts(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        var i: usize = 0;
        while (i < self.ghosts.items.len) {
            const gh = self.ghosts.items[i];
            const el = now - gh.start;
            if (el >= fly_ms * ms) {
                self.gpa.free(gh.pixels);
                _ = self.ghosts.swapRemove(i);
                continue;
            }
            i += 1;
            // Shrinks toward its center, fading as it goes.
            const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(el)) / @as(f32, @floatFromInt(fly_ms * ms)));
            const k = 1 - t;
            const cx: f32 = @as(f32, @floatFromInt(gh.frame.x)) + @as(f32, @floatFromInt(gh.frame.w)) / 2;
            const cy: f32 = @as(f32, @floatFromInt(gh.frame.y)) + @as(f32, @floatFromInt(gh.frame.h)) / 2;
            const sx = struct {
                fn map(c: f32, v: i32, kk: f32) i32 {
                    return @intFromFloat(@round(c + (@as(f32, @floatFromInt(v)) - c) * kk));
                }
            }.map;
            const fr = Rect{ .x = sx(cx, gh.frame.x, k), .y = sx(cy, gh.frame.y, k), .w = @max(1, sx(cx, gh.frame.right(), k) - sx(cx, gh.frame.x, k)), .h = @max(1, sx(cy, gh.frame.bottom(), k) - sx(cy, gh.frame.y, k)) };
            const cr = Rect{ .x = sx(cx, gh.content.x, k), .y = sx(cy, gh.content.y, k), .w = @max(1, sx(cx, gh.content.right(), k) - sx(cx, gh.content.x, k)), .h = @max(1, sx(cy, gh.content.bottom(), k) - sx(cy, gh.content.y, k)) };
            const alpha: u8 = @intFromFloat(255 * (1 - t * t));
            if (gh.chrome_bar) cv.fillRect(fr, th.get(.chrome).fade(1 - t * t));
            if (gh.pixels.len > 0) cv.blitScaled(.{ .pixels = gh.pixels, .w = gh.buf_w, .h = gh.buf_h, .id = gh.image_id, .version = gh.version }, cr, alpha);
            cv.hairlineRect(fr, th.get(.border).fade(1 - t));
        }
    }

    fn destroyWindow(self: *Compositor, h: Handle) void {
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            if (g.ptr.surface) |s| s.destroy();
            g.ptr.surface = null;
            self.gpa.free(g.ptr.pixels);
            g.ptr.pixels = &.{};
            self.gpa.free(g.ptr.exe);
            g.ptr.exe = &.{};
            self.gpa.free(g.ptr.object);
            g.ptr.object = &.{};
        }
        self.windows.destroy(h);
    }

    fn removeHandle(list: *std.ArrayList(Handle), h: Handle) void {
        for (list.items, 0..) |x, i| {
            if (x.eql(h)) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    pub fn focus(self: *Compositor, h: Handle, now: i64) void {
        const old = self.focused;
        if (old) |o| {
            if (o.eql(h)) return;
        }
        self.focused = h;
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            g.ptr.last_focus = now;
        }
        if (old) |o| self.publishWindow(o, .changed);
        self.publishWindow(h, .changed);
        self.full_redraw = true;
    }

    /// Up to 4 windows per screen; beyond that the least recently used
    /// one goes to the shelf.
    fn enforceLimit(self: *Compositor, now: i64) void {
        while (self.tiles.items.len > tiling.max_windows) {
            var lru: usize = 0;
            var lru_t: i64 = std.math.maxInt(i64);
            for (self.tiles.items, 0..) |t, i| {
                if (self.focused != null and self.focused.?.eql(t)) continue;
                const g = self.windows.acquire(t) orelse continue;
                defer g.release();
                if (g.ptr.last_focus < lru_t) {
                    lru_t = g.ptr.last_focus;
                    lru = i;
                }
            }
            const h = self.tiles.orderedRemove(lru);
            self.shelveHandle(h, now);
        }
    }

    fn shelveHandle(self: *Compositor, h: Handle, now: i64) void {
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            g.ptr.shelved = true;
            // Animate from where it is now into its place in the panel.
            g.ptr.fly_from = RectF.from(currentFrame(g.ptr, now));
            g.ptr.fly_start = now;
            // Its thumbnail flashes once when it lands.
            g.ptr.flash_start = now + (fly_ms - 40) * ms;
        }
        self.shelf.append(self.gpa, h) catch {};
        self.publishWindow(h, .changed);
    }

    /// Minimize: the window flies to the panel; the others take the room.
    pub fn shelve(self: *Compositor, h: Handle, now: i64) void {
        if (self.isFullscreen(h)) self.exitFullscreen(h, now);
        const was_max = if (self.maximized) |m| m.eql(h) else false;
        removeHandle(&self.tiles, h);
        self.shelveHandle(h, now);
        // Show the way to the panel: the outline travels from the window
        // to its thumbnail, as when a window comes out of it.
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            self.cue = .{ .h = h, .from = g.ptr.fly_from, .start = now };
        }
        // Minimizing the maximized window brings the others back.
        if (was_max) self.exitMaximized(true, now);
        if (self.focused) |f| {
            if (f.eql(h)) {
                self.focused = null;
                if (self.tiles.items.len > 0) self.focus(self.tiles.items[self.tiles.items.len - 1], now);
            }
        }
        self.relayout(now, true);
    }

    /// Takes a window out of the panel; it flies out of its thumbnail.
    /// The caller puts it into the tiles.
    fn unshelve(self: *Compositor, h: Handle) void {
        const from = self.panelRectOf(h);
        removeHandle(&self.shelf, h);
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            g.ptr.shelved = false;
            g.ptr.fly_start = -1;
            if (from) |r| {
                g.ptr.from = RectF.from(r);
                g.ptr.target = r;
                g.ptr.anim_start = 0;
                g.ptr.placed = true;
            }
        }
    }

    /// Restore from the panel into the tiles, at the end.
    pub fn restore(self: *Compositor, h: Handle, now: i64) void {
        self.restoreAt(h, null, now);
    }

    fn restoreAt(self: *Compositor, h: Handle, index: ?usize, now: i64) void {
        self.unshelve(h);
        const i = @min(index orelse self.tiles.items.len, self.tiles.items.len);
        self.tiles.insert(self.gpa, i, h) catch return;
        self.focus(h, now);
        self.enforceLimit(now);
        self.relayout(now, true);
    }

    /// A click on a panel thumbnail. In maximized mode the clicked window
    /// becomes the maximized one and the current one goes to the panel;
    /// otherwise the window is tiled again.
    pub fn panelClick(self: *Compositor, h: Handle, now: i64) void {
        const m = self.maximized orelse return self.restore(h, now);
        self.unshelve(h);
        removeHandle(&self.tiles, m);
        self.shelveHandle(m, now);
        self.tiles.insert(self.gpa, 0, h) catch {};
        self.maximized = h;
        self.focus(h, now);
        self.relayout(now, true);
    }

    /// A panel window dragged into the window area is tiled at `index`.
    /// In maximized mode this ends the mode: the maximized window and the
    /// dragged one share the screen; the others stay in the panel.
    pub fn panelDrop(self: *Compositor, h: Handle, index: usize, now: i64) void {
        if (self.maximized != null) {
            self.maximized = null;
            self.pre_max.clearRetainingCapacity();
        }
        self.restoreAt(h, index, now);
    }

    pub fn isMaximized(self: *const Compositor, h: Handle) bool {
        return if (self.maximized) |m| m.eql(h) else false;
    }

    /// Maximize = minimize every other window: they fly to the panel and
    /// this one fills the work area. On the maximized window it restores:
    /// the windows that were tiled before come back.
    pub fn toggleMaximize(self: *Compositor, h: Handle, now: i64) void {
        if (self.isFullscreen(h)) self.exitFullscreen(h, now);
        if (self.isMaximized(h)) {
            self.exitMaximized(true, now);
            self.focus(h, now);
            self.relayout(now, true);
            return;
        }
        if (self.maximized != null) self.exitMaximized(false, now);
        self.pre_max.clearRetainingCapacity();
        self.pre_max.appendSlice(self.gpa, self.tiles.items) catch {};
        var i: usize = 0;
        while (i < self.tiles.items.len) {
            const t = self.tiles.items[i];
            if (t.eql(h)) {
                i += 1;
                continue;
            }
            _ = self.tiles.orderedRemove(i);
            self.shelveHandle(t, now);
        }
        self.maximized = h;
        self.focus(h, now);
        self.relayout(now, true);
    }

    /// Ends maximized mode. With `bring_back`, the windows tiled before
    /// maximize return from the panel in their old order; the window that
    /// is maximized now keeps or takes a place among them.
    fn exitMaximized(self: *Compositor, bring_back: bool, now: i64) void {
        const m = self.maximized orelse return;
        self.maximized = null;
        defer self.pre_max.clearRetainingCapacity();
        if (!bring_back) return;
        var order: std.ArrayList(Handle) = .empty;
        defer order.deinit(self.gpa);
        var has_m = false;
        for (self.pre_max.items) |p| {
            if (p.eql(m)) has_m = true;
            if (p.eql(m) or contains(self.tiles.items, p) or contains(self.shelf.items, p))
                order.append(self.gpa, p) catch {};
        }
        if (!has_m and contains(self.tiles.items, m)) order.append(self.gpa, m) catch {};
        for (order.items) |p| {
            if (contains(self.shelf.items, p)) self.unshelve(p);
        }
        self.tiles.clearRetainingCapacity();
        self.tiles.appendSlice(self.gpa, order.items) catch {};
        self.enforceLimit(now);
        self.relayout(now, true);
    }

    fn contains(list: []const Handle, h: Handle) bool {
        for (list) |x| {
            if (x.eql(h)) return true;
        }
        return false;
    }

    // --------------------------------------------------------- full screen

    pub fn isFullscreen(self: *const Compositor, h: Handle) bool {
        return contains(self.spaces.items, h);
    }

    /// The full-screen window shown now, if the current space is one.
    fn activeFs(self: *const Compositor) ?Handle {
        if (self.space == 0 or self.space > self.spaces.items.len) return null;
        return self.spaces.items[self.space - 1];
    }

    fn screenRect(self: *const Compositor) Rect {
        return .{ .x = 0, .y = 0, .w = self.screen.w, .h = self.screen.h };
    }

    pub fn toggleFullscreen(self: *Compositor, h: Handle, now: i64) void {
        if (self.isFullscreen(h)) self.exitFullscreen(h, now) else self.enterFullscreen(h, now);
    }

    /// Full screen: the window gets a space of its own, like a new
    /// workspace, and covers the whole screen with no top bar or panel.
    /// The desktop keeps the other windows tiled.
    pub fn enterFullscreen(self: *Compositor, h: Handle, now: i64) void {
        if (self.isFullscreen(h)) return;
        if (contains(self.shelf.items, h)) self.unshelve(h);
        if (self.isMaximized(h)) self.exitMaximized(true, now);
        var home: usize = self.tiles.items.len;
        for (self.tiles.items, 0..) |t, i| {
            if (t.eql(h)) home = i;
        }
        removeHandle(&self.tiles, h);
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            const w = g.ptr;
            w.fullscreen = true;
            w.fs_home = home;
            w.fs_from = RectF.from(currentFrame(w, now));
            w.fs_start = now;
            w.target = self.screenRect();
            self.sizeContent(w, self.screen);
        }
        self.spaces.append(self.gpa, h) catch return;
        self.space_from = self.space;
        self.space = self.spaces.items.len;
        // The zoom is the animation; no slide.
        self.space_start = -1;
        self.fs_bar.snap(0);
        self.focus(h, now);
        self.relayout(now, false);
        self.publishWindow(h, .changed);
    }

    /// Back from full screen: the window returns to its tile on the
    /// desktop, shrinking from the full screen into it.
    pub fn exitFullscreen(self: *Compositor, h: Handle, now: i64) void {
        if (!self.isFullscreen(h)) return;
        self.removeSpace(h);
        self.space = 0;
        self.space_start = -1;
        if (self.maximized != null) self.exitMaximized(true, now);
        var home: usize = 0;
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            const w = g.ptr;
            w.fullscreen = false;
            w.fs_start = -1;
            home = w.fs_home;
            w.from = RectF.from(self.screenRect());
            w.target = self.screenRect();
            w.anim_start = 0;
            w.placed = true;
        }
        self.tiles.insert(self.gpa, @min(home, self.tiles.items.len), h) catch return;
        self.focus(h, now);
        self.enforceLimit(now);
        self.relayout(now, true);
    }

    fn removeSpace(self: *Compositor, h: Handle) void {
        for (self.spaces.items, 0..) |x, i| {
            if (!x.eql(h)) continue;
            _ = self.spaces.orderedRemove(i);
            const idx = i + 1;
            if (self.space == idx) self.space = 0 else if (self.space > idx) self.space -= 1;
            self.space_from = 0;
            self.space_start = -1;
            return;
        }
    }

    /// Switch to another space with a slide (Super+Left / Super+Right, or
    /// the space dots).
    pub fn switchSpace(self: *Compositor, to: usize, now: i64) void {
        const target = @min(to, self.spaces.items.len);
        if (target == self.space) return;
        self.space_from = self.space;
        self.space = target;
        self.space_start = now;
        self.fs_bar.snap(0);
        self.setContentHover(null, now);
        if (self.activeFs()) |h| {
            self.focus(h, now);
        } else {
            // Back on the desktop: the most recently used tile.
            var best: ?Handle = null;
            var best_t: i64 = std.math.minInt(i64);
            for (self.tiles.items) |t| {
                const g = self.windows.acquire(t) orelse continue;
                defer g.release();
                if (g.ptr.last_focus > best_t) {
                    best_t = g.ptr.last_focus;
                    best = t;
                }
            }
            if (best) |b| self.focus(b, now);
        }
        self.full_redraw = true;
    }

    // ------------------------------------------------------------ layout

    fn chromeSize(content: Size) Size {
        return .{ .w = content.w + 2, .h = content.h + chrome.title_h + 1 };
    }

    fn contentRect(frame: Rect) Rect {
        return .{ .x = frame.x + 1, .y = frame.y + chrome.title_h, .w = @max(1, frame.w - 2), .h = @max(1, frame.h - chrome.title_h - 1) };
    }

    fn currentFrame(w: *const Window, now: i64) Rect {
        if (!w.placed) return w.target;
        const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(now - w.anim_start)) / @as(f32, @floatFromInt(anim_ms * ms)));
        return RectF.lerp(w.from, RectF.from(w.target), t).round();
    }

    fn relayout(self: *Compositor, now: i64, animate: bool) void {
        const area = self.workArea();
        var items: [tiling.max_windows]tiling.Item = undefined;
        var handles: [tiling.max_windows]Handle = undefined;
        var n: usize = 0;
        {
            for (self.tiles.items) |h| {
                if (n == tiling.max_windows) break;
                const g = self.windows.acquire(h) orelse continue;
                defer g.release();
                const opt = if (g.ptr.surface) |s| s.optimalSize() else Size{ .w = 640, .h = 720 };
                items[n] = .{
                    .optimal = chromeSize(opt),
                    .focused = self.focused != null and self.focused.?.eql(h),
                    // A launch placeholder may grow; the app decides once it runs.
                    .growable = if (g.ptr.surface) |s| s.growable() else true,
                };
                handles[n] = h;
                n += 1;
            }
        }
        tiling.layout(area, items[0..n], self.overrides, .{}, &self.slots);
        self.slot_count = n;
        for (handles[0..n], 0..) |h, i| self.place(h, self.slots[i].frame, self.slots[i].row, now, animate);
        self.full_redraw = true;
    }

    fn place(self: *Compositor, h: Handle, frame: Rect, row: u8, now: i64, animate: bool) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        const cur = currentFrame(w, now);
        w.from = RectF.from(if (w.placed and animate) cur else frame);
        w.anim_start = now;
        w.target = frame;
        w.row = row;
        w.placed = true;
        const content = contentRect(frame);
        self.sizeContent(w, .{ .w = content.w, .h = content.h });
        self.publishWindowLocked(h, w, .changed);
    }

    /// The compositor decides the content size (Wayland `configure`).
    fn sizeContent(self: *Compositor, w: *Window, size: Size) void {
        if (size.w == w.content.w and size.h == w.content.h and w.buf_w == size.w * self.scale) return;
        w.content = size;
        const bw = size.w * self.scale;
        const bh = size.h * self.scale;
        const px = self.gpa.realloc(w.pixels, @intCast(bw * bh)) catch return;
        w.pixels = px;
        w.buf_w = bw;
        w.buf_h = bh;
        self.image_seq += 1;
        w.image_id = self.image_seq;
        w.version = 0;
        if (w.surface) |s| s.configure(size, self.scale);
        w.dirty = true;
    }

    /// A window that went to the panel before it was ever placed gets a
    /// buffer at its optimal size, so its thumbnail shows its content.
    fn ensureDrawn(self: *Compositor, w: *Window) void {
        const s = w.surface orelse return;
        if (w.pixels.len == 0) {
            const opt = s.optimalSize();
            self.sizeContent(w, .{ .w = @max(opt.w, 320), .h = @max(@min(opt.h, 800), 120) });
        }
        w.paint(self.scale);
    }

    /// Fills `r` with the window's picture, scaled to cover it: the whole
    /// height, or the whole width for a tall window, anchored at the
    /// top-left, where titles and headings are. Nothing is stretched.
    fn blitCover(cv: *Canvas, w: *const Window, r: Rect) void {
        if (w.pixels.len == 0 or w.buf_w <= 0 or w.buf_h <= 0 or r.w <= 0 or r.h <= 0) return;
        const sw: f32 = @floatFromInt(w.buf_w);
        const sh: f32 = @floatFromInt(w.buf_h);
        const k = @max(@as(f32, @floatFromInt(r.w)) / sw, @as(f32, @floatFromInt(r.h)) / sh);
        const full = Rect{ .x = r.x, .y = r.y, .w = @intFromFloat(@ceil(sw * k)), .h = @intFromFloat(@ceil(sh * k)) };
        const old = cv.pushClip(r);
        defer cv.popClip(old);
        cv.blitScaled(w.image(), full, 255);
    }

    /// Where a window's content is on screen.
    fn contentOf(self: *const Compositor, w: *const Window) Rect {
        return if (w.fullscreen) self.screenRect() else contentRect(w.target);
    }

    // ------------------------------------------------------------- input

    fn windowAt(self: *Compositor, x: f32, y: f32, now: i64) ?Handle {
        for (self.visibleTiles()) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            if (currentFrame(g.ptr, now).contains(x, y)) return h;
        }
        return null;
    }

    fn visibleTiles(self: *Compositor) []const Handle {
        return self.tiles.items[0..@min(self.tiles.items.len, tiling.max_windows)];
    }

    /// A shared border between two slots of a row, or between the rows.
    /// The whole gap between the two windows is the grab area, plus a few
    /// pixels into each window's edge (Look and Controls, Borders).
    const Divider = struct {
        vertical: bool,
        row: u8,
        /// Where the pointer can grab it.
        zone: Rect,
        /// The slot boundary (x for vertical, y for horizontal).
        boundary: i32,
        /// The span the divider line covers (y range or x range).
        from: i32,
        to: i32,
    };

    const grab_px = 5;

    fn dividers(self: *const Compositor, out: *[3]Divider) usize {
        if (self.slot_count < 2) return 0;
        var n: usize = 0;
        var i: usize = 0;
        while (i + 1 < self.slot_count) : (i += 1) {
            const a = self.slots[i];
            const b = self.slots[i + 1];
            if (a.row != b.row) continue;
            const left = @min(a.frame.right(), a.slot.right());
            const right = @max(b.frame.x, b.slot.x);
            out[n] = .{
                .vertical = true,
                .row = a.row,
                .zone = .{ .x = left - grab_px, .y = a.slot.y, .w = right - left + 2 * grab_px, .h = a.slot.h },
                .boundary = a.slot.right(),
                .from = a.slot.y,
                .to = a.slot.bottom(),
            };
            n += 1;
        }
        if (self.slot_count > 2) {
            var top_bottom: i32 = self.slots[0].frame.bottom();
            if (self.slot_count > 1 and self.slots[1].row == 0) top_bottom = @max(top_bottom, self.slots[1].frame.bottom());
            var bottom_top: i32 = self.slots[2].frame.y;
            if (self.slot_count > 3) bottom_top = @min(bottom_top, self.slots[3].frame.y);
            const area = self.workArea();
            const y0 = @min(top_bottom, self.slots[2].slot.y);
            const y1 = @max(bottom_top, self.slots[2].slot.y);
            out[n] = .{
                .vertical = false,
                .row = 0,
                .zone = .{ .x = area.x, .y = y0 - grab_px, .w = area.w, .h = y1 - y0 + 2 * grab_px },
                .boundary = self.slots[2].slot.y,
                .from = area.x,
                .to = area.right(),
            };
            n += 1;
        }
        return n;
    }

    fn dividerAt(self: *const Compositor, x: f32, y: f32) ?Divider {
        var buf: [3]Divider = undefined;
        const n = self.dividers(&buf);
        // The row divider is checked last, so a column divider wins where
        // they cross.
        for (buf[0..n]) |d| {
            if (d.zone.contains(x, y)) return d;
        }
        return null;
    }

    fn borderAt(self: *const Compositor, x: f32, y: f32) Drag {
        const d = self.dividerAt(x, y) orelse return .none;
        const b: f32 = @floatFromInt(d.boundary);
        if (d.vertical) return .{ .col_border = .{ .row = d.row, .start = x, .boundary = b } };
        return .{ .row_border = .{ .start = y, .boundary = b } };
    }

    fn sendToContent(self: *Compositor, h: Handle, ev: Event, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const s = g.ptr.surface orelse return;
        const c = self.contentOf(g.ptr);
        const ox: f32 = @floatFromInt(c.x);
        const oy: f32 = @floatFromInt(c.y);
        var local = ev;
        switch (local) {
            .pointer_motion => |*m| {
                m.x -= ox;
                m.y -= oy;
            },
            .pointer_button => |*b| {
                b.x -= ox;
                b.y -= oy;
            },
            else => {},
        }
        s.input(local, now);
        g.ptr.dirty = true;
    }

    fn setContentHover(self: *Compositor, h: ?Handle, now: i64) void {
        if (self.content_hover) |old| {
            if (h == null or !old.eql(h.?)) self.sendToContent(old, .pointer_leave, now);
        }
        self.content_hover = h;
    }

    pub fn handleInput(self: *Compositor, ev: Event, now: i64) void {
        defer self.windows.endEvent();
        switch (ev) {
            .key => |k| {
                self.mods = k.mods;
                if (k.key == .super) {
                    if (k.pressed and !k.repeat) {
                        self.super_down = true;
                        self.super_other = false;
                    } else if (!k.pressed) {
                        // The launcher opens on release of Super alone.
                        if (self.super_down and !self.super_other) self.toggleLauncher(now);
                        self.super_down = false;
                    }
                    return;
                }
                if (k.pressed and self.super_down) {
                    self.super_other = true;
                    self.shortcut(k.key, now);
                    return;
                }
                if (self.launcher.open) {
                    if (k.pressed) self.launcherAction(self.launcher.key(self.app_infos.items, k.key, k.mods.shift), now);
                    return;
                }
                // A dialog with the keyboard gets it; Esc asks it to close.
                if (self.focusedDialog()) |i| {
                    const d = &self.dialogs.items[i];
                    if (k.pressed and k.key == .escape) {
                        if (!d.surface.requestClose()) self.beginCloseDialog(i, now);
                    } else self.sendToDialog(i, ev, now);
                    return;
                }
                if ((self.preview != null or self.panel_menu != null) and k.pressed and k.key == .escape) {
                    self.preview = null;
                    self.panel_menu = null;
                    self.full_redraw = true;
                    return;
                }
                if (self.drag == .title and k.pressed and k.key == .escape) {
                    self.cancelReorder(now);
                    return;
                }
                if (self.chooser != null and k.pressed and k.key == .escape) {
                    self.chooser = null;
                    self.full_redraw = true;
                    return;
                }
                if (self.top_menu.isOpen() and k.pressed and k.key == .escape) {
                    // From a detail view, back to the menu; else close it.
                    if (self.top_menu.view != .main) self.top_menu.view = .main else self.top_menu = .{};
                    self.full_redraw = true;
                    return;
                }
                if (self.focused) |f| self.sendToContent(f, ev, now);
            },
            .text => |t| {
                if (self.super_down) return;
                if (self.launcher.open) {
                    self.launcher.text(t.slice());
                    return;
                }
                if (self.focusedDialog()) |i| {
                    self.sendToDialog(i, ev, now);
                    return;
                }
                if (self.focused) |f| self.sendToContent(f, ev, now);
            },
            .pointer_motion => |m| self.pointerMotion(m.x, m.y, now),
            .pointer_leave => {
                self.setContentHover(null, now);
                self.px = -1;
            },
            .pointer_button => |b| {
                self.mods = b.mods;
                if (b.pressed) self.press(b.button, b.x, b.y, now) else self.release(b.button, b.x, b.y, now);
            },
            .wheel => |w0| {
                if (self.launcher.open) return;
                var w = w0;
                // Kuroko's own direction defaults, per device type.
                const natural = if (w.source == .touchpad) self.params.touchpad_natural else self.params.wheel_natural;
                if (natural) {
                    w.dy = -w.dy;
                    w.dx = -w.dx;
                }
                if (w.source == .wheel and w.dy != 0) {
                    const r = self.tracker.feed(now, w.dy, w.mods.shift);
                    w.band = r.band;
                    w.rate = r.rate;
                }
                if (self.dialogAt(self.px, self.py)) |i| {
                    self.sendToDialog(i, .{ .wheel = w }, now);
                    return;
                }
                if (self.modalBlocking(self.px, self.py, now) != null) return;
                const h = self.activeFs() orelse self.windowAt(self.px, self.py, now) orelse return;
                self.sendToContent(h, .{ .wheel = w }, now);
            },
        }
    }

    fn shortcut(self: *Compositor, k: core.input.Key, now: i64) void {
        switch (k) {
            .left => if (self.space > 0) self.switchSpace(self.space - 1, now),
            .right => self.switchSpace(self.space + 1, now),
            else => {},
        }
        const f = self.focused orelse return;
        switch (k) {
            .x => self.requestClose(f, now),
            .z => self.shelve(f, now), // shelve (minimize)
            .enter => self.toggleMaximize(f, now),
            .f => self.toggleFullscreen(f, now),
            else => {},
        }
    }

    fn windowAction(self: *Compositor, h: Handle, which: chrome.Button, now: i64) void {
        switch (which) {
            .close => self.requestClose(h, now),
            .shelve => self.shelve(h, now),
            .maximize => self.toggleMaximize(h, now),
            .fullscreen => self.toggleFullscreen(h, now),
        }
    }

    /// A press on a part of a top-bar menu.
    fn menuPress(self: *Compositor, hit: menus.Hit, x: f32, now: i64) void {
        const sys = &self.system;
        switch (hit) {
            .none => return,
            .setting => |row| self.flipSetting(row, now),
            .radio, .radio_switch => |r| sys.toggleRadio(r),
            .radio_more => |r| self.top_menu.view = .{ .radio = r },
            .back => self.top_menu.view = .main,
            .network => |i| sys.pickNetwork(i),
            .device => |i| self.top_menu.view = .{ .device = i },
            .pause => |i| sys.togglePause(i),
            .prop => |ref| sys.toggleProp(ref.dev, ref.i),
            .mute => |dir| sys.toggleMute(dir),
            .slider => |dir| {
                sys.setLevel(dir, self.top_menu.sliderLevel(self.screen.w, sys, dir, x));
                self.drag = .{ .menu_slider = dir };
            },
            .audio => |p| sys.pickAudio(p.dir, p.i),
            .connect => |i| sys.toggleConnect(i),
            .enable => |i| sys.toggleEnabled(i),
            .layout => |i| sys.pickLayout(i),
            .layout_edit => self.openDesktopDialog("languages", now),
        }
        self.full_redraw = true;
    }

    fn flipSetting(self: *Compositor, row: menus.Setting, now: i64) void {
        _ = now;
        switch (row) {
            .dark => self.setDark(!self.theme.dark),
            .learning => self.setLearning(!self.learning),
            .wheel_natural => self.params.wheel_natural = !self.params.wheel_natural,
            .touchpad_natural => self.params.touchpad_natural = !self.params.touchpad_natural,
        }
        self.full_redraw = true;
    }

    /// Light or dark theme for the shell and every app (Mode B: the
    /// "theme changed" message).
    pub fn setDark(self: *Compositor, dark: bool) void {
        self.theme = if (dark) Theme.darkTheme() else Theme.light();
        self.params.dark = dark;
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            if (g.ptr.surface) |sf| sf.setDark(dark);
            g.ptr.dirty = true;
        }
        for (self.dialogs.items) |*d| {
            d.surface.setDark(dark);
            d.dirty = true;
        }
        self.full_redraw = true;
    }

    fn toggleLauncher(self: *Compositor, now: i64) void {
        if (self.launcher.open) {
            self.launcher.hide(now);
        } else {
            const px = if (self.px < 0) @as(f32, @floatFromInt(self.screen.w)) / 2 else self.px;
            const py = if (self.py < 0) @as(f32, @floatFromInt(self.screen.h)) / 2 else self.py;
            var focus_list: [core.influence.max_per_list]shell.Pick = undefined;
            var recent_list: [core.influence.max_per_list]shell.Pick = undefined;
            const lists = self.launcherLists(&focus_list, &recent_list);
            self.launcher.show(.{ .x = 0, .y = 0, .w = self.screen.w, .h = self.screen.h }, px, py, self.app_infos.items, focus_list[0..lists.focus], recent_list[0..lists.recent], self.wall_s, now);
        }
        self.full_redraw = true;
    }

    pub fn launcherAction(self: *Compositor, a: shell.Launcher.Action, now: i64) void {
        switch (a) {
            .none => {},
            .close => self.launcher.hide(now),
            .launch => |l| {
                self.launcher.hide(now);
                var found: [8]Handle = undefined;
                const n = self.windowsOf(l.app, &found);
                if (l.new or n == 0) {
                    self.launchFrom(l.app, l.from, now);
                } else if (n == 1) {
                    // An app already running is brought up, not started again.
                    self.activate(found[0], l.from, now);
                } else {
                    self.openChooser(l.app, found[0..n], l.from);
                }
            },
        }
        self.full_redraw = true;
    }

    /// Every window of an app: tiled, in the panel or in full screen.
    fn windowsOf(self: *Compositor, app: usize, out: []Handle) usize {
        var n: usize = 0;
        for ([_][]const Handle{ self.tiles.items, self.spaces.items, self.shelf.items }) |list| {
            for (list) |h| {
                if (n == out.len) return n;
                const g = self.windows.acquire(h) orelse continue;
                defer g.release();
                if (g.ptr.app == app) {
                    out[n] = h;
                    n += 1;
                }
            }
        }
        return n;
    }

    fn updateRunning(self: *Compositor) void {
        var buf: [8]Handle = undefined;
        for (self.app_infos.items, 0..) |*info, i| info.running = @intCast(self.windowsOf(i, &buf));
    }

    /// A new window: it grows out of the icon into its tile.
    fn launchFrom(self: *Compositor, app: usize, from: Rect, now: i64) void {
        if (self.space != 0) self.switchSpace(0, now);
        const h = (if (app >= self.apps.len) self.launchInstalled(app, now) else self.launch(app, now)) catch return;
        self.growFrom(h, from, now);
        self.startCue(h, from, now);
    }

    /// Starts an installed app from the registry, with a launch
    /// placeholder that its first window replaces (`adoptWindow`).
    fn launchInstalled(self: *Compositor, app: usize, now: i64) !Handle {
        const e = &self.installed.entries.items[app - self.apps.len];
        if (e.status != .installed) return error.NotInstalled;
        var buf: [64][]const u8 = undefined;
        const argv = core.proc.withoutFieldCodes(e.exec, &buf);
        const pid = core.proc.spawn(self.gpa, argv, self.child_env) catch |err| {
            std.log.err("cannot start {s} ({s}): {s}", .{ e.name, if (argv.len > 0) argv[0] else "", @errorName(err) });
            return err;
        };
        std.log.info("started {s} (pid {d}): {s}", .{ e.name, pid, argv[0] });
        self.launch_seq += 1;
        const h = try self.windows.create(.{
            .app = app,
            .seq = self.launch_seq,
            .launch_start = now,
            .ready_at = std.math.maxInt(i64),
            .expected_ns = 3000 * ms,
            .waiting = true,
        });
        try self.openNew(h, app, now);
        return h;
    }

    /// A new window joins the tiles, focused, on the desktop.
    fn openNew(self: *Compositor, h: Handle, app: usize, now: i64) !void {
        try self.tiles.append(self.gpa, h);
        for (self.recent.items, 0..) |a, i| {
            if (a == app) {
                _ = self.recent.orderedRemove(i);
                break;
            }
        }
        try self.recent.insert(self.gpa, 0, app);
        self.maximized = null;
        self.pre_max.clearRetainingCapacity();
        if (self.space != 0) self.switchSpace(0, now);
        self.focus(h, now);
        self.enforceLimit(now);
        self.relayout(now, true);
        self.publishWindow(h, .opened);
    }

    /// The environment of the apps Kuroko starts (WAYLAND_DISPLAY of its
    /// own server, ...): "NAME=value" sets, "NAME" removes.
    pub fn setChildEnv(self: *Compositor, env: []const []const u8) void {
        self.child_env = env;
    }

    /// A window from an app outside Kuroko (a Wayland client). It takes
    /// the place of its app's launch placeholder when there is one;
    /// otherwise it opens like any new window. The app is found by its
    /// binary in the registry, then by its app id.
    pub fn adoptWindow(self: *Compositor, s: Surface, client: Client, now: i64) void {
        defer self.windows.endEvent();
        const exe = client.exe;
        const app = self.appForClient(exe, s.appId());
        s.setDark(self.theme.dark);
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch {};
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            if (w.surface != null or !w.waiting or w.app != app) continue;
            w.surface = s;
            w.waiting = false;
            w.status = .{};
            w.dirty = true;
            self.setClient(w, client);
            self.refreshTrustLocked(h, w);
            if (w.content.w > 0) s.configure(w.content, self.scale);
            self.full_redraw = true;
            return;
        }
        self.launch_seq += 1;
        const h = self.windows.create(.{
            .app = app,
            .surface = s,
            .seq = self.launch_seq,
            .launch_start = now,
            .ready_at = now,
        }) catch {
            s.destroy();
            return;
        };
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            self.setClient(g.ptr, client);
        }
        self.openNew(h, app, now) catch {};
    }

    /// The launcher entry of a client's app; an unknown app gets one of its
    /// own, hidden from the launcher.
    fn appForClient(self: *Compositor, exe: []const u8, app_id: []const u8) usize {
        for (self.installed.entries.items, 0..) |e, i| {
            if (exe.len > 0 and std.mem.eql(u8, e.key, exe)) return self.apps.len + i;
        }
        for (self.installed.entries.items, 0..) |e, i| {
            if (app_id.len > 0 and std.ascii.eqlIgnoreCase(e.id, app_id)) return self.apps.len + i;
        }
        const name = if (app_id.len > 0) app_id else if (exe.len > 0) std.fs.path.basename(exe) else "App";
        const i = self.installed.addUnlisted(exe, name) catch return 0;
        self.syncInstalled();
        return self.apps.len + i;
    }

    pub fn syncInstalledForTest(self: *Compositor) void {
        self.syncInstalled();
    }

    /// A record as if krkdesk had sent it (tests).
    pub fn deskRecordForTest(self: *Compositor, rec: core.format.Record) void {
        self.onDeskRecord(rec);
    }

    fn appName(self: *const Compositor, app: usize) []const u8 {
        if (app < self.app_infos.items.len) return self.app_infos.items[app].name;
        return "";
    }

    fn appIdOf(self: *const Compositor, app: usize) []const u8 {
        if (app < self.apps.len) return self.apps[app].app_id;
        const i = app - self.apps.len;
        if (i < self.installed.entries.items.len) return self.installed.entries.items[i].id;
        return "";
    }

    /// The state a window is shown in, as the app is told it.
    fn stateOf(self: *const Compositor, h: Handle, w: *const Window) tw.surface.WindowState {
        const focused = if (self.focused) |f| f.eql(h) else false;
        const maximized = if (self.maximized) |m| m.eql(h) else false;
        return .{
            .focused = focused,
            .maximized = maximized,
            .fullscreen = w.fullscreen,
            .tiled = !maximized and !w.fullscreen,
        };
    }

    /// A record from krkdesk: the app registry.
    fn onDeskRecord(self: *Compositor, rec: core.format.Record) void {
        if (rec.type_id == core.types.desk_trust) return self.applyTrustRecord(rec);
        if (rec.type_id == core.types.desk_notice) {
            const m = core.format.readStruct(core.types.DeskNotice, rec);
            if (m.kind == .influence_changed) self.influence_stale = true;
            if (m.kind == .icons_changed) self.icons_stale = true;
            return;
        }
        const res = self.installed.apply(rec) catch return;
        switch (res) {
            .none => {},
            .changed => {
                if (self.installed.last_save != null) self.apps_asked = false;
                self.syncInstalled();
                // An app installed or removed changes its windows' trust.
                self.refreshAllTrust();
            },
            .need_snapshot => self.askForApps(),
        }
    }

    // -------------------------------------------------- focus and recent

    /// Reads the influence file if krkdesk said it changed. A missing or
    /// broken file means none: the simple session list is used instead.
    fn refreshInfluence(self: *Compositor) void {
        if (!self.influence_stale) return;
        const r = self.state_reader orelse return;
        self.influence_stale = false;
        self.influence_ok = false;
        self.gpa.free(self.influence_bytes);
        self.influence_bytes = &.{};
        self.influence.picks.clearRetainingCapacity();
        const bytes = r.read(r.ctx, self.gpa, "focus.krkde") orelse return;
        self.influence_bytes = bytes;
        core.influence.decode(self.gpa, bytes, &self.influence) catch return;
        self.influence_ok = true;
    }

    /// Reads the icons if krkdesk said they changed, and gives each app its
    /// icon.
    fn refreshIcons(self: *Compositor) void {
        if (!self.icons_stale) return;
        const r = self.state_reader orelse return;
        self.icons_stale = false;
        const bytes = r.read(r.ctx, self.gpa, "icons.krkde") orelse return;
        defer self.gpa.free(bytes);
        self.icons.decode(bytes) catch return;
        self.icon_ids.clearRetainingCapacity();
        for (self.icons.icons.items) |_| {
            self.image_seq += 1;
            self.icon_ids.append(self.gpa, self.image_seq) catch return;
        }
        self.syncInstalled();
    }

    fn iconFor(self: *const Compositor, key: []const u8) chrome.Icon {
        var out: chrome.Icon = .{};
        for (self.icons.icons.items, 0..) |*ic, i| {
            if (!std.mem.eql(u8, ic.key, key) or i >= self.icon_ids.items.len) continue;
            const img: tw.Image = .{ .pixels = ic.pixels, .w = ic.w, .h = ic.h, .id = self.icon_ids.items[i] };
            if (ic.w <= 64) out.small = img else out.large = img;
        }
        return out;
    }

    fn appIcon(self: *const Compositor, app: usize) chrome.Icon {
        if (app < self.app_infos.items.len) return self.app_infos.items[app].icon;
        return .{};
    }

    /// The launcher index of an influence reference: an installed app by
    /// its binary, or one of Kuroko's own apps by its app id. Unknown
    /// references are dropped (references, not free content).
    fn resolveApp(self: *const Compositor, ref: []const u8) ?usize {
        for (self.apps, 0..) |a, i| {
            if (std.mem.eql(u8, a.app_id, ref)) return i;
        }
        for (self.installed.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, ref)) return self.apps.len + i;
        }
        return null;
    }

    /// Focus and Recent for the launcher, at the moment it opens.
    fn launcherLists(self: *Compositor, focus_out: []shell.Pick, recent_out: []shell.Pick) struct { focus: usize, recent: usize } {
        self.refreshInfluence();
        var nf: usize = 0;
        var nr: usize = 0;
        if (self.influence_ok) {
            for (self.influence.picks.items) |p| {
                const app = self.resolveApp(p.app) orelse continue;
                const pick: shell.Pick = .{ .app = app, .reason = p.reason, .value = p.value };
                switch (p.list) {
                    .focus => if (nf < focus_out.len) {
                        focus_out[nf] = pick;
                        nf += 1;
                    },
                    .recent => if (nr < recent_out.len) {
                        recent_out[nr] = pick;
                        nr += 1;
                    },
                    _ => {},
                }
            }
            return .{ .focus = nf, .recent = nr };
        }
        // No predictor: this session's launches, newest first.
        for (self.recent.items) |a| {
            if (nr == recent_out.len) break;
            recent_out[nr] = .{ .app = a };
            nr += 1;
        }
        return .{ .focus = 0, .recent = nr };
    }

    // ------------------------------------------------------------- trust

    fn setClient(self: *Compositor, w: *Window, client: Client) void {
        w.pid = client.pid;
        self.gpa.free(w.exe);
        w.exe = self.gpa.dupe(u8, client.exe) catch &.{};
    }

    /// A mark from krkdesk. A snapshot replaces all marks; windows are
    /// decided again at its end, or at once for a single change.
    fn applyTrustRecord(self: *Compositor, rec: core.format.Record) void {
        if (rec.swapped) return;
        const m = core.format.readStruct(core.types.DeskTrust, rec);
        const path = core.format.trailing(core.types.DeskTrust, rec);
        switch (m.kind) {
            .snapshot_begin => {
                self.marks.clearAll();
                return;
            },
            .snapshot_end => {},
            .mark => {
                if (m.path_len != path.len or path.len == 0) return;
                _ = self.marks.set(.{ .subject = m.subject, .level = m.level, .path = path }) catch return;
            },
            .cleared => {
                if (m.path_len != path.len) return;
                _ = self.marks.clear(m.subject, path);
            },
            _ => return,
        }
        self.refreshAllTrust();
    }

    /// The app part of a window's trust. Kuroko's own apps are trusted.
    /// An installed app counts only when the window's binary is the one
    /// the registry lists: a client that only claims an app id does not
    /// inherit the app's trust.
    fn appTrust(self: *const Compositor, w: *const Window) Trust {
        if (w.app < self.apps.len) return .trusted;
        const i = w.app - self.apps.len;
        if (i >= self.installed.entries.items.len) return self.marks.appLevel(w.exe, false);
        const e = &self.installed.entries.items[i];
        const exe = if (w.exe.len > 0) w.exe else e.key;
        const listed = e.status == .installed and std.mem.eql(u8, exe, e.key);
        return self.marks.appLevel(exe, listed);
    }

    fn decideTrust(self: *const Compositor, w: *Window) bool {
        const app = self.appTrust(w);
        const both = core.trust.combine(app, self.marks.objectLevel(w.object));
        const changed = app != w.app_trust or both != w.trust;
        w.app_trust = app;
        w.trust = both;
        return changed;
    }

    fn refreshTrustLocked(self: *Compositor, h: Handle, w: *Window) void {
        if (!self.decideTrust(w)) return;
        if (self.publisher.subscriberCount() == 0) return;
        self.scratch.clearRetainingCapacity();
        self.identityRecord(&self.scratch, h, w);
        self.publisher.broadcast(self.scratch.items);
    }

    fn refreshAllTrust(self: *Compositor) void {
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            self.refreshTrustLocked(h, g.ptr);
        }
    }

    /// A window's trust, as decided now.
    pub fn trustOf(self: *Compositor, h: Handle) ?WindowTrust {
        const g = self.windows.acquire(h) orelse return null;
        defer g.release();
        const w = g.ptr;
        _ = self.decideTrust(w);
        const exe: []const u8 = if (w.exe.len > 0) w.exe else if (w.app >= self.apps.len and w.app - self.apps.len < self.installed.entries.items.len) self.installed.entries.items[w.app - self.apps.len].key else "";
        return .{ .app = w.app_trust, .window = w.trust, .pid = w.pid, .exe = exe, .object = w.object };
    }

    /// The object open in a window (a file path; "" when none is known).
    /// Its trust joins the app's.
    pub fn setWindowObject(self: *Compositor, h: Handle, path: []const u8) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        if (std.mem.eql(u8, w.object, path)) return;
        const copy = self.gpa.dupe(u8, path) catch return;
        self.gpa.free(w.object);
        w.object = copy;
        self.refreshTrustLocked(h, w);
    }

    /// The user sets (`level`) or takes back (null) a mark: the window's
    /// Security menu. It applies at once; krkdesk saves it and confirms.
    pub fn requestTrust(self: *Compositor, subject: core.types.TrustSubject, path: []const u8, level: ?Trust) void {
        if (path.len == 0 or path[0] != '/') return;
        if (level) |l| {
            _ = self.marks.set(.{ .subject = subject, .level = l, .path = path }) catch return;
        } else _ = self.marks.clear(subject, path);
        var rec: std.ArrayList(u8) = .empty;
        defer rec.deinit(self.gpa);
        core.format.appendStruct(self.gpa, &rec, core.types.trust_request, 1, core.types.TrustRequest{
            .action = if (level == null) .clear else .set,
            .subject = subject,
            .level = level orelse .unknown,
            .path_len = @intCast(path.len),
        }, path) catch return;
        self.publisher.sendControl(rec.items);
        self.refreshAllTrust();
    }

    /// Marks the app of a window (its binary). Kuroko's own apps are
    /// always trusted and cannot be marked.
    pub fn markWindowApp(self: *Compositor, h: Handle, level: ?Trust) void {
        const t = self.trustOf(h) orelse return;
        if (t.exe.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (t.exe.len > buf.len) return;
        @memcpy(buf[0..t.exe.len], t.exe);
        self.requestTrust(.app, buf[0..t.exe.len], level);
    }

    /// Marks the object open in a window.
    pub fn markWindowObject(self: *Compositor, h: Handle, level: ?Trust) void {
        const t = self.trustOf(h) orelse return;
        if (t.object.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (t.object.len > buf.len) return;
        @memcpy(buf[0..t.object.len], t.object);
        self.requestTrust(.file, buf[0..t.object.len], level);
    }

    fn askForApps(self: *Compositor) void {
        if (self.apps_asked) return;
        self.apps_asked = true;
        var rec: std.ArrayList(u8) = .empty;
        defer rec.deinit(self.gpa);
        core.format.appendStruct(self.gpa, &rec, core.types.desk_request, 1, core.types.DeskRequest{ .kind = .app_snapshot }, "") catch return;
        self.publisher.sendControl(rec.items);
    }

    /// The launcher's entries for the installed apps, after a change.
    fn syncInstalled(self: *Compositor) void {
        for (self.installed.entries.items, 0..) |*e, i| {
            const at = self.apps.len + i;
            if (at >= self.app_infos.items.len) self.app_infos.append(self.gpa, .{ .name = e.name }) catch return;
            const info = &self.app_infos.items[at];
            info.name = e.name;
            info.hidden = !e.shown();
            info.missing = e.status == .missing;
            info.update = e.update;
            info.icon = self.iconFor(e.key);
        }
        self.full_redraw = true;
    }

    /// Brings a window up wherever it is and shows the way to it: an
    /// outline travels from `from` to the window, then the window flashes
    /// once. A minimized window also grows out of `from` into its tile.
    pub fn activate(self: *Compositor, h: Handle, from: Rect, now: i64) void {
        if (self.isFullscreen(h)) {
            for (self.spaces.items, 0..) |x, i| {
                if (x.eql(h)) self.switchSpace(i + 1, now);
            }
            self.startCue(h, from, now);
            return;
        }
        if (self.space != 0) self.switchSpace(0, now);
        if (contains(self.shelf.items, h)) {
            self.panelClick(h, now);
            self.growFrom(h, from, now);
        } else {
            self.focus(h, now);
        }
        self.startCue(h, from, now);
    }

    fn growFrom(self: *Compositor, h: Handle, from: Rect, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        g.ptr.from = RectF.from(from);
        g.ptr.anim_start = now;
        g.ptr.placed = true;
    }

    /// An action on a panel window. Anything that brings it out shows the
    /// way: the outline travels from its thumbnail (or its preview) to
    /// where it lands, then it flashes once, as from the launcher.
    fn fromPanel(self: *Compositor, h: Handle, what: PreviewButton, now: i64) void {
        const from = self.previewCellOf(h, now) orelse self.panelRectOf(h) orelse Rect{};
        self.preview = null;
        // A window on screen: bring it forward and show where it is.
        if (!self.isShelved(h)) switch (what) {
            .close => return self.requestClose(h, now),
            .minimize => return self.shelve(h, now),
            .restore => return self.activate(h, from, now),
            .maximize => {
                if (!self.isMaximized(h)) self.toggleMaximize(h, now);
                return self.startCue(h, from, now);
            },
            .fullscreen => {
                if (!self.isFullscreen(h)) self.enterFullscreen(h, now);
                return self.startCue(h, from, now);
            },
        };
        switch (what) {
            .close => return self.requestClose(h, now),
            .minimize => return,
            .restore => self.panelClick(h, now),
            .maximize => {
                if (self.maximized != null) self.panelClick(h, now) else {
                    self.restore(h, now);
                    self.toggleMaximize(h, now);
                }
            },
            .fullscreen => {
                self.enterFullscreen(h, now);
                // It zooms out of the preview into the whole screen.
                if (self.windows.acquire(h)) |g| {
                    defer g.release();
                    g.ptr.fs_from = RectF.from(from);
                }
                self.startCue(h, from, now);
                return;
            },
        }
        self.growFrom(h, from, now);
        self.startCue(h, from, now);
    }

    // The panel preview: hovering a panel window shows it enlarged, past
    // the panel's edge, with close, restore, maximize and full screen.

    const preview_w = 400;
    const preview_bar = 36;
    const preview_r: f32 = 13;
    /// Cells of the grid for several windows.
    const cell_w = 360;
    const cell_body = 220;
    const cell_gap = 12;
    /// Room for the heading inside the grid's backing.
    const grid_head = 28;

    fn previewCols(self: *const Compositor, x0: i32) usize {
        const room = self.screen.w - x0 - 8;
        return @intCast(@max(1, @divTrunc(room + cell_gap, cell_w + cell_gap)));
    }

    /// A cell of the preview at full size. One window: by its shape, right
    /// of the panel, level with its thumbnail, so the panel's other
    /// thumbnails stay visible and reachable. Several: a grid right of the
    /// panel that grows to the right, then down.
    fn previewCellFull(self: *Compositor, p: *const Preview, i: usize) Rect {
        const x0 = shell.panel_w + 12;
        if (p.n == 1) {
            const g = self.windows.acquire(p.items[0]);
            const aspect: f32 = blk: {
                const gg = g orelse break :blk 0.66;
                defer gg.release();
                const c = gg.ptr.content;
                break :blk if (c.w > 0) @as(f32, @floatFromInt(c.h)) / @as(f32, @floatFromInt(c.w)) else 0.66;
            };
            const body_h: i32 = std.math.clamp(@as(i32, @intFromFloat(preview_w * aspect)), 160, 320);
            var full = Rect{ .x = x0, .y = p.anchor.y - preview_bar, .w = preview_w, .h = preview_bar + body_h };
            if (full.bottom() > self.screen.h - 8) full.y = self.screen.h - 8 - full.h;
            full.y = @max(full.y, shell.top_bar_h + 4);
            return full;
        }
        // Several: over the window area, right of the panel.
        const gx0 = shell.panel_w + 14;
        const cols = self.previewCols(gx0);
        const rows = (p.n + cols - 1) / cols;
        const ch: i32 = preview_bar + cell_body;
        const grid_h: i32 = @as(i32, @intCast(rows)) * (ch + cell_gap) - cell_gap;
        var y0 = p.anchor.y - preview_bar + grid_head;
        if (y0 + grid_h > self.screen.h - 16) y0 = self.screen.h - 16 - grid_h;
        y0 = @max(y0, shell.top_bar_h + 12 + grid_head);
        const col: i32 = @intCast(i % cols);
        const row: i32 = @intCast(i / cols);
        return .{ .x = gx0 + 10 + col * (cell_w + cell_gap), .y = y0 + row * (ch + cell_gap), .w = cell_w, .h = ch };
    }

    /// The cell while the view grows out of the thumbnail.
    fn previewCell(self: *Compositor, p: *const Preview, i: usize, now: i64) Rect {
        const full = self.previewCellFull(p, i);
        const t = core.anim.easeOutCubic(self.preview_t.value(now));
        return RectF.lerp(RectF.from(p.anchor), RectF.from(full), t).round();
    }

    fn previewCellOf(self: *Compositor, h: Handle, now: i64) ?Rect {
        const p = self.preview orelse return null;
        for (p.items[0..p.n], 0..) |x, i| {
            if (x.eql(h)) return self.previewCell(&p, i, now);
        }
        return null;
    }

    /// The semi-transparent backing of the grid (several windows).
    fn previewBacking(self: *Compositor, p: *const Preview) ?Rect {
        if (p.n < 2) return null;
        var r = self.previewCellFull(p, 0);
        for (1..p.n) |i| r = r.unite(self.previewCellFull(p, i));
        r = r.inset(-10);
        r.y -= grid_head;
        r.h += grid_head;
        return r;
    }

    /// Where the pointer can be without closing the view: the cells, the
    /// backing, the thumbnail, and the strip between them.
    fn previewKeepArea(self: *Compositor, p: *const Preview) Rect {
        var r = self.previewBacking(p) orelse self.previewCellFull(p, 0);
        r = r.unite(p.anchor.inset(-4));
        r = r.unite(.{ .x = 0, .y = r.y, .w = 1, .h = r.h });
        return r;
    }

    fn previewButtonCenter(r: Rect, i: usize) [2]f32 {
        return .{
            @as(f32, @floatFromInt(r.x)) + 10 + preview_r + @as(f32, @floatFromInt(i)) * (2 * preview_r + 6),
            @as(f32, @floatFromInt(r.y)) + preview_bar / 2.0,
        };
    }

    const PreviewHit = struct { h: Handle, button: ?PreviewButton };

    /// The window (and button) under the pointer in the preview.
    fn previewHit(self: *Compositor, x: f32, y: f32) ?PreviewHit {
        const p = self.preview orelse return null;
        for (p.items[0..p.n], 0..) |h, i| {
            const r = self.previewCellFull(&p, i);
            if (!r.contains(x, y)) continue;
            for (0..4) |b| {
                const c = previewButtonCenter(r, b);
                if (@abs(x - c[0]) <= preview_r + 2 and @abs(y - c[1]) <= preview_r + 2) {
                    // The second button minimizes a window on screen and
                    // brings back a minimized one.
                    const which: PreviewButton = if (b == 1 and !self.isShelved(h)) .minimize else @enumFromInt(b);
                    return .{ .h = h, .button = which };
                }
            }
            return .{ .h = h, .button = null };
        }
        return null;
    }

    /// Where a preview button is (for tests and scripts).
    pub fn previewButtonPos(self: *Compositor, h: Handle, which: PreviewButton) ?[2]f32 {
        const p = self.preview orelse return null;
        for (p.items[0..p.n], 0..) |x, i| {
            if (x.eql(h)) return previewButtonCenter(self.previewCellFull(&p, i), if (which == .minimize) 1 else @intFromEnum(which));
        }
        return null;
    }

    /// Opens the view for the group under the pointer; keeps it while the
    /// pointer stays on it.
    fn updatePreview(self: *Compositor, x: f32, y: f32, now: i64) void {
        if (self.panel_menu != null) return;
        if (self.preview) |p| {
            var alive = true;
            for (p.items[0..p.n]) |h| {
                if (!self.windows.isLive(h)) alive = false;
            }
            if (!alive) {
                self.preview = null;
            } else if (self.previewKeepArea(&p).contains(x, y)) {
                if (self.groupAt(x, y)) |gr| {
                    if (gr.app != p.app) self.openPreview(gr, now);
                }
                return;
            }
        }
        if (self.groupAt(x, y)) |gr| {
            if (self.preview == null or self.preview.?.app != gr.app) self.openPreview(gr, now);
        } else self.preview = null;
    }

    fn openPreview(self: *Compositor, gr: Group, now: i64) void {
        var p = Preview{ .app = gr.app, .anchor = gr.thumb() };
        // On screen first, then minimized, most recent first.
        p.n = self.windowsOf(gr.app, &p.items);
        self.preview = p;
        self.preview_t.snap(0);
        self.preview_t.set(1, now, 160);
    }

    fn isShelved(self: *Compositor, h: Handle) bool {
        return contains(self.shelf.items, h);
    }

    fn appOf(self: *Compositor, h: Handle) ?usize {
        const g = self.windows.acquire(h) orelse return null;
        defer g.release();
        return g.ptr.app;
    }

    /// The window on screen whose enlarged view the pointer is in.
    fn previewPointed(self: *Compositor) ?Handle {
        const p = self.preview orelse return null;
        const h = if (self.previewHit(self.px, self.py)) |hit| hit.h else if (p.n == 1 and self.previewKeepArea(&p).contains(self.px, self.py)) p.items[0] else return null;
        if (self.isShelved(h)) return null;
        return h;
    }

    /// While the pointer is in the enlarged view of a window that is on
    /// screen, that window's border pulses slowly, so the eye finds it:
    /// one soft pulse every 1.2 s (well under 3 flashes per second).
    fn drawPointedPulse(self: *Compositor, cv: *Canvas, now: i64) void {
        const h = self.previewPointed() orelse return;
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        if (w.fullscreen) return;
        const period: i64 = pulse_ms * ms;
        const ph: f32 = @as(f32, @floatFromInt(@mod(now, period))) / @as(f32, @floatFromInt(period));
        const f = 0.5 - 0.5 * @cos(std.math.tau * ph);
        const frame = currentFrame(w, now);
        const th = &self.theme;
        cv.fillRect(frame, th.get(.accent).fade(0.08 * f));
        cv.strokeRect(frame.inset(1), 4, th.get(.accent).fade(0.25 + 0.75 * f));
    }

    fn drawPreview(self: *Compositor, cv: *Canvas, now: i64) void {
        const p = self.preview orelse return;
        const th = &self.theme;
        const t = self.preview_t.value(now);
        // Several windows: a semi-transparent backing holds the grid.
        if (self.previewBacking(&p)) |b| {
            const full_b = b;
            const cur_b = RectF.lerp(RectF.from(p.anchor), RectF.from(full_b), core.anim.easeOutCubic(t)).round();
            cv.fillRoundRect(cur_b, 16, th.get(.overlay_tint).fade(0.7));
            cv.strokeRoundRect(cur_b, 16, 1, th.get(.border).fade(0.8));
            if (t > 0.9) {
                var buf: [64]u8 = undefined;
                const head = std.fmt.bufPrint(&buf, "{s}: {d} windows. Pick one; Esc closes", .{ self.appName(p.app), p.n }) catch "";
                _ = cv.text(@floatFromInt(full_b.x + 16), @floatFromInt(full_b.y + 9), head, .{ .size = .small, .weight = .semibold }, th.get(.text));
            }
        }
        const hit = self.previewHit(self.px, self.py);
        for (p.items[0..p.n], 0..) |h, i| {
            const r = self.previewCell(&p, i, now);
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            const hot_cell = hit != null and hit.?.h.eql(h);
            // In the grid the cells are a little see-through too.
            const alpha: f32 = if (p.n > 1 and !hot_cell) 0.86 else 1;
            cv.fillRoundRect(r.translate(0, 6), 12, th.get(.shadow).fade(alpha));
            cv.fillRoundRect(r, 12, th.get(.chrome_focused).fade(alpha));
            const body = Rect{ .x = r.x + 6, .y = r.y + @as(i32, @intFromFloat(preview_bar * t)), .w = r.w - 12, .h = r.h - @as(i32, @intFromFloat(preview_bar * t)) - 6 };
            self.ensureDrawn(w);
            cv.fillRect(body, th.get(.surface).fade(alpha));
            if (w.pixels.len > 0 and w.buf_w > 0 and w.buf_h > 0 and body.w > 0 and body.h > 0) {
                // Keep the window's proportions: fit, centered.
                const bw: f32 = @floatFromInt(body.w);
                const bh: f32 = @floatFromInt(body.h);
                const sw: f32 = @floatFromInt(w.buf_w);
                const sh: f32 = @floatFromInt(w.buf_h);
                const k = @min(bw / sw, bh / sh);
                const fw: i32 = @intFromFloat(sw * k);
                const fh: i32 = @intFromFloat(sh * k);
                const fit = Rect{ .x = body.x + @divTrunc(body.w - fw, 2), .y = body.y + @divTrunc(body.h - fh, 2), .w = fw, .h = fh };
                cv.blitScaled(w.image(), fit, @intFromFloat(255 * alpha));
            }
            cv.strokeRoundRect(r, 12, if (hot_cell) 3 else 2, th.get(.accent).fade(if (hot_cell or p.n == 1) 1 else 0.5));
            if (t < 0.9) continue;
            // Bar: the buttons at the left (full size), then the title.
            const glyphs = [_]chrome.Glyph{ .close, if (w.shelved) .to_desktop else .minimize, .maximize, .fullscreen };
            for (glyphs, 0..) |gl, b| {
                const c = previewButtonCenter(r, b);
                const hot = hot_cell and hit.?.button != null and (if (hit.?.button.? == .minimize) 1 else @intFromEnum(hit.?.button.?)) == b;
                cv.fillCircle(c[0], c[1], preview_r, th.get(if (hot) .accent else .surface));
                cv.strokeRoundRect(.{ .x = @intFromFloat(c[0] - preview_r), .y = @intFromFloat(c[1] - preview_r), .w = @intFromFloat(2 * preview_r), .h = @intFromFloat(2 * preview_r) }, preview_r, 1, th.get(.border));
                chrome.drawGlyph(cv, gl, c[0], c[1], preview_r, th.get(if (hot) .accent_text else .text));
            }
            const title = if (w.surface) |sf| sf.title() else self.appName(w.app);
            var tb: [48]u8 = undefined;
            const label = if (p.n > 1) (std.fmt.bufPrint(&tb, "{d}. {s} \u{00B7} {s}", .{ i + 1, title, self.whereIs(w) }) catch title) else title;
            const tx: f32 = @as(f32, @floatFromInt(r.x)) + 10 + 4 * (2 * preview_r + 6) + 8;
            _ = cv.textEllipsis(tx, @as(f32, @floatFromInt(r.y)) + 9, label, @as(f32, @floatFromInt(r.right())) - tx - 10, .{ .size = .body, .weight = .semibold }, th.get(.chrome_text));
            // What the hovered button does, in words.
            if (hot_cell) {
                if (hit.?.button) |b| {
                    const tips = [_][]const u8{ "Close", "Back to the window area", "Maximize", "Full screen", "Minimize" };
                    const tip = tips[@intFromEnum(b)];
                    const m = tw.font.Metrics.of(.{ .size = .small }, cv.scale);
                    const tr = Rect{ .x = r.x + 8, .y = r.y + preview_bar + 4, .w = @as(i32, @intFromFloat(m.width(tip))) + 16, .h = 22 };
                    cv.fillRoundRect(tr, 6, th.get(.chrome_focused));
                    cv.strokeRoundRect(tr, 6, 1, th.get(.border));
                    _ = cv.text(@floatFromInt(tr.x + 8), @floatFromInt(tr.y + 3), tip, .{ .size = .small }, th.get(.text));
                }
            }
        }
    }

    // --- right-click menu on a panel group

    fn openPanelMenu(self: *Compositor, gr: Group, x: f32, y: f32) void {
        var m = PanelMenu{ .app = gr.app, .count = gr.count, .visible = gr.visible, .rect = .{} };
        var buf: [3]PanelMenu.Item = undefined;
        const n: i32 = @intCast(m.items(&buf).len);
        m.rect = (Rect{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = 190, .h = n * PanelMenu.item_h + 12 }).clampInto(self.screenRect().inset(8));
        self.panel_menu = m;
        self.preview = null;
        self.full_redraw = true;
    }

    fn panelMenuItemAt(self: *const Compositor, x: f32, y: f32) ?PanelMenu.Item {
        const m = self.panel_menu orelse return null;
        var buf: [3]PanelMenu.Item = undefined;
        for (m.items(&buf), 0..) |it, i| {
            const r = Rect{ .x = m.rect.x + 6, .y = m.rect.y + 6 + @as(i32, @intCast(i)) * PanelMenu.item_h, .w = m.rect.w - 12, .h = PanelMenu.item_h };
            if (r.contains(x, y)) return it;
        }
        return null;
    }

    fn panelMenuPress(self: *Compositor, x: f32, y: f32, now: i64) void {
        const m = self.panel_menu.?;
        const picked = self.panelMenuItemAt(x, y);
        self.panel_menu = null;
        self.full_redraw = true;
        const it = picked orelse return;
        var hs: [8]Handle = undefined;
        const n = self.windowsOf(m.app, &hs);
        switch (it) {
            .close_all => for (hs[0..n]) |h| self.requestClose(h, now),
            .minimize_all => for (hs[0..n]) |h| {
                if (!self.isShelved(h)) self.shelve(h, now);
            },
            .show_all => {
                if (self.maximized != null) {
                    self.maximized = null;
                    self.pre_max.clearRetainingCapacity();
                }
                for (hs[0..n]) |h| {
                    if (!self.isShelved(h)) continue;
                    self.restore(h, now);
                    self.flashAfterFly(h, now);
                }
            },
        }
    }

    fn drawPanelMenu(self: *Compositor, cv: *Canvas) void {
        const m = self.panel_menu orelse return;
        const th = &self.theme;
        cv.fillRoundRect(m.rect.translate(0, 4), 10, th.get(.shadow));
        cv.fillRoundRect(m.rect, 10, th.get(.surface));
        cv.strokeRoundRect(m.rect, 10, 1, th.get(.border));
        var buf: [3]PanelMenu.Item = undefined;
        const hover = self.panelMenuItemAt(self.px, self.py);
        for (m.items(&buf), 0..) |it, i| {
            const r = Rect{ .x = m.rect.x + 6, .y = m.rect.y + 6 + @as(i32, @intCast(i)) * PanelMenu.item_h, .w = m.rect.w - 12, .h = PanelMenu.item_h };
            if (hover != null and hover.? == it) cv.fillRoundRect(r, 6, th.get(.accent).fade(0.14));
            var lb: [40]u8 = undefined;
            const label = switch (it) {
                .show_all => std.fmt.bufPrint(&lb, "Show all ({d})", .{m.count}) catch "Show all",
                .close_all => std.fmt.bufPrint(&lb, "Close all ({d})", .{m.count}) catch "Close all",
                .minimize_all => std.fmt.bufPrint(&lb, "Minimize ({d})", .{m.visible}) catch "Minimize",
            };
            _ = cv.text(@floatFromInt(r.x + 10), @floatFromInt(r.y + 6), label, .{}, th.get(if (it == .close_all) .danger else .text));
        }
    }

    /// A window restored from the panel flashes once when it lands.
    fn flashAfterFly(self: *Compositor, h: Handle, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        g.ptr.flash_start = now + (anim_ms - 40) * ms;
        self.full_redraw = true;
    }

    fn startCue(self: *Compositor, h: Handle, from: Rect, now: i64) void {
        self.cue = .{ .h = h, .from = RectF.from(from), .start = now };
        if (self.windows.acquire(h)) |g| {
            defer g.release();
            g.ptr.flash_start = now + (cue_ms - 80) * ms;
        }
        self.full_redraw = true;
    }

    fn openChooser(self: *Compositor, app: usize, hs: []const Handle, icon: Rect) void {
        var c = Chooser{ .app = app };
        c.n = @min(hs.len, c.items.len);
        @memcpy(c.items[0..c.n], hs[0..c.n]);
        const w: i32 = Chooser.pad + @as(i32, @intCast(c.n + 1)) * (Chooser.thumb_w + Chooser.pad);
        const h: i32 = Chooser.head + Chooser.thumb_h + 34;
        // Floats just below the icon it came from, clamped to the screen.
        const cx = icon.x + @divTrunc(icon.w, 2);
        c.rect = (Rect{ .x = cx - @divTrunc(w, 2), .y = icon.bottom() + 8, .w = w, .h = h }).clampInto(self.screenRect().inset(12));
        self.chooser = c;
        self.full_redraw = true;
    }

    fn chooserPress(self: *Compositor, x: f32, y: f32, now: i64) void {
        const c = self.chooser.?;
        self.chooser = null;
        self.full_redraw = true;
        const i = c.at(x, y) orelse return;
        if (i < c.n) self.activate(c.items[i], c.slot(i), now) else self.launchFrom(c.app, c.slot(i), now);
    }

    fn drawChooser(self: *Compositor, cv: *Canvas) void {
        const c = self.chooser orelse return;
        const th = &self.theme;
        const r = c.rect;
        cv.fillRoundRect(r.translate(0, 6), 14, th.get(.shadow));
        cv.fillRoundRect(r, 14, th.get(.surface));
        cv.strokeRoundRect(r, 14, 1, th.get(.border));
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s}: {d} windows. Pick one", .{ self.appName(c.app), c.n }) catch self.appName(c.app);
        _ = cv.text(@floatFromInt(r.x + Chooser.pad), @floatFromInt(r.y + 12), title, .{ .size = .body, .weight = .semibold }, th.get(.text));
        const hover = c.at(self.px, self.py);
        for (0..c.n + 1) |i| {
            const sr = c.slot(i);
            const hovered = hover != null and hover.? == i;
            if (i < c.n) {
                const g = self.windows.acquire(c.items[i]) orelse continue;
                defer g.release();
                self.ensureDrawn(g.ptr);
                cv.fillRect(sr, th.get(.surface_alt));
                if (g.ptr.pixels.len > 0) cv.blitScaled(g.ptr.image(), sr, 255);
                const name = if (g.ptr.surface) |sf| sf.title() else self.appName(g.ptr.app);
                var lb: [80]u8 = undefined;
                const label = std.fmt.bufPrint(&lb, "{d}. {s} \u{00B7} {s}", .{ i + 1, name, self.whereIs(g.ptr) }) catch name;
                // The window itself is outlined on screen while its
                // thumbnail is under the pointer.
                if (hovered and !g.ptr.shelved and !g.ptr.fullscreen) {
                    const f = g.ptr.target;
                    cv.fillRect(f, th.get(.accent).fade(0.10));
                    cv.strokeRect(f.inset(1), 4, th.get(.accent));
                }
                _ = cv.textEllipsis(@floatFromInt(sr.x), @floatFromInt(sr.bottom() + 8), label, @floatFromInt(sr.w), .{ .size = .small }, th.get(.text));
            } else {
                // New window: a plus.
                cv.fillRoundRect(sr, 10, th.get(.surface_alt));
                const cx: f32 = @as(f32, @floatFromInt(sr.x)) + @as(f32, @floatFromInt(sr.w)) / 2;
                const cy: f32 = @as(f32, @floatFromInt(sr.y)) + @as(f32, @floatFromInt(sr.h)) / 2;
                cv.line(cx - 16, cy, cx + 16, cy, 3, th.get(.text_dim));
                cv.line(cx, cy - 16, cx, cy + 16, 3, th.get(.text_dim));
                _ = cv.text(@floatFromInt(sr.x), @floatFromInt(sr.bottom() + 8), "New window", .{ .size = .small }, th.get(.text));
            }
            cv.strokeRoundRect(sr.inset(-3), 8, if (hovered) 3 else 1, th.get(if (hovered) .accent else .border));
        }
    }

    /// Where a window is, in words: "top left", "minimized", "full screen".
    fn whereIs(self: *const Compositor, w: *const Window) []const u8 {
        if (w.shelved) return "minimized";
        if (w.fullscreen) return "full screen";
        if (self.slot_count <= 1) return "whole screen";
        const area = self.workArea();
        const cx = w.target.x + @divTrunc(w.target.w, 2);
        const cy = w.target.y + @divTrunc(w.target.h, 2);
        const left = cx < area.x + @divTrunc(area.w, 2);
        const full_h = w.target.h > @divTrunc(area.h * 3, 4);
        if (full_h) return if (left) "left" else "right";
        const top = cy < area.y + @divTrunc(area.h, 2);
        if (top) return if (left) "top left" else "top right";
        return if (left) "bottom left" else "bottom right";
    }

    /// The travel outline and the window flash, on top of the windows.
    fn drawCue(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        if (self.cue) |cue| {
            const el = now - cue.start;
            if (el >= cue_ms * ms) {
                self.cue = null;
            } else {
                const g = self.windows.acquire(cue.h) orelse return;
                defer g.release();
                const to: Rect = if (g.ptr.fullscreen) self.screenRect() else if (g.ptr.shelved) (self.panelRectOf(cue.h) orelse g.ptr.target) else g.ptr.target;
                const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(el)) / @as(f32, @floatFromInt(cue_ms * ms)));
                const cur = RectF.lerp(cue.from, RectF.from(to), t).round();
                cv.fillRoundRect(cur, 10, th.get(.accent).fade(0.10 * (1 - t)));
                cv.strokeRoundRect(cur, 10, 3, th.get(.accent).fade(0.9 - 0.5 * t));
            }
        }
        // The flash: one pulse of the frame (and a light tint).
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            if (w.flash_start < 0 or now < w.flash_start) continue;
            const el = now - w.flash_start;
            if (el >= flash_ms * ms) {
                w.flash_start = -1;
                continue;
            }
            if (w.shelved) continue;
            if (w.fullscreen and self.activeFs() == null) continue;
            const f = @sin(std.math.pi * @as(f32, @floatFromInt(el)) / @as(f32, @floatFromInt(flash_ms * ms)));
            const frame = if (w.fullscreen) self.screenRect() else currentFrame(w, now);
            cv.fillRect(frame, th.get(.accent).fade(0.16 * f));
            cv.strokeRect(frame.inset(1), 4, th.get(.accent).fade(f));
        }
    }

    fn pointerMotion(self: *Compositor, x: f32, y: f32, now: i64) void {
        self.px = x;
        self.py = y;
        if (self.launcher.open) {
            self.launcher.pointerMotion(self.app_infos.items, x, y);
            self.full_redraw = true;
            return;
        }
        if (self.dialogMotion(x, y, now)) return;
        if (self.activeFs()) |fs| {
            self.fsPointerMotion(fs, x, y, now);
            return;
        }
        switch (self.drag) {
            .menu_slider => |dir| {
                self.system.setLevel(dir, self.top_menu.sliderLevel(self.screen.w, &self.system, dir, x));
                self.full_redraw = true;
                return;
            },
            .panel => |*d| {
                if (@abs(x - d.x) + @abs(y - d.y) > 5) {
                    d.moved = true;
                    self.preview = null;
                }
                self.cursor = if (d.moved) .grab else .arrow;
                self.full_redraw = true;
                return;
            },
            .col_border => |d| {
                const area = self.workArea();
                const b = d.boundary + (x - d.start);
                self.overrides.col_split[d.row] = (b - @as(f32, @floatFromInt(area.x))) / @as(f32, @floatFromInt(area.w));
                self.relayout(now, false);
                return;
            },
            .row_border => |d| {
                const area = self.workArea();
                const b = d.boundary + (y - d.start);
                self.overrides.row_split = (b - @as(f32, @floatFromInt(area.y))) / @as(f32, @floatFromInt(area.h));
                self.relayout(now, false);
                return;
            },
            .title => |*d| {
                if (!d.moved and @abs(x - d.x) + @abs(y - d.y) > 5) {
                    d.moved = true;
                    const vis = self.visibleTiles();
                    self.reorder_n = @min(self.slot_count, vis.len);
                    @memcpy(self.reorder_slots[0..self.reorder_n], self.slots[0..self.reorder_n]);
                    @memcpy(self.reorder_tiles[0..self.reorder_n], vis[0..self.reorder_n]);
                }
                if (d.moved) {
                    const want = self.reorderTarget(d.h, x, y);
                    if (!sameHandle(want, d.want)) {
                        d.want = want;
                        d.want_since = now;
                    }
                }
                self.cursor = if (d.moved) .grab else .arrow;
                self.full_redraw = true;
                return;
            },
            .content => |h| {
                self.sendToContent(h, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
                return;
            },
            else => {},
        }

        if (self.drag == .none) self.updatePreview(x, y, now);
        if (self.preview != null) {
            self.cursor = .arrow;
            self.setContentHover(null, now);
            self.full_redraw = true;
            return;
        }

        // Chrome: expanding buttons and the menu.
        for (self.visibleTiles()) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            const frame = currentFrame(w, now);
            if (chrome.buttonZone(frame).contains(x, y)) {
                if (w.buttons_t.to < 0.5) w.aimed = chrome.aimedAt(frame, x);
                w.buttons_t.set(1, now, 120);
            } else w.buttons_t.set(0, now, 200);
            const bar = Rect{ .x = frame.x, .y = frame.y, .w = frame.w, .h = chrome.title_h };
            if (bar.contains(x, y) and !chrome.buttonZone(frame).contains(x, y)) {
                w.menu_leave_since = null;
                if (w.menu_rest_since == null) w.menu_rest_since = now;
            } else {
                w.menu_rest_since = null;
                if (w.menu_t.to > 0.5 and w.menu_leave_since == null) w.menu_leave_since = now;
            }
        }

        const border = self.borderAt(x, y);
        self.cursor = switch (border) {
            .col_border => .resize_ew,
            .row_border => .resize_ns,
            else => .arrow,
        };

        // Content.
        const h = self.windowAt(x, y, now);
        var in_content: ?Handle = null;
        if (h) |hh| {
            const g = self.windows.acquire(hh).?;
            defer g.release();
            if (self.contentOf(g.ptr).contains(x, y) and border == .none) in_content = hh;
        }
        self.setContentHover(in_content, now);
        if (in_content) |c| {
            self.sendToContent(c, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
            const g = self.windows.acquire(c).?;
            defer g.release();
            if (g.ptr.surface) |s| self.cursor = s.cursor();
        }
        self.full_redraw = true;
    }

    // In a full-screen space everything goes to the window, except its
    // title bar, which slides down when the pointer touches the top edge.

    fn fsPointerMotion(self: *Compositor, h: Handle, x: f32, y: f32, now: i64) void {
        self.full_redraw = true;
        if (self.drag == .content) {
            self.sendToContent(h, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
            return;
        }
        if (y <= 2) {
            self.fs_bar.set(1, now, 180);
        } else if (y > chrome.title_h + 24 and self.drag == .none) {
            self.fs_bar.set(0, now, 200);
        }
        const g = self.windows.acquire(h) orelse return;
        const w = g.ptr;
        const bar_shown = self.fs_bar.to > 0.5;
        const frame = self.chromeFrame(w, now);
        if (bar_shown and chrome.buttonZone(frame).contains(x, y)) {
            if (w.buttons_t.to < 0.5) w.aimed = chrome.aimedAt(frame, x);
            w.buttons_t.set(1, now, 120);
        } else w.buttons_t.set(0, now, 200);
        const in_bar = bar_shown and y < @as(f32, chrome.title_h);
        const cur = if (w.surface) |s| s.cursor() else .arrow;
        g.release();
        self.cursor = .arrow;
        if (in_bar) {
            self.setContentHover(null, now);
            return;
        }
        self.setContentHover(h, now);
        self.sendToContent(h, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
        self.cursor = cur;
    }

    fn fsPress(self: *Compositor, h: Handle, button: core.input.Button, x: f32, y: f32, now: i64) void {
        if (self.fs_bar.to > 0.5 and y < @as(f32, chrome.title_h)) {
            if (self.spaceDotAt(x, y, true)) |i| {
                self.switchSpace(i, now);
                return;
            }
            if (button != .left) return;
            const g = self.windows.acquire(h) orelse return;
            defer g.release();
            const menu = if (g.ptr.surface) |s| s.menu() else &[_][]const u8{};
            switch (chrome.hit(self.chromeFrame(g.ptr, now), self.chromeState(g.ptr, now), menu, self.scale, x, y)) {
                .button => |b| self.drag = .{ .button = .{ .h = h, .which = b } },
                else => {},
            }
            return;
        }
        self.drag = .{ .content = h };
        self.sendToContent(h, .{ .pointer_button = .{ .button = button, .pressed = true, .x = x, .y = y } }, now);
    }

    /// Space dots: one per space, the desktop first. On the desktop they sit
    /// in the middle of the top bar; in full screen at the right of the
    /// revealed title bar. Shown only when a full-screen space exists.
    fn spaceDots(self: *const Compositor, out: []Rect, fs: bool, now: i64) usize {
        if (self.spaces.items.len == 0) return 0;
        const n = @min(self.spaces.items.len + 1, out.len);
        const step: i32 = 16;
        const total: i32 = @as(i32, @intCast(n)) * step;
        const x0: i32 = if (fs) self.screen.w - 24 - total else @divTrunc(self.screen.w - total, 2);
        const bar_y: i32 = if (fs) blk: {
            const t = self.fs_bar.value(now);
            break :blk @intFromFloat(@round(-@as(f32, chrome.title_h) * (1 - t)));
        } else 0;
        const bh: i32 = if (fs) chrome.title_h else shell.top_bar_h;
        for (0..n) |i| out[i] = .{ .x = x0 + @as(i32, @intCast(i)) * step, .y = bar_y + @divTrunc(bh - step, 2), .w = step, .h = step };
        return n;
    }

    fn spaceDotAt(self: *const Compositor, x: f32, y: f32, fs: bool) ?usize {
        var buf: [16]Rect = undefined;
        const n = self.spaceDots(&buf, fs, 0x7fff_ffff_ffff);
        for (buf[0..n], 0..) |r, i| {
            if (r.contains(x, y)) return i;
        }
        return null;
    }

    fn drawSpaceDots(self: *const Compositor, cv: *Canvas, fs: bool, now: i64) void {
        const th = &self.theme;
        var buf: [16]Rect = undefined;
        const n = self.spaceDots(&buf, fs, now);
        for (buf[0..n], 0..) |r, i| {
            const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
            const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
            const active = i == self.space;
            const col = th.get(if (active) .accent else .text_dim);
            if (i == 0) {
                // The desktop: a small square (shape cue, not only color).
                const q: i32 = if (active) 9 else 7;
                const rr = Rect{ .x = @as(i32, @intFromFloat(cx)) - @divTrunc(q, 2), .y = @as(i32, @intFromFloat(cy)) - @divTrunc(q, 2), .w = q, .h = q };
                if (active) cv.fillRect(rr, col) else cv.hairlineRect(rr, col);
            } else if (active) {
                cv.fillCircle(cx, cy, 4.5, col);
            } else {
                cv.fillCircle(cx, cy, 3.5, col);
                cv.fillCircle(cx, cy, 2, th.get(if (fs) .chrome else .chrome_focused));
            }
        }
    }

    fn press(self: *Compositor, button: core.input.Button, x: f32, y: f32, now: i64) void {
        self.full_redraw = true;
        // Dialogs float above the windows; a modal one blocks what is
        // under it and is nudged instead.
        if (self.dialogAt(x, y)) |i| {
            const d = &self.dialogs.items[i];
            self.dialog_focus = d.id;
            self.drag = .{ .dialog = d.id };
            self.sendToDialog(i, .{ .pointer_button = .{ .button = button, .pressed = true, .x = x, .y = y } }, now);
            self.raiseDialog(i);
            return;
        }
        if (self.modalBlocking(x, y, now)) |i| {
            self.dialogs.items[i].nudge_start = now;
            return;
        }
        self.dialog_focus = null;
        if (self.chooser != null) {
            if (button == .left) self.chooserPress(x, y, now) else self.chooser = null;
            return;
        }
        if (self.panel_menu) |m| {
            if (m.rect.contains(x, y)) {
                if (button == .left) self.panelMenuPress(x, y, now);
                return;
            }
            self.panel_menu = null;
            self.full_redraw = true;
        }
        // Right click on a panel group (or its enlarged view): its menu.
        if (button == .right and self.space == 0) {
            if (self.groupAt(x, y)) |gr| return self.openPanelMenu(gr, x, y);
            if (self.previewHit(x, y)) |hit| {
                if (self.preview) |p| {
                    var buf: [12]Group = undefined;
                    const n = self.groups(&buf);
                    for (buf[0..n]) |gr| {
                        if (gr.app == p.app) return self.openPanelMenu(gr, x, y);
                    }
                }
                _ = hit;
            }
        }
        // The enlarged view, when shown, is on top of the panel.
        if (self.preview) |p| {
            if (self.previewHit(x, y)) |hit| {
                if (button == .left) {
                    if (hit.button) |b| {
                        self.drag = .{ .preview_button = .{ .h = hit.h, .which = b } };
                    } else {
                        // A cell works like the thumbnail: click restores,
                        // drag tiles.
                        self.drag = .{ .panel = .{ .h = hit.h, .x = x, .y = y, .t0 = now, .moved = false } };
                    }
                }
                return;
            }
            // On the backing, between cells: nothing.
            if (self.previewBacking(&p)) |b| {
                if (b.contains(x, y)) return;
            }
        }
        if (self.space == 0 and button == .left) {
            if (self.panelButtonAt(x, y)) |b| {
                switch (b) {
                    .minimize_all => self.minimizeAll(now),
                    .close_all => self.closeAllClick(now),
                }
                return;
            }
        }
        if (self.close_all_armed != null) self.close_all_armed = null;
        if (self.space == 0 and button == .left and self.appsButtonRect().contains(x, y)) {
            self.toggleLauncher(now);
            return;
        }
        if (self.launcher.open) {
            if (button == .left) self.launcherAction(self.launcher.press(self.app_infos.items, x, y, self.mods.shift), now);
            return;
        }
        if (self.activeFs()) |fs| {
            self.fsPress(fs, button, x, y, now);
            return;
        }
        if (self.spaceDotAt(x, y, false)) |i| {
            self.switchSpace(i, now);
            return;
        }
        const top = shell.topBarHit(self.screen.w, x, y);
        if (self.top_menu.isOpen()) {
            const hit = self.top_menu.hit(self.screen.w, &self.system, x, y);
            if (hit != .none) {
                self.menuPress(hit, x, now);
                return;
            }
            if (self.top_menu.rect(self.screen.w, &self.system).contains(x, y)) return;
            // A click anywhere else closes it; on the icon that opened it,
            // that is all the click does.
            const from = self.top_menu.from;
            self.top_menu = .{};
            if (top == from) return;
        }
        switch (top) {
            .learning => {
                self.setLearning(!self.learning);
                return;
            },
            .apps => {
                if (button == .left) self.toggleLauncher(now);
                return;
            },
            .gear, .control_center, .devices, .language => {
                self.top_menu = .{ .from = top };
                return;
            },
            .none => {},
        }
        // Panel thumbnails: a click restores (or swaps, when maximized);
        // a drag tiles the window where it is dropped.
        if (self.shelfAt(x, y)) |h| {
            if (button == .left) self.drag = .{ .panel = .{ .h = h, .x = x, .y = y, .t0 = now, .moved = false } };
            return;
        }
        const border = self.borderAt(x, y);
        if (border != .none and button == .left) {
            self.drag = border;
            return;
        }
        const h = self.windowAt(x, y, now) orelse return;
        self.focus(h, now);
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        const frame = w.target;
        if (self.contentOf(w).contains(x, y)) {
            self.drag = .{ .content = h };
            self.sendToContent(h, .{ .pointer_button = .{ .button = button, .pressed = true, .x = x, .y = y } }, now);
            return;
        }
        if (button != .left) return;
        const menu = if (w.surface) |s| s.menu() else &[_][]const u8{};
        const st = self.chromeState(w, now);
        switch (chrome.hit(frame, st, menu, self.scale, x, y)) {
            .button => |b| self.drag = .{ .button = .{ .h = h, .which = b } },
            .title, .menu, .icon => {
                // Double click on the title bar: maximize, or restore.
                if (self.last_title) |lt| {
                    if (lt.h.eql(h) and now - lt.t <= double_click_ms * ms and @abs(x - lt.x) + @abs(y - lt.y) < 8) {
                        self.last_title = null;
                        self.toggleMaximize(h, now);
                        return;
                    }
                }
                self.last_title = .{ .h = h, .t = now, .x = x, .y = y };
                self.drag = .{ .title = .{ .h = h, .x = x, .y = y, .moved = false } };
            },
            .none => {},
        }
    }

    fn release(self: *Compositor, button: core.input.Button, x: f32, y: f32, now: i64) void {
        const d = self.drag;
        self.drag = .none;
        self.full_redraw = true;
        switch (d) {
            .content => |h| self.sendToContent(h, .{ .pointer_button = .{ .button = button, .pressed = false, .x = x, .y = y } }, now),
            .dialog => |id| if (self.dialogIndex(id)) |i| self.sendToDialog(i, .{ .pointer_button = .{ .button = button, .pressed = false, .x = x, .y = y } }, now),
            .button => |b| {
                // Acts on release only if the pointer is still on it.
                const g = self.windows.acquire(b.h) orelse return;
                const st = self.chromeState(g.ptr, now);
                const frame = self.chromeFrame(g.ptr, now);
                const menu = if (g.ptr.surface) |s| s.menu() else &[_][]const u8{};
                const still = chrome.hit(frame, st, menu, self.scale, x, y);
                g.release();
                if (still == .button and still.button == b.which) self.windowAction(b.h, b.which, now);
            },
            .preview_button => |b| {
                if (self.previewHit(x, y)) |hit| {
                    if (hit.h.eql(b.h) and hit.button == b.which) self.fromPanel(b.h, b.which, now);
                }
                self.preview = null;
            },
            .panel => |p| {
                if (!p.moved) {
                    self.fromPanel(p.h, .restore, now);
                } else if (!self.isShelved(p.h)) {
                    // A window on screen is already in the window area.
                    self.fromPanel(p.h, .restore, now);
                } else if (x >= @as(f32, @floatFromInt(self.panelW()))) {
                    // A quick drag puts the window next to the panel; a slow
                    // one where it is dropped.
                    const quick = now - p.t0 < quick_drag_ms * ms;
                    const from = self.panelRectOf(p.h);
                    self.panelDrop(p.h, if (quick) 0 else self.dropIndex(x, y), now);
                    if (from) |f| self.startCue(p.h, f, now);
                }
            },
            .title => |t0| {
                if (!t0.moved) return;
                var t = t0;
                // Dropped on the panel: minimize.
                if (x < @as(f32, @floatFromInt(self.panelW())) and y > shell.top_bar_h) {
                    self.previewSwap(&t, null, now);
                    self.shelve(t.h, now);
                    return;
                }
                // Dropping a window on another tile swaps the two windows
                // (the preview may not have caught up with a fast drop).
                self.previewSwap(&t, self.reorderTarget(t.h, x, y), now);
                self.landFromThumb(t.h, now);
            },
            else => {},
        }
        self.cursor = .arrow;
    }

    /// The window a reordered window `h` would swap with when dropped at
    /// (x, y): the owner of that point's tile when the drag began. Its own
    /// tile, and anywhere outside the tiles, is no target.
    fn reorderTarget(self: *const Compositor, h: Handle, x: f32, y: f32) ?Handle {
        for (self.reorder_slots[0..self.reorder_n], self.reorder_tiles[0..self.reorder_n]) |sl, th| {
            if (!sl.slot.contains(x, y)) continue;
            if (th.eql(h) or !contains(self.tiles.items, th)) return null;
            return th;
        }
        return null;
    }

    /// Shows the drop before it happens: undoes the swap with the previous
    /// partner and swaps the dragged window with `to`. Both windows move
    /// to their new tiles with the usual animation.
    fn previewSwap(self: *Compositor, d: anytype, to: ?Handle, now: i64) void {
        if (sameHandle(d.partner, to)) return;
        if (d.partner) |p| self.swapTiles(d.h, p);
        if (to) |t| self.swapTiles(d.h, t);
        d.partner = to;
        self.relayout(now, true);
    }

    fn swapTiles(self: *Compositor, a: Handle, b: Handle) void {
        var ia: ?usize = null;
        var ib: ?usize = null;
        for (self.tiles.items, 0..) |h, i| {
            if (h.eql(a)) ia = i;
            if (h.eql(b)) ib = i;
        }
        if (ia != null and ib != null) std.mem.swap(Handle, &self.tiles.items[ia.?], &self.tiles.items[ib.?]);
    }

    /// Escape during a reorder: everything goes back where it was.
    fn cancelReorder(self: *Compositor, now: i64) void {
        var d = self.drag.title;
        self.drag = .none;
        self.cursor = .arrow;
        self.previewSwap(&d, null, now);
        if (d.moved) self.landFromThumb(d.h, now);
        self.full_redraw = true;
    }

    /// The window dragged by its title bar lands in its tile from the
    /// thumbnail under the pointer.
    fn landFromThumb(self: *Compositor, h: Handle, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        g.ptr.from = RectF.from(self.dragThumbRect());
        g.ptr.anim_start = now;
    }

    /// The thumbnail that follows the pointer while a window is dragged.
    fn dragThumbRect(self: *const Compositor) Rect {
        const w: i32 = 200;
        const h: i32 = 130;
        return .{ .x = @as(i32, @intFromFloat(self.px)) - @divTrunc(w, 2), .y = @as(i32, @intFromFloat(self.py)) - 16, .w = w, .h = h };
    }

    fn drawDragThumb(self: *Compositor, cv: *Canvas, w: *Window) void {
        const th = &self.theme;
        const thumb = self.dragThumbRect();
        cv.fillRect(thumb.translate(0, 4), th.get(.shadow));
        cv.fillRect(thumb, th.get(.surface));
        if (w.pixels.len > 0) cv.blitScaled(w.image(), thumb, 255);
        cv.strokeRect(thumb, 2, th.get(.accent));
    }

    /// The window being reordered, once the drag has moved: it is drawn as
    /// a thumbnail under the pointer and a placeholder in its tile.
    fn reordering(self: *const Compositor) ?Handle {
        return switch (self.drag) {
            .title => |d| if (d.moved) d.h else null,
            else => null,
        };
    }

    /// Where a window dropped at (x, y) joins the tiles: before the tile
    /// under the pointer when on its left half, after it on its right half.
    fn dropIndex(self: *const Compositor, x: f32, y: f32) usize {
        const n = @min(self.slot_count, self.tiles.items.len);
        for (self.slots[0..n], 0..) |sl, i| {
            if (!sl.slot.contains(x, y)) continue;
            const mid: f32 = @as(f32, @floatFromInt(sl.slot.x)) + @as(f32, @floatFromInt(sl.slot.w)) / 2;
            return if (x < mid) i else i + 1;
        }
        return n;
    }

    /// Panel entries, top to bottom: one per app, in the order the apps
    /// first opened. Each is the app's icon with the number of its windows.
    fn groups(self: *const Compositor, out: []Group) usize {
        const self_m = @constCast(self);
        var n: usize = 0;
        // Every open window: tiled, full screen and minimized.
        var rep_t: [16]i64 = undefined;
        for ([_][]const Handle{ self.tiles.items, self.spaces.items, self.shelf.items }, 0..) |list, li| {
            for (list, 0..) |h, pos| {
                const g = self_m.windows.acquire(h) orelse continue;
                defer g.release();
                const w = g.ptr;
                const visible = li < 2;
                // Which window a click brings up: the most recently
                // minimized (the shelf is in minimize order); else the most
                // recently used window on screen.
                const score: i64 = if (visible) w.last_focus else std.math.maxInt(i32) * ms * 4 + @as(i64, @intCast(pos));
                var found = false;
                for (out[0..n], 0..) |*gr, gi| {
                    if (gr.app != w.app) continue;
                    found = true;
                    gr.count +|= 1;
                    if (visible) gr.visible +|= 1;
                    gr.first = @min(gr.first, w.seq);
                    if (score > rep_t[gi]) {
                        gr.rep = h;
                        rep_t[gi] = score;
                    }
                }
                if (!found and n < out.len and n < rep_t.len) {
                    out[n] = .{ .app = w.app, .rep = h, .count = 1, .visible = @intFromBool(visible), .first = w.seq, .rect = .{} };
                    rep_t[n] = score;
                    n += 1;
                }
            }
        }
        // Stable order: by when the app's first window opened.
        std.mem.sort(Group, out[0..n], {}, struct {
            fn lt(_: void, x: Group, y: Group) bool {
                return if (x.first != y.first) x.first < y.first else x.app < y.app;
            }
        }.lt);
        // Entries stop above the apps button, below the panel buttons.
        const limit = self.appsButtonRect().y - shell.panel_pad;
        var y: i32 = self.panelButtonRect(.close_all).bottom() + shell.panel_pad;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (y + panel_icon > limit) break;
            out[k].rect = .{ .x = @divTrunc(shell.panel_w - panel_icon, 2), .y = y, .w = panel_icon, .h = panel_icon };
            y += panel_icon + panel_icon_gap;
        }
        return k;
    }

    fn isLanded(self: *Compositor, h: Handle) bool {
        const g = self.windows.acquire(h) orelse return false;
        defer g.release();
        return g.ptr.fly_start < 0;
    }

    fn groupAt(self: *Compositor, x: f32, y: f32) ?Group {
        var buf: [12]Group = undefined;
        const n = self.groups(&buf);
        for (buf[0..n]) |gr| {
            if (gr.rect.contains(x, y)) return gr;
        }
        return null;
    }

    /// Panel entries: the app icon, and the room below it for the status
    /// line.
    const panel_icon = 52;
    const panel_icon_gap = 14;

    const PanelButton = enum { minimize_all, close_all };

    /// Minimize all and close all, side by side at the top of the panel.
    fn panelButtonRect(self: *const Compositor, which: PanelButton) Rect {
        const bw: i32 = 32;
        const gap: i32 = 6;
        const x0 = @divTrunc(self.panelW() - (2 * bw + gap), 2);
        return .{ .x = x0 + if (which == .close_all) bw + gap else 0, .y = shell.top_bar_h + 10, .w = bw, .h = 30 };
    }

    fn panelButtonAt(self: *const Compositor, x: f32, y: f32) ?PanelButton {
        for ([_]PanelButton{ .minimize_all, .close_all }) |b| {
            if (self.panelButtonRect(b).contains(x, y)) return b;
        }
        return null;
    }

    /// Every window on the desktop goes to the panel, flying and flashing.
    pub fn minimizeAll(self: *Compositor, now: i64) void {
        if (self.tiles.items.len == 0) return;
        self.maximized = null;
        self.pre_max.clearRetainingCapacity();
        while (self.tiles.items.len > 0) {
            const h = self.tiles.orderedRemove(0);
            self.shelveHandle(h, now);
        }
        self.focused = null;
        self.relayout(now, true);
    }

    /// Closes every window, each shrinking to nothing. Asks first: the
    /// first click arms the button for 3 s, the second closes.
    fn closeAllClick(self: *Compositor, now: i64) void {
        if (self.close_all_armed) |t| {
            if (now - t <= 3000 * ms) {
                self.close_all_armed = null;
                self.closeAll(now);
                return;
            }
        }
        self.close_all_armed = now;
    }

    pub fn closeAll(self: *Compositor, now: i64) void {
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| self.requestClose(h, now);
    }

    fn drawPanelButtons(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        if (self.close_all_armed) |t| {
            if (now - t > 3000 * ms) self.close_all_armed = null;
        }
        const armed = self.close_all_armed != null;
        const hover = self.panelButtonAt(self.px, self.py);
        for ([_]PanelButton{ .minimize_all, .close_all }) |b| {
            const r = self.panelButtonRect(b);
            const hot = hover != null and hover.? == b;
            const danger = b == .close_all and armed;
            const bg = if (danger) th.get(.danger) else if (hot) th.get(.accent).fade(0.18) else th.get(.surface_alt);
            cv.fillRoundRect(r, 7, bg);
            cv.strokeRoundRect(r, 7, 1, th.get(if (hot or danger) .accent else .border));
            const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
            const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
            const col = if (danger) core.Color.rgb(0xFFFFFF) else th.get(.text);
            if (b == .minimize_all) {
                // Two stacked bars: many windows down.
                cv.line(cx - 7, cy - 3, cx + 7, cy - 3, 1.8, col);
                cv.line(cx - 7, cy + 3, cx + 7, cy + 3, 1.8, col);
            } else {
                chrome.drawGlyph(cv, .close, cx - 2, cy - 2, 11, col);
                chrome.drawGlyph(cv, .close, cx + 3, cy + 3, 11, col.fade(0.6));
            }
        }
        // A label says what the hovered (or armed) button does.
        const label: ?[]const u8 = if (armed) "Click again to close all" else if (hover) |b| (if (b == .minimize_all) "Minimize all" else "Close all windows") else null;
        if (label) |l| {
            const r = self.panelButtonRect(.minimize_all);
            const m = tw.font.Metrics.of(.{ .size = .small }, cv.scale);
            const tr = Rect{ .x = r.x, .y = r.bottom() + 6, .w = @as(i32, @intFromFloat(m.width(l))) + 16, .h = 22 };
            cv.fillRoundRect(tr, 6, th.get(if (armed) .danger else .chrome_focused));
            cv.strokeRoundRect(tr, 6, 1, th.get(.border));
            _ = cv.text(@floatFromInt(tr.x + 8), @floatFromInt(tr.y + 3), l, .{ .size = .small }, if (armed) core.Color.rgb(0xFFFFFF) else th.get(.text));
        }
    }

    /// The thumbnail a window in the panel goes to: its app's group.
    fn panelRectOf(self: *const Compositor, h: Handle) ?Rect {
        const app = @constCast(self).appOf(h) orelse return null;
        var buf: [12]Group = undefined;
        const n = self.groups(&buf);
        for (buf[0..n]) |gr| {
            if (gr.app == app) return gr.thumb();
        }
        return null;
    }

    fn shelfAt(self: *Compositor, x: f32, y: f32) ?Handle {
        const gr = self.groupAt(x, y) orelse return null;
        return gr.rep;
    }

    /// The title bar's frame: the window frame, or for a full-screen window
    /// a bar at the top of the screen that slides down when revealed.
    fn chromeFrame(self: *const Compositor, w: *const Window, now: i64) Rect {
        if (!w.fullscreen) return currentFrame(w, now);
        const t = self.fs_bar.value(now);
        const y: i32 = @intFromFloat(@round(-@as(f32, chrome.title_h) * (1 - t)));
        return .{ .x = 0, .y = y, .w = self.screen.w, .h = chrome.title_h };
    }

    fn chromeState(self: *const Compositor, w: *const Window, now: i64) chrome.State {
        const focused = blk: {
            const f = self.focused orelse break :blk false;
            const g = self.windows.slots.items[f.index];
            break :blk g.value == w;
        };
        return .{
            .buttons_t = w.buttons_t.value(now),
            .aimed = w.aimed,
            .menu_t = w.menu_t.value(now),
            .focused = focused,
            .failed = w.status.kind == .failed,
            .maximized = blk: {
                const m = self.maximized orelse break :blk false;
                break :blk self.windows.slots.items[m.index].value == w;
            },
            .fullscreen = w.fullscreen,
        };
    }

    // ---------------------------------------------------------------- tick

    /// Advances animations, launches and clients. Returns true when a new
    /// frame is needed.
    pub fn tick(self: *Compositor, now: i64) bool {
        defer self.windows.endEvent();
        var need = self.full_redraw;

        // Reorder: once the pointer has rested on a tile, its window moves
        // aside into the dragged window's tile.
        switch (self.drag) {
            .title => |*d| if (d.moved and !sameHandle(d.want, d.partner)) {
                if (now - d.want_since >= reorder_dwell_ms * ms) self.previewSwap(d, d.want, now);
                need = true;
            },
            else => {},
        }

        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch {};
        var to_close: ?Handle = null;
        var relayout_needed = false;
        for (hs.items) |h| {
            var attach = false;
            {
                const g = self.windows.acquire(h) orelse continue;
                defer g.release();
                const w = g.ptr;
                if (w.surface == null and now >= w.ready_at) attach = true;
                if (w.surface) |s| {
                    if (s.tick(now)) w.dirty = true;
                    if (s.wantsClose()) to_close = h;
                    if (s.takeDialog()) |req| self.queueDialog(req, .{ .parent = h, .modal = req.modal });
                    const ws = self.stateOf(h, w);
                    if (@as(u8, @bitCast(ws)) != w.told_state) {
                        w.told_state = @bitCast(ws);
                        s.windowState(ws);
                    }
                    const st = s.status();
                    if (st.kind != w.status.kind or @abs(st.progress - w.status.progress) > 0.001) {
                        w.status = st;
                        self.publishWindowLocked(h, w, .changed);
                    }
                } else if (w.waiting and now - w.launch_start > wait_ms * ms) {
                    // No window came: the start failed.
                    w.waiting = false;
                    w.status = .{ .kind = .failed };
                    self.publishWindowLocked(h, w, .changed);
                } else if (w.ready_at != std.math.maxInt(i64) or w.waiting) {
                    // Launch progress: the expected time lands at 75%, then
                    // the bar creeps toward 100% ever more slowly.
                    const t: f32 = @floatFromInt(now - w.launch_start);
                    const e: f32 = @floatFromInt(@max(w.expected_ns, 1));
                    const p = if (t < e) 0.75 * t / e else 0.75 + 0.25 * (1 - @exp(-(t - e) / e));
                    w.status = .{ .kind = if (t > e * 1.5) .working else .progress, .progress = p };
                    need = true;
                }
                if (w.menu_rest_since) |t0| {
                    if (now - t0 >= 80 * ms) w.menu_t.set(1, now, 150);
                }
                if (w.menu_leave_since) |t0| {
                    if (now - t0 >= 300 * ms) {
                        w.menu_t.set(0, now, 150);
                        w.menu_leave_since = null;
                    }
                }
                if (!w.buttons_t.done(now) or !w.menu_t.done(now)) need = true;
                if (now - w.anim_start < anim_ms * ms) need = true;
                if (w.fly_start >= 0) {
                    if (now - w.fly_start < fly_ms * ms) need = true else w.fly_start = -1;
                }
                if (w.dirty) need = true;
                if (w.status.kind == .working) need = true;
            }
            if (attach) {
                self.attachSurface(h, now);
                relayout_needed = true;
                need = true;
            }
        }
        if (relayout_needed) self.relayout(now, true);
        if (to_close) |h| self.close(h, now);
        if (self.tickDialogs(now)) need = true;
        if (self.launcher.visible(now)) need = true;
        if (self.cue != null) need = true;
        if (self.ghosts.items.len > 0) need = true;
        if (self.close_all_armed) |t| {
            if (now - t > 3000 * ms) {
                self.close_all_armed = null;
                need = true;
            }
        }
        if (self.preview != null and !self.preview_t.done(now)) need = true;
        // The slow pulse keeps frames coming while it runs.
        if (self.previewPointed() != null) need = true;
        {
            var it_hs: std.ArrayList(Handle) = .empty;
            defer it_hs.deinit(self.gpa);
            self.windows.handles(&it_hs, self.gpa) catch {};
            for (it_hs.items) |h| {
                const g = self.windows.acquire(h) orelse continue;
                defer g.release();
                if (g.ptr.flash_start >= 0) need = true;
            }
        }
        if (self.space_start >= 0 and now - self.space_start < space_ms * ms) need = true;
        if (!self.fs_bar.done(now)) need = true;
        if (self.activeFs()) |h| {
            if (self.fsZooming(h, now)) need = true;
        }

        if (self.publisher.poll()) self.sendSnapshot();
        self.publisher.receive(self, onDeskRecord);
        self.refreshIcons();
        self.publisher.flush();
        self.windows.collect(null);
        return need;
    }

    // ------------------------------------------------------------- dialogs

    /// Opens a dialog (Top-Level Design, "Dialogs"). The compositor owns
    /// the surface from now on, and destroys it on failure.
    pub fn openDialog(self: *Compositor, s: Surface, opts: dlg.Options, now: i64) !u32 {
        errdefer s.destroy();
        self.dialog_seq += 1;
        var d: dlg.Dialog = .{ .id = self.dialog_seq, .surface = s, .opts = opts, .open_start = now };
        try self.sizeDialog(&d, dlg.fit(s.optimalSize(), self.workArea()));
        errdefer self.gpa.free(d.pixels);
        s.setDark(self.theme.dark);
        d.rect = self.dialogPlace(&d, now) orelse .{};
        try self.dialogs.append(self.gpa, d);
        self.dialog_focus = d.id;
        // A desktop dialog closes the top-bar menu that asked for it.
        if (opts.layer == .desktop) self.top_menu = .{};
        self.full_redraw = true;
        return d.id;
    }

    /// Opens one of Kuroko's own dialogs by name, modal over the desktop;
    /// when it is already open, it takes the keyboard instead.
    pub fn openDesktopDialog(self: *Compositor, name: []const u8, now: i64) void {
        const dd = self.desktop_dialogs orelse return;
        const s = dd.open(dd.ctx, name) orelse return;
        for (self.dialogs.items, 0..) |*d, i| {
            if (d.opts.layer == .desktop and !d.closing() and std.mem.eql(u8, d.surface.appId(), s.appId())) {
                s.destroy();
                self.dialog_focus = d.id;
                d.nudge_start = now;
                self.raiseDialog(i);
                return;
            }
        }
        _ = self.openDialog(s, .{ .modal = true, .layer = .desktop }, now) catch {};
    }

    /// The system state changed from outside (a desktop dialog applied
    /// a choice): draw again.
    pub fn systemChanged(self: *Compositor) void {
        self.full_redraw = true;
    }

    /// A dialog a surface asked for, opened at the next upkeep (not while
    /// the window list is being walked).
    fn queueDialog(self: *Compositor, req: Surface.DialogRequest, opts: dlg.Options) void {
        if (self.pending_dialogs_len == self.pending_dialogs.len) {
            req.surface.destroy();
            return;
        }
        self.pending_dialogs[self.pending_dialogs_len] = .{ .surface = req.surface, .opts = opts };
        self.pending_dialogs_len += 1;
    }

    fn sizeDialog(self: *Compositor, d: *dlg.Dialog, size: Size) !void {
        const bw = size.w * self.scale;
        const bh = size.h * self.scale;
        d.pixels = try self.gpa.realloc(d.pixels, @intCast(bw * bh));
        d.buf_w = bw;
        d.buf_h = bh;
        d.content = size;
        self.image_seq += 1;
        d.image_id = self.image_seq;
        d.version = 0;
        d.surface.configure(size, self.scale);
        d.dirty = true;
    }

    /// Where a dialog's content goes now, or null while its parent is not
    /// on screen (in the panel, in a full-screen space): it hides with it.
    fn dialogPlace(self: *Compositor, d: *const dlg.Dialog, now: i64) ?Rect {
        const area = self.workArea();
        const ph = d.opts.parent orelse return dlg.place(d.content, null, area);
        if (self.space != 0) return null;
        const g = self.windows.acquire(ph) orelse return null;
        defer g.release();
        const w = g.ptr;
        if (w.shelved or w.fullscreen or !w.placed) return null;
        return dlg.place(d.content, contentRect(currentFrame(w, now)), area);
    }

    fn dialogIndex(self: *const Compositor, id: u32) ?usize {
        for (self.dialogs.items, 0..) |d, i| {
            if (d.id == id) return i;
        }
        return null;
    }

    /// The dialog with the keyboard, if it is still open and shown.
    fn focusedDialog(self: *const Compositor) ?usize {
        const i = self.dialogIndex(self.dialog_focus orelse return null) orelse return null;
        const d = &self.dialogs.items[i];
        if (d.closing() or d.rect.w == 0) return null;
        return i;
    }

    /// The topmost dialog whose frame is at (x, y): desktop dialogs first.
    fn dialogAt(self: *const Compositor, x: f32, y: f32) ?usize {
        for ([_]dlg.Layer{ .desktop, .app }) |layer| {
            var i = self.dialogs.items.len;
            while (i > 0) {
                i -= 1;
                const d = &self.dialogs.items[i];
                if (d.opts.layer != layer or d.closing() or d.rect.w == 0) continue;
                if (d.rect.inset(-dlg.frame_pad).contains(x, y)) return i;
            }
        }
        return null;
    }

    /// The modal dialog in the way of the pointer at (x, y): a modal
    /// desktop dialog blocks everything; an app's blocks its parent.
    fn modalBlocking(self: *Compositor, x: f32, y: f32, now: i64) ?usize {
        var i = self.dialogs.items.len;
        while (i > 0) {
            i -= 1;
            const d = &self.dialogs.items[i];
            if (d.closing() or !d.opts.modal) continue;
            if (d.opts.layer == .desktop and d.opts.parent == null) return i;
            const ph = d.opts.parent orelse continue;
            if (d.rect.w == 0) continue;
            const g = self.windows.acquire(ph) orelse continue;
            defer g.release();
            if (currentFrame(g.ptr, now).contains(x, y)) return i;
        }
        return null;
    }

    /// Clicked: on top of its layer.
    fn raiseDialog(self: *Compositor, i: usize) void {
        if (i + 1 == self.dialogs.items.len) return;
        const d = self.dialogs.orderedRemove(i);
        self.dialogs.appendAssumeCapacity(d);
    }

    fn sendToDialog(self: *Compositor, i: usize, ev: Event, now: i64) void {
        const d = &self.dialogs.items[i];
        const ox: f32 = @floatFromInt(d.rect.x);
        const oy: f32 = @floatFromInt(d.rect.y);
        var local = ev;
        switch (local) {
            .pointer_motion => |*m| {
                m.x -= ox;
                m.y -= oy;
            },
            .pointer_button => |*b| {
                b.x -= ox;
                b.y -= oy;
            },
            else => {},
        }
        d.surface.input(local, now);
        d.dirty = true;
    }

    /// Pointer motion over a dialog, or held in one: true when the dialog
    /// took it. Leaving a dialog tells it so.
    fn dialogMotion(self: *Compositor, x: f32, y: f32, now: i64) bool {
        if (self.drag == .dialog) {
            if (self.dialogIndex(self.drag.dialog)) |i| self.sendToDialog(i, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
            return true;
        }
        const at = self.dialogAt(x, y);
        const id: ?u32 = if (at) |i| self.dialogs.items[i].id else null;
        if (self.dialog_hover) |old| {
            if (id != old) {
                if (self.dialogIndex(old)) |oi| self.sendToDialog(oi, .pointer_leave, now);
            }
        }
        self.dialog_hover = id;
        const i = at orelse return false;
        self.setContentHover(null, now);
        self.sendToDialog(i, .{ .pointer_motion = .{ .x = x, .y = y } }, now);
        self.cursor = self.dialogs.items[i].surface.cursor();
        self.full_redraw = true;
        return true;
    }

    fn beginCloseDialog(self: *Compositor, i: usize, now: i64) void {
        const d = &self.dialogs.items[i];
        if (d.closing()) return;
        d.close_start = now;
        if (self.dialog_focus == d.id) {
            self.dialog_focus = null;
            // The keyboard goes to the next dialog on top, if any.
            var k = self.dialogs.items.len;
            while (k > 0) {
                k -= 1;
                const o = &self.dialogs.items[k];
                if (k != i and !o.closing() and o.rect.w > 0) {
                    self.dialog_focus = o.id;
                    break;
                }
            }
        }
        self.full_redraw = true;
    }

    fn destroyDialog(self: *Compositor, i: usize) void {
        const d = self.dialogs.orderedRemove(i);
        d.surface.destroy();
        self.gpa.free(d.pixels);
        if (self.dialog_focus == d.id) self.dialog_focus = null;
        if (self.dialog_hover == d.id) self.dialog_hover = null;
        if (self.drag == .dialog and self.drag.dialog == d.id) self.drag = .none;
        self.full_redraw = true;
    }

    /// The window closes: its dialogs go with it, at once.
    fn closeDialogsOf(self: *Compositor, h: Handle) void {
        var i: usize = 0;
        while (i < self.dialogs.items.len) {
            const p = self.dialogs.items[i].opts.parent;
            if (p != null and p.?.eql(h)) self.destroyDialog(i) else i += 1;
        }
    }

    /// Each frame: dialogs asked for, the dialogs' own ticks, requests to
    /// close, parents that are gone, and where each one is now. True
    /// while one needs frames.
    fn tickDialogs(self: *Compositor, now: i64) bool {
        var need = false;
        var q: usize = 0;
        while (q < self.pending_dialogs_len) : (q += 1) {
            const p = self.pending_dialogs[q];
            _ = self.openDialog(p.surface, p.opts, now) catch {};
            need = true;
        }
        self.pending_dialogs_len = 0;
        var i: usize = 0;
        while (i < self.dialogs.items.len) {
            const d = &self.dialogs.items[i];
            const orphan = if (d.opts.parent) |ph| blk: {
                const g = self.windows.acquire(ph) orelse break :blk true;
                g.release();
                break :blk false;
            } else false;
            if (d.gone(now) or orphan) {
                self.destroyDialog(i);
                need = true;
                continue;
            }
            if (!d.closing()) {
                if (d.surface.tick(now)) d.dirty = true;
                if (d.surface.wantsClose()) self.beginCloseDialog(i, now);
                // A dialog's own dialog: over the same window, in its layer.
                if (d.surface.takeDialog()) |req| self.queueDialog(req, .{ .parent = d.opts.parent, .modal = req.modal, .layer = d.opts.layer });
            }
            d.rect = self.dialogPlace(d, now) orelse .{};
            if (d.dirty or d.animating(now)) need = true;
            i += 1;
        }
        return need;
    }

    /// One layer of dialogs, each in a rounded frame with a shadow; a
    /// modal one dims what it blocks.
    fn drawDialogs(self: *Compositor, cv: *Canvas, layer: dlg.Layer, now: i64) void {
        const th = &self.theme;
        for (self.dialogs.items) |*d| {
            if (d.opts.layer != layer) continue;
            d.rect = self.dialogPlace(d, now) orelse .{};
            if (d.rect.w == 0) continue;
            const look = d.look(now);
            if (d.opts.modal) {
                const dim = th.get(.shadow).withAlpha(@intFromFloat(90 * look.alpha));
                if (d.opts.parent) |ph| {
                    if (self.windows.acquire(ph)) |g| {
                        defer g.release();
                        cv.fillRect(currentFrame(g.ptr, now), dim);
                    }
                } else cv.fillRect(self.screenRect(), dim);
            }
            d.paint(self.scale);
            const r = scaleAround(d.rect, look.k);
            const frame = r.inset(-dlg.frame_pad);
            cv.fillRoundRect(frame.translate(0, 8), dlg.frame_radius + 2, th.get(.shadow).fade(look.alpha));
            cv.fillRoundRect(frame, dlg.frame_radius, th.get(.surface).fade(look.alpha));
            if (look.k == 1 and look.alpha >= 1) {
                cv.blit(d.image(), r.x * self.scale, r.y * self.scale);
            } else {
                cv.blitScaled(d.image(), r, @intFromFloat(255 * look.alpha));
            }
            cv.strokeRoundRect(frame, dlg.frame_radius, 1, th.get(.border).fade(look.alpha));
        }
    }

    fn scaleAround(r: Rect, k: f32) Rect {
        if (k == 1) return r;
        const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.w)) * k));
        const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.h)) * k));
        return .{ .x = r.x + @divTrunc(r.w - w, 2), .y = r.y + @divTrunc(r.h - h, 2), .w = w, .h = h };
    }

    // -------------------------------------------------------------- render

    pub fn render(self: *Compositor, cv: *Canvas, now: i64) void {
        defer self.windows.endEvent();
        self.full_redraw = false;
        self.holdOverStall(now);
        const sliding = self.space_start >= 0 and now - self.space_start < space_ms * ms;
        const fs = self.activeFs();
        const zooming = if (fs) |h| self.fsZooming(h, now) else false;

        // The desktop is drawn unless a full-screen window covers it all.
        if (fs == null or sliding or zooming) self.drawDesktop(cv, now);

        if (sliding) {
            // Spaces sit side by side; the screen slides to the new one.
            const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(now - self.space_start)) / @as(f32, @floatFromInt(space_ms * ms)));
            const w: f32 = @floatFromInt(self.screen.w);
            const dir: f32 = if (self.space > self.space_from) 1 else -1;
            const off_from: i32 = @intFromFloat(@round(-dir * t * w));
            const off_to: i32 = @intFromFloat(@round(dir * (1 - t) * w));
            if (self.space_from > 0 and self.space_from <= self.spaces.items.len)
                self.drawFsWindow(cv, self.spaces.items[self.space_from - 1], self.screenRect().translate(off_from, 0), now);
            if (fs) |h| self.drawFsWindow(cv, h, self.screenRect().translate(off_to, 0), now);
        } else if (fs) |h| {
            if (zooming) {
                const g = self.windows.acquire(h).?;
                const from = g.ptr.fs_from;
                const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(now - g.ptr.fs_start)) / @as(f32, @floatFromInt(space_ms * ms)));
                g.release();
                self.drawFsWindow(cv, h, RectF.lerp(from, RectF.from(self.screenRect()), t).round(), now);
            } else {
                self.drawFsWindow(cv, h, self.screenRect(), now);
                // The title bar, when revealed.
                const g = self.windows.acquire(h).?;
                defer g.release();
                if (self.fs_bar.value(now) > 0.01) {
                    const title = if (g.ptr.surface) |s| s.title() else self.appName(g.ptr.app);
                    const menu = if (g.ptr.surface) |s| s.menu() else &[_][]const u8{};
                    const frame = self.chromeFrame(g.ptr, now);
                    cv.fillRect(frame.translate(0, 3), self.theme.get(.shadow));
                    chrome.drawTitleBar(cv, &self.theme, frame, self.chromeState(g.ptr, now), title, self.appName(g.ptr.app), self.appIcon(g.ptr.app), menu);
                    self.drawSpaceDots(cv, true, now);
                }
            }
        }
        self.drawGhosts(cv, now);
        self.drawCue(cv, now);
        self.drawChooser(cv);
        self.updateRunning();
        self.launcher.draw(cv, &self.theme, self.app_infos.items, now);
        self.drawDialogs(cv, .desktop, now);
    }

    /// A slow frame (apps redrawing at a new size, many pixels on a HiDPI
    /// screen) must not eat the animations: the ones that were running at
    /// the previous frame are held for the stall, so they play from where
    /// they were instead of jumping to the end. What counts as a stall is
    /// relative to the machine's usual frame pace (FramePace), so a slower
    /// machine still animates in real time, with fewer frames. Animations
    /// that started after the previous frame (by the input that ended an
    /// idle pause) are never held.
    fn holdOverStall(self: *Compositor, now: i64) void {
        const stall = self.pace.frame(now) orelse return;
        const since = stall.since;
        const shift = stall.shift;
        const hold = struct {
            fn f(start: *i64, now_: i64, dur: i64, since_: i64, sh: i64) void {
                if (start.* >= 0 and start.* <= since_ and now_ - start.* < dur + sh) start.* += sh;
            }
        }.f;
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            if (w.placed) hold(&w.anim_start, now, anim_ms * ms, since, shift);
            hold(&w.fly_start, now, fly_ms * ms, since, shift);
            hold(&w.fs_start, now, space_ms * ms, since, shift);
            hold(&w.flash_start, now, flash_ms * ms, since, shift);
        }
        if (self.cue) |*c| hold(&c.start, now, cue_ms * ms, since, shift);
        for (self.ghosts.items) |*gh| hold(&gh.start, now, fly_ms * ms, since, shift);
        hold(&self.space_start, now, space_ms * ms, since, shift);
    }

    fn fsZooming(self: *Compositor, h: Handle, now: i64) bool {
        const g = self.windows.acquire(h) orelse return false;
        defer g.release();
        return g.ptr.fs_start >= 0 and now - g.ptr.fs_start < space_ms * ms;
    }

    fn drawDesktop(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        // Desktop background: a calm vertical gradient.
        const bg = th.get(.background);
        const h = self.screen.h;
        var y: i32 = 0;
        while (y < h) : (y += 8) {
            const t: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
            cv.fillRect(.{ .x = 0, .y = y, .w = self.screen.w, .h = 8 }, bg.mix(th.get(.accent), 0.04 + 0.06 * t));
        }

        self.drawDividers(cv, false);
        const lifted = self.reordering();
        for (self.visibleTiles()) |wh| {
            if (!sameHandle(lifted, wh)) self.drawWindow(cv, wh, now);
        }
        self.drawDividers(cv, true);
        self.drawDialogs(cv, .app, now);
        self.drawShelf(cv, now);
        self.drawFlying(cv, now);
        self.drawPointedPulse(cv, now);
        self.drawPreview(cv, now);
        self.drawPanelMenu(cv);
        self.drawDragFeedback(cv, now);

        const hint = "Apps or Super: launcher   +X close   +Z minimize   +Enter maximize   +F full screen   +\u{2190}/\u{2192} spaces";
        const hover = if (self.drag == .none) shell.topBarHit(self.screen.w, self.px, self.py) else .none;
        shell.drawTopBar(cv, th, self.screen.w, self.clock[0..self.clock_len], self.learning, self.system.layoutCode(), hint, hover, self.launcher.open, self.top_menu.from);
        self.drawSpaceDots(cv, false, now);
        self.top_menu.draw(cv, th, self.screen.w, &self.system, .{ self.theme.dark, self.learning, self.params.wheel_natural, self.params.touchpad_natural }, self.px, self.py);
    }

    /// A full-screen window: its content fills `r` (the screen, or a
    /// moving rect while zooming or sliding). No chrome.
    fn drawFsWindow(self: *Compositor, cv: *Canvas, h: Handle, r: Rect, _: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        w.paint(self.scale);
        cv.fillRect(r, self.theme.get(.surface));
        if (w.pixels.len == 0) return;
        if (r.w == w.content.w and r.h == w.content.h) {
            cv.blit(w.image(), r.x * self.scale, r.y * self.scale);
        } else {
            cv.blitScaled(w.image(), r, 255);
        }
    }

    fn drawWindow(self: *Compositor, cv: *Canvas, h: Handle, now: i64) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        const w = g.ptr;
        const th = &self.theme;
        const frame = currentFrame(w, now);
        const content = contentRect(frame);
        const app_name = self.appName(w.app);

        if (w.surface != null) {
            w.paint(self.scale);
            const old = cv.pushClip(content);
            cv.blit(w.image(), content.x * self.scale, content.y * self.scale);
            cv.popClip(old);
        } else {
            // Launch placeholder: icon and name on the theme background.
            cv.fillRect(content, th.get(.surface));
            const fade = std.math.clamp(@as(f32, @floatFromInt(now - w.launch_start)) / @as(f32, @floatFromInt(200 * ms)), 0, 1);
            const icon = Rect{ .x = content.x + @divTrunc(content.w - 64, 2), .y = content.y + @divTrunc(content.h, 2) - 60, .w = 64, .h = 64 };
            chrome.drawAppIcon(cv, th, icon, app_name, .title, self.appIcon(w.app));
            if (fade < 1) cv.fillRect(icon.inset(-2), th.get(.surface).fade(1 - fade));
            const m = tw.font.Metrics.of(.{ .size = .large }, self.scale);
            _ = cv.text(@as(f32, @floatFromInt(content.x)) + (@as(f32, @floatFromInt(content.w)) - m.width(app_name)) / 2, @floatFromInt(icon.bottom() + 14), app_name, .{ .size = .large }, th.get(.text_dim).fade(fade));
        }

        const title = if (w.surface) |s| s.title() else app_name;
        const menu = if (w.surface) |s| s.menu() else &[_][]const u8{};
        chrome.drawTitleBar(cv, th, frame, self.chromeState(w, now), title, app_name, self.appIcon(w.app), menu);
        chrome.drawBorders(cv, th, frame, w.status, now);
    }

    /// Shared borders. The line is drawn under the windows, so it shows in
    /// the gaps between them; the grip is drawn on top. Both brighten when
    /// the pointer is over the border or it is being dragged.
    fn drawDividers(self: *Compositor, cv: *Canvas, grips: bool) void {
        const th = &self.theme;
        var buf: [3]Divider = undefined;
        const n = self.dividers(&buf);
        const hovered = self.dividerAt(self.px, self.py);
        for (buf[0..n]) |d| {
            const active = switch (self.drag) {
                .col_border => |c| d.vertical and c.row == d.row,
                .row_border => !d.vertical,
                else => if (hovered) |h| h.vertical == d.vertical and h.row == d.row and h.boundary == d.boundary else false,
            };
            const line = if (active) th.get(.accent) else th.get(.hairline);
            const grip_col = if (active) th.get(.accent) else th.get(.text_dim).fade(0.55);
            if (d.vertical) {
                const mid = @divTrunc(d.from + d.to, 2);
                if (!grips) {
                    cv.fillRect(.{ .x = d.boundary, .y = d.from, .w = 1, .h = d.to - d.from }, line);
                } else {
                    const gw: i32 = if (active) 6 else 4;
                    const gh: i32 = if (active) 64 else 44;
                    cv.fillRoundRect(.{ .x = d.boundary - @divTrunc(gw, 2), .y = mid - @divTrunc(gh, 2), .w = gw, .h = gh }, @as(f32, @floatFromInt(gw)) / 2, grip_col);
                }
            } else {
                const mid = @divTrunc(d.from + d.to, 2);
                if (!grips) {
                    cv.fillRect(.{ .x = d.from, .y = d.boundary, .w = d.to - d.from, .h = 1 }, line);
                } else {
                    const gw: i32 = if (active) 64 else 44;
                    const gh: i32 = if (active) 6 else 4;
                    cv.fillRoundRect(.{ .x = mid - @divTrunc(gw, 2), .y = d.boundary - @divTrunc(gh, 2), .w = gw, .h = gh }, @as(f32, @floatFromInt(gh)) / 2, grip_col);
                }
            }
        }
    }

    /// The panel on the left: one icon per open app, with the number of its
    /// windows. A window that was just minimized flies into its app's icon.
    fn drawShelf(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        const strip = Rect{ .x = 0, .y = shell.top_bar_h, .w = self.panelW(), .h = self.screen.h - shell.top_bar_h };
        cv.fillRect(strip, th.get(.chrome).fade(0.92));
        cv.hairlineVRight(strip.right() - 1, strip.y, strip.h, th.get(.hairline));
        const ab = self.appsButtonRect();
        shell.drawAppsIcon(cv, th, ab, ab.contains(self.px, self.py), self.launcher.open);
        defer self.drawPanelButtons(cv, now);
        var gbuf: [12]Group = undefined;
        const n = self.groups(&gbuf);
        for (gbuf[0..n]) |gr| {
            const r = gr.rect;
            const g = self.windows.acquire(gr.rep) orelse continue;
            defer g.release();
            const w = g.ptr;
            const thumb = gr.thumb();
            if (gr.count == 1 and w.fly_start >= 0 and now - w.fly_start < fly_ms * ms) {
                // The app's only window is still flying in: drawn by
                // drawFlying, on top of everything; the icon follows.
                continue;
            }
            const hovered = r.contains(self.px, self.py);
            const radius = @as(f32, @floatFromInt(panel_icon)) * 0.24;
            if (hovered) cv.fillRoundRect(thumb.inset(-4), radius + 4, th.get(.accent).fade(0.16));
            chrome.drawAppIcon(cv, th, thumb, self.appName(w.app), .title, self.appIcon(w.app));
            // Only minimized windows: the icon is dimmed.
            if (gr.visible == 0) cv.fillRoundRect(thumb, radius, th.get(.chrome).fade(0.45));
            // A window on screen: a bar at the panel's edge (shape, not
            // only color).
            if (gr.visible > 0) cv.fillRoundRect(.{ .x = 0, .y = thumb.y + 8, .w = 3, .h = thumb.h - 16 }, 1.5, th.get(.accent));
            if (hovered) cv.strokeRoundRect(thumb.inset(-4), radius + 4, 2, th.get(.accent));
            // The flash when a window of the app has just landed here.
            const flash_at: i64 = blk: {
                var best: i64 = -1;
                var hs: [8]Handle = undefined;
                const nw = self.windowsOf(gr.app, &hs);
                for (hs[0..nw]) |x| {
                    if (!self.isShelved(x)) continue;
                    const gx = self.windows.acquire(x) orelse continue;
                    defer gx.release();
                    const fs = gx.ptr.flash_start;
                    if (fs >= 0 and now >= fs and now - fs < flash_ms * ms) best = @max(best, fs);
                }
                break :blk best;
            };
            if (flash_at >= 0) {
                const f = @sin(std.math.pi * @as(f32, @floatFromInt(now - flash_at)) / @as(f32, @floatFromInt(flash_ms * ms)));
                cv.fillRoundRect(thumb, radius, th.get(.accent).fade(0.22 * f));
                cv.strokeRoundRect(thumb.inset(-2), radius + 2, 3, th.get(.accent).fade(f));
            }
            // Status keeps working: its line runs under the icon.
            if (w.status.kind != .normal) chrome.drawBorders(cv, th, .{ .x = thumb.x, .y = thumb.bottom() + 4 - chrome.title_h, .w = thumb.w, .h = chrome.title_h + chrome.status_h }, w.status, now);
            // Several windows of the app: their number at the top-right.
            if (gr.count > 1) {
                const bx: f32 = @floatFromInt(thumb.right() - 2);
                const by: f32 = @floatFromInt(thumb.y + 2);
                // Red, with a larger number.
                cv.fillCircle(bx, by, 14, th.get(.chrome));
                cv.fillCircle(bx, by, 12.5, th.get(.danger));
                var nb: [4]u8 = undefined;
                const txt = std.fmt.bufPrint(&nb, "{d}", .{gr.count}) catch "+";
                const style: tw.font.Style = .{ .size = .large, .weight = .semibold };
                const m = tw.font.Metrics.of(style, cv.scale);
                _ = cv.text(bx - m.width(txt) / 2, by - @as(f32, @floatFromInt(m.lineHeight())) / 2, txt, style, core.Color.rgb(0xFFFFFF));
            }
        }
    }

    /// Windows on their way into the panel: their content, scaled, moving
    /// from where they were to their thumbnail.
    fn drawFlying(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        for (self.shelf.items) |h| {
            const thumb = self.panelRectOf(h) orelse continue;
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            const w = g.ptr;
            if (w.fly_start < 0 or now - w.fly_start >= fly_ms * ms) continue;
            const t = core.anim.easeOutCubic(@as(f32, @floatFromInt(now - w.fly_start)) / @as(f32, @floatFromInt(fly_ms * ms)));
            const to = RectF.from(thumb);
            const cur = RectF.lerp(w.fly_from, to, t).round();
            cv.fillRect(cur.translate(0, 4), th.get(.shadow));
            cv.fillRect(cur, th.get(.surface));
            blitCover(cv, w, cur);
            cv.hairlineRect(cur, th.get(.border));
        }
    }

    fn drawDragFeedback(self: *Compositor, cv: *Canvas, now: i64) void {
        const th = &self.theme;
        switch (self.drag) {
            .title => |d| {
                if (!d.moved) return;
                // While dragging, every tile is outlined. The tile the
                // pointer rests on brightens until its window moves aside.
                const vis = self.visibleTiles();
                for (self.slots[0..@min(self.slot_count, vis.len)], vis[0..@min(self.slot_count, vis.len)]) |sl, vh| {
                    if (vh.eql(d.h)) continue;
                    const pending = sameHandle(d.want, vh) and !sameHandle(d.partner, vh);
                    cv.strokeRoundRect(sl.slot.inset(4), 10, if (pending) 3 else 1.5, th.get(.accent).fade(if (pending) 0.8 else 0.45));
                }
                const g = self.windows.acquire(d.h) orelse return;
                defer g.release();
                // Where the window will land: a placeholder in its tile,
                // moving with the layout, with the window's title on it.
                const r = currentFrame(g.ptr, now);
                cv.fillRoundRect(r, 10, th.get(.accent).fade(0.14));
                cv.strokeRoundRect(r, 10, 3, th.get(.accent));
                const title = if (g.ptr.surface) |s| s.title() else self.appName(g.ptr.app);
                const m = tw.font.Metrics.of(.{ .size = .large }, self.scale);
                const tw_ = @min(m.width(title), @as(f32, @floatFromInt(@max(0, r.w - 32))));
                _ = cv.textEllipsis(@as(f32, @floatFromInt(r.x)) + (@as(f32, @floatFromInt(r.w)) - tw_) / 2, @as(f32, @floatFromInt(r.y + @divTrunc(r.h, 2) - 12)), title, tw_, .{ .size = .large }, th.get(.text_dim));
                self.drawDragThumb(cv, g.ptr);
            },
            .panel => |d| {
                if (!d.moved or self.px < @as(f32, @floatFromInt(self.panelW()))) return;
                // Where it will go: the half of the tile under the pointer
                // it will take, with a bar on the edge it joins at.
                const n = @min(self.slot_count, self.tiles.items.len);
                for (self.slots[0..n]) |sl| {
                    if (!sl.slot.contains(self.px, self.py)) continue;
                    const left = self.px < @as(f32, @floatFromInt(sl.slot.x)) + @as(f32, @floatFromInt(sl.slot.w)) / 2;
                    const half = Rect{ .x = if (left) sl.slot.x else sl.slot.x + @divTrunc(sl.slot.w, 2), .y = sl.slot.y, .w = @divTrunc(sl.slot.w, 2), .h = sl.slot.h };
                    cv.fillRoundRect(half.inset(6), 10, th.get(.accent).fade(0.14));
                    cv.strokeRoundRect(half.inset(6), 10, 2, th.get(.accent).fade(0.8));
                    const ex = if (left) sl.slot.x + 2 else sl.slot.right() - 6;
                    cv.fillRect(.{ .x = ex, .y = sl.slot.y + 8, .w = 4, .h = sl.slot.h - 16 }, th.get(.accent));
                }
                // The window itself, as a small thumbnail under the pointer.
                const g = self.windows.acquire(d.h) orelse return;
                defer g.release();
                self.drawDragThumb(cv, g.ptr);
            },
            .col_border, .row_border => {},
            else => {},
        }
    }

    // ----------------------------------------------------------- publishing

    fn publishWindow(self: *Compositor, h: Handle, kind: core.types.SceneKind) void {
        const g = self.windows.acquire(h) orelse return;
        defer g.release();
        self.publishWindowLocked(h, g.ptr, kind);
    }

    fn sceneRecord(self: *Compositor, out: *std.ArrayList(u8), h: Handle, w: *const Window, kind: core.types.SceneKind) void {
        const title = if (w.surface) |s| s.title() else self.appName(w.app);
        const app_id = if (w.surface) |s| s.appId() else self.appIdOf(w.app);
        var trail: [512]u8 = undefined;
        const tl = @min(title.len, 256);
        const al = @min(app_id.len, 256);
        @memcpy(trail[0..tl], title[0..tl]);
        @memcpy(trail[tl..][0..al], app_id[0..al]);
        const focused = if (self.focused) |f| f.eql(h) else false;
        core.format.appendStruct(self.gpa, out, core.types.scene_window, 1, core.types.SceneWindow{
            .kind = kind,
            .status = w.status.kind,
            .focused = @intFromBool(focused),
            .shelved = @intFromBool(w.shelved),
            .window_id = h.toId(),
            .x = w.target.x,
            .y = w.target.y,
            .w = w.target.w,
            .h = w.target.h,
            .progress = w.status.progress,
            .title_len = @intCast(tl),
            .app_id_len = @intCast(al),
        }, trail[0 .. tl + al]) catch {};
    }

    /// Who a window belongs to and its trust (SceneIdentity).
    fn identityRecord(self: *Compositor, out: *std.ArrayList(u8), h: Handle, w: *const Window) void {
        core.format.appendStruct(self.gpa, out, core.types.scene_identity, 1, core.types.SceneIdentity{
            .window_id = h.toId(),
            .pid = w.pid,
            .trust = w.trust,
            .app_trust = w.app_trust,
            .exe_len = @intCast(w.exe.len),
        }, w.exe) catch {};
    }

    fn publishWindowLocked(self: *Compositor, h: Handle, w: *Window, kind: core.types.SceneKind) void {
        // A new window's trust is decided as it opens.
        if (kind == .opened) _ = self.decideTrust(w);
        if (self.publisher.subscriberCount() == 0) return;
        self.scratch.clearRetainingCapacity();
        if (kind == .opened) self.identityRecord(&self.scratch, h, w);
        self.sceneRecord(&self.scratch, h, w, kind);
        self.publisher.broadcast(self.scratch.items);
    }

    fn sendSnapshot(self: *Compositor) void {
        self.scratch.clearRetainingCapacity();
        const marker = core.types.SceneWindow{ .kind = .snapshot_begin, .status = .normal, .focused = 0, .shelved = 0, .window_id = 0, .x = 0, .y = 0, .w = 0, .h = 0, .progress = 0, .title_len = 0, .app_id_len = 0 };
        core.format.appendStruct(self.gpa, &self.scratch, core.types.scene_window, 1, marker, "") catch return;
        self.sessionRecord(&self.scratch);
        var hs: std.ArrayList(Handle) = .empty;
        defer hs.deinit(self.gpa);
        self.windows.handles(&hs, self.gpa) catch return;
        for (hs.items) |h| {
            const g = self.windows.acquire(h) orelse continue;
            defer g.release();
            self.identityRecord(&self.scratch, h, g.ptr);
            self.sceneRecord(&self.scratch, h, g.ptr, .opened);
        }
        var end = marker;
        end.kind = .snapshot_end;
        core.format.appendStruct(self.gpa, &self.scratch, core.types.scene_window, 1, end, "") catch return;
        self.publisher.sendSnapshot(self.scratch.items);
    }
};

/// Frame pacing: learns the usual time between frames while the screen is
/// being drawn continuously, and reports a frame that came much later than
/// that (a stall). A fast machine draws every 16 ms; a slow one (a VM, a
/// software renderer) may draw every 50 ms, and that is its pace, not a
/// stall. Gaps longer than `idle_gap` are idle time (nothing to draw) and
/// do not change the pace.
pub const FramePace = struct {
    /// Time of the previous frame, or -1 before the first.
    last: i64 = -1,
    /// Usual time between frames.
    usual: i64 = 16 * ms,

    pub const idle_gap = 100 * ms;
    /// A frame is a stall when it is over 40 ms and over 2.5x the usual gap.
    pub const min_stall = 40 * ms;

    pub const Stall = struct {
        /// Time of the frame before the stall: animations running then
        /// are the ones to hold.
        since: i64,
        /// How long to hold them.
        shift: i64,
    };

    pub fn frame(self: *FramePace, now: i64) ?Stall {
        defer self.last = now;
        if (self.last < 0) return null;
        const gap = now - self.last;
        const usual = self.usual;
        if (gap <= idle_gap) self.usual += @divTrunc(gap - self.usual, 8);
        if (gap <= min_stall or gap * 2 <= usual * 5) return null;
        return .{ .since = self.last, .shift = gap - usual };
    }
};

test "FramePace: steady 60 Hz has no stalls" {
    var p: FramePace = .{};
    var t: i64 = 0;
    for (0..120) |_| {
        try std.testing.expect(p.frame(t) == null);
        t += 16 * ms;
    }
}

test "FramePace: one slow frame at 60 Hz is a stall" {
    var p: FramePace = .{};
    var t: i64 = 0;
    for (0..60) |_| {
        _ = p.frame(t);
        t += 16 * ms;
    }
    const before = t - 16 * ms;
    t += 104 * ms; // this frame comes 120 ms after the previous one
    const s = p.frame(t) orelse return error.NoStall;
    try std.testing.expectEqual(before, s.since);
    try std.testing.expect(s.shift > 100 * ms and s.shift < 106 * ms);
}

test "FramePace: a slow machine's steady pace stops counting as stalls" {
    var p: FramePace = .{};
    var t: i64 = 0;
    var stalls: usize = 0;
    for (0..60) |i| {
        if (p.frame(t) != null) {
            stalls += 1;
            try std.testing.expect(i < 6); // only while it learns the pace
        }
        t += 60 * ms;
    }
    try std.testing.expect(p.usual > 55 * ms and p.usual <= 60 * ms);
    try std.testing.expect(stalls <= 5);
}

test "FramePace: an idle pause does not change the pace" {
    var p: FramePace = .{};
    var t: i64 = 0;
    for (0..60) |_| {
        _ = p.frame(t);
        t += 16 * ms;
    }
    const usual = p.usual;
    t += 3000 * ms;
    const s = p.frame(t) orelse return error.NoStall;
    try std.testing.expectEqual(usual, p.usual);
    // Only animations already running before the pause are held; one that
    // starts with the input that ended the pause (after `since`) is not.
    try std.testing.expect(t - 1 * ms > s.since);
}
