//! txsim: the simulator backend. Runs the real compositor core in one SDL3
//! window on macOS (or any desktop), so the compositor, desktop and widgets
//! can be developed before the Linux VM and wlroots backend exist.
//!
//! The backend stays thin: it only translates SDL events into Tesselix
//! input events and shows the canvas the core draws. All behavior lives in
//! txcomp and txwidgets, so it is the same code that will run on Linux.
//!
//!   zig build run                    clean desktop; Controls, Scroll Lab
//!                                    and Notes start minimized in the panel
//!   zig build run -- --tiled         all five apps open on the desktop
//!   zig build run -- --empty         nothing started
//!   zig build run -- --dark          dark theme
//!   zig build run -- --size 1280x800
//!
//! Development only: --snapshot FILE.ppm --script NAME renders a scripted
//! sequence and writes the final frame (used to check the UI headless).

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const txcomp = @import("txcomp");
const controls = @import("controls");

const c = @import("sdl.zig");

const ms = std.time.ns_per_ms;

// SIGINT and SIGTERM (Ctrl+C, `pkill txsim`) end the run cleanly: the loop
// stops, the timing summary is printed, and the process exits.
var quit_signal = std.atomic.Value(bool).init(false);
fn onQuitSignal(_: c_int) callconv(.c) void {
    quit_signal.store(true, .monotonic);
}
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*const anyopaque;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

const apps = [_]txcomp.AppEntry{
    .{ .name = "Controls", .app_id = "org.tesselix.controls", .start_ms = 300, .create = controls.createControls },
    .{ .name = "Scroll Lab", .app_id = "org.tesselix.scroll-lab", .start_ms = 1200, .create = controls.createScrollLab },
    .{ .name = "Stopwatch", .app_id = "org.tesselix.stopwatch", .start_ms = 150, .create = controls.createStopwatch },
    .{ .name = "Notes", .app_id = "org.tesselix.notes", .start_ms = 400, .create = controls.createNotes },
    .{ .name = "Reader", .app_id = "org.tesselix.reader", .start_ms = 600, .create = controls.createReader },
};

const Options = struct {
    dark: bool = false,
    empty: bool = false,
    /// All five apps open on the desktop (the old start).
    tiled: bool = false,
    w: i32 = 1440,
    h: i32 = 900,
    snapshot: ?[]const u8 = null,
    size_given: bool = false,
    /// The whole screen (the Ubuntu VM, with SDL's KMS/DRM driver).
    fullscreen: bool = false,
    script: []const u8 = "default",
};

fn parseArgs(args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--fullscreen")) o.fullscreen = true else if (std.mem.eql(u8, a, "--dark")) o.dark = true else if (std.mem.eql(u8, a, "--empty")) o.empty = true else if (std.mem.eql(u8, a, "--tiled")) o.tiled = true else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], 'x');
            o.w = try std.fmt.parseInt(i32, it.next() orelse "1440", 10);
            o.h = try std.fmt.parseInt(i32, it.next() orelse "900", 10);
            o.size_given = true;
        } else if (std.mem.eql(u8, a, "--snapshot") and i + 1 < args.len) {
            i += 1;
            o.snapshot = args[i];
        } else if (std.mem.eql(u8, a, "--script") and i + 1 < args.len) {
            i += 1;
            o.script = args[i];
        } else {
            std.debug.print("unknown option: {s}\n", .{a});
            return error.BadArgs;
        }
    }
    return o;
}

fn mapKey(sym: u32) core.input.Key {
    return switch (sym) {
        c.K_ESCAPE => .escape,
        c.K_RETURN, c.K_KP_ENTER => .enter,
        c.K_TAB => .tab,
        c.K_BACKSPACE => .backspace,
        c.K_DELETE => .delete,
        c.K_LEFT => .left,
        c.K_RIGHT => .right,
        c.K_UP => .up,
        c.K_DOWN => .down,
        // On a Mac keyboard, Fn+← / Fn+→ arrive as Home / End.
        c.K_HOME => .home,
        c.K_END => .end,
        c.K_PAGEUP => .page_up,
        c.K_PAGEDOWN => .page_down,
        c.K_SPACE => .space,
        c.K_LGUI, c.K_RGUI => .super,
        c.K_F5 => .f5,
        c.K_F12 => .f12,
        c.K_A => .a,
        c.K_C => .c,
        c.K_F => .f,
        c.K_Q => .q,
        c.K_V => .v,
        c.K_W => .w,
        c.K_X => .x,
        c.K_Z => .z,
        else => .unknown,
    };
}

fn mods() core.input.Mods {
    const m = c.SDL_GetModState();
    return .{
        .shift = (m & c.KMOD_SHIFT) != 0,
        .ctrl = (m & c.KMOD_CTRL) != 0,
        .alt = (m & c.KMOD_ALT) != 0,
        .super = (m & c.KMOD_GUI) != 0,
    };
}

/// Translates one SDL event. Returns null for events the core ignores.
/// SDL3 reports pointer positions in window points, which are Tesselix's
/// logical pixels.
fn translate(ev: *const c.Event) ?core.input.Event {
    switch (ev.type) {
        c.EVENT_MOUSE_MOTION => return .{ .pointer_motion = .{ .x = ev.motion.x, .y = ev.motion.y } },
        c.EVENT_MOUSE_BUTTON_DOWN, c.EVENT_MOUSE_BUTTON_UP => {
            const b: core.input.Button = switch (ev.button.button) {
                c.BUTTON_LEFT => .left,
                c.BUTTON_RIGHT => .right,
                else => .middle,
            };
            return .{ .pointer_button = .{ .button = b, .pressed = ev.button.down, .x = ev.button.x, .y = ev.button.y, .mods = mods() } };
        },
        c.EVENT_MOUSE_WHEEL => {
            // Remove the host's direction flip; positive = away from the
            // user. Tesselix's forward direction is toward the user.
            const flip: f32 = if (ev.wheel.direction == c.MOUSEWHEEL_FLIPPED) -1 else 1;
            const y = ev.wheel.y * flip;
            const x = ev.wheel.x * flip;
            // Fractional deltas come from touchpads and smooth wheels
            // (approximate: macOS gives no device type here).
            const fractional = @abs(y - @round(y)) > 0.01 or @abs(x - @round(x)) > 0.01;
            if (fractional) {
                return .{ .wheel = .{ .dx = -x * 10, .dy = -y * 10, .source = .touchpad, .mods = mods() } };
            }
            return .{ .wheel = .{ .dx = -x, .dy = -y, .source = .wheel, .mods = mods() } };
        },
        c.EVENT_KEY_DOWN, c.EVENT_KEY_UP => {
            const k = mapKey(ev.key.key);
            if (k == .unknown) return null;
            return .{ .key = .{ .key = k, .pressed = ev.key.down, .mods = mods(), .repeat = ev.key.repeat } };
        },
        c.EVENT_TEXT_INPUT => {
            const p = ev.text.text orelse return null;
            return .{ .text = core.input.Text.from(std.mem.span(p)) };
        },
        c.EVENT_WINDOW_MOUSE_LEAVE => return .pointer_leave,
        else => return null,
    }
}

const Screen = struct {
    texture: ?*c.Texture = null,
    pixels: []u32 = &.{},
    pw: i32 = 0,
    ph: i32 = 0,
    lw: i32 = 0,
    lh: i32 = 0,
    scale: i32 = 1,

    fn update(self: *Screen, gpa: std.mem.Allocator, window: *c.Window, renderer: *c.Renderer) !bool {
        var lw: c_int = 0;
        var lh: c_int = 0;
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &lw, &lh);
        _ = c.SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (lw == self.lw and lh == self.lh and pw == self.pw and ph == self.ph) return false;
        // Integer scale only (1× or 2×), as on HiDPI Wayland outputs.
        const scale: i32 = std.math.clamp(@divTrunc(pw + @divTrunc(lw, 2), @max(lw, 1)), 1, 2);
        self.lw = lw;
        self.lh = lh;
        self.pw = lw * scale;
        self.ph = lh * scale;
        self.scale = scale;
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        const tex = c.SDL_CreateTexture(renderer, c.PIXELFORMAT_ARGB8888, c.TEXTUREACCESS_STREAMING, self.pw, self.ph) orelse return error.Texture;
        // The canvas is already at physical size; never smooth it.
        _ = c.SDL_SetTextureScaleMode(tex, c.SCALEMODE_NEAREST);
        self.texture = tex;
        self.pixels = try gpa.realloc(self.pixels, @intCast(self.pw * self.ph));
        return true;
    }
};

fn sdlFailed(what: []const u8, count: *u32) void {
    count.* += 1;
    if (count.* <= 8) std.log.err("{s} failed: {s}", .{ what, c.SDL_GetError() });
    if (count.* == 8) std.log.err("(further SDL errors are not shown)", .{});
}

fn clockText(buf: []u8) []const u8 {
    const t = c.time(null);
    var tm: c.Tm = undefined;
    _ = c.localtime_r(&t, &tm) orelse return "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)) }) catch "";
}

fn writePpm(io: std.Io, path: []const u8, s: *const Screen) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    const out = &fw.interface;
    defer out.flush() catch {};
    try out.print("P6\n{d} {d}\n255\n", .{ s.pw, s.ph });
    var row: [4096 * 3]u8 = undefined;
    var y: usize = 0;
    while (y < s.ph) : (y += 1) {
        const w: usize = @intCast(s.pw);
        for (0..w) |x| {
            const p = s.pixels[y * w + x];
            row[x * 3] = @truncate(p >> 16);
            row[x * 3 + 1] = @truncate(p >> 8);
            row[x * 3 + 2] = @truncate(p);
        }
        try out.writeAll(row[0 .. w * 3]);
    }
}

/// Monotonic nanoseconds since start: the core's frame clock.
const Clock = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn now(self: Clock) i64 {
        return @intCast(self.start.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds);
    }
};

/// Scripted input for headless checks: (time in ms, event).
const Step = struct { t: i64, ev: core.input.Event };

fn motion(t: i64, x: f32, y: f32) Step {
    return .{ .t = t, .ev = .{ .pointer_motion = .{ .x = x, .y = y } } };
}
fn wheelStep(t: i64, n: f32) Step {
    return .{ .t = t, .ev = .{ .wheel = .{ .dy = n } } };
}
fn keyStep(t: i64, k: core.input.Key, pressed: bool) Step {
    return .{ .t = t, .ev = .{ .key = .{ .key = k, .pressed = pressed, .mods = .{} } } };
}

fn script(name: []const u8) struct { steps: []const Step, end: i64 } {
    const S = struct {
        const default = [_]Step{};
        const map = [_]Step{
            motion(1700, 1000, 500),
            wheelStep(1750, 1), wheelStep(1800, 1), wheelStep(1830, 1), wheelStep(1860, 1),
            wheelStep(1890, 1), wheelStep(1920, 1), wheelStep(1950, 1), wheelStep(1980, 1),
            motion(2600, 1430, 400), motion(2610, 1431, 402),
            motion(3000, 1360, 520),
        };
        const launcher = [_]Step{
            motion(1700, 700, 450),
            keyStep(1800, .super, true), keyStep(1850, .super, false),
        };
        const drag = [_]Step{
            motion(1700, 697, 460),
            .{ .t = 1750, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 697, .y = 460 } } },
            motion(1800, 650, 460), motion(1850, 600, 460), motion(1900, 560, 460),
        };
        const swap = [_]Step{
            motion(1700, 1060, 63),
            .{ .t = 1750, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 1060, .y = 63 } } },
            motion(1800, 900, 200), motion(1850, 500, 400), motion(1900, 350, 420),
        };
        const minimize = [_]Step{
            motion(1700, 300, 700),
            .{ .t = 1720, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 300, .y = 700 } } },
            .{ .t = 1730, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 300, .y = 700 } } },
            keyStep(1800, .super, true),
            .{ .t = 1810, .ev = .{ .key = .{ .key = .z, .pressed = true, .mods = .{ .super = true } } } },
            keyStep(1820, .super, false),
        };
        const maximize = [_]Step{
            keyStep(1800, .super, true),
            .{ .t = 1810, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{ .super = true } } } },
            keyStep(1820, .super, false),
        };
        const fullscreen = [_]Step{
            keyStep(1800, .super, true),
            .{ .t = 1810, .ev = .{ .key = .{ .key = .f, .pressed = true, .mods = .{ .super = true } } } },
            keyStep(1820, .super, false),
            motion(2200, 700, 1), motion(2300, 120, 15),
        };
        const panel_drag = [_]Step{
            motion(1700, 38, 95),
            .{ .t = 1720, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 38, .y = 95 } } },
            motion(1800, 300, 300), motion(1900, 500, 420), motion(2000, 560, 450),
        };
        const restore_icon = [_]Step{
            keyStep(1800, .super, true),
            .{ .t = 1810, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{ .super = true } } } },
            keyStep(1820, .super, false),
            motion(2100, 230, 44), motion(2150, 232, 44),
        };
        const apps_button = [_]Step{
            motion(1700, 16, 14),
            .{ .t = 1720, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 16, .y = 14 } } },
            .{ .t = 1730, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 16, .y = 14 } } },
        };
        const apps_panel = [_]Step{
            motion(300, 28, 868),
            .{ .t = 320, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 28, .y = 868 } } },
            .{ .t = 340, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 28, .y = 868 } } },
        };
        const control_center = [_]Step{
            .{ .t = 1700, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 1390, .y = 14 } } },
            .{ .t = 1710, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 1390, .y = 14 } } },
            motion(1800, 1300, 82),
        };
        const buttons = [_]Step{
            motion(1700, 250, 50), motion(1750, 252, 52),
        };
        // Super, "notes", Shift+Enter: a second Notes window; then Super,
        // "notes", Enter: the chooser for the two.
        const chooser = [_]Step{
            keyStep(1700, .super, true),                                             keyStep(1710, .super, false),
            .{ .t = 1800, .ev = .{ .text = core.input.Text.from("notes") } },
            .{ .t = 1850, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{ .shift = true } } } },
            keyStep(3000, .super, true),                                             keyStep(3010, .super, false),
            .{ .t = 3100, .ev = .{ .text = core.input.Text.from("notes") } },
            .{ .t = 3150, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{} } } },
            motion(3300, 700, 300),
        };
        // Super, "reader", Enter: the outline travels from the icon.
        const cue = [_]Step{
            keyStep(1700, .super, true),                                             keyStep(1710, .super, false),
            .{ .t = 1800, .ev = .{ .text = core.input.Text.from("reader") } },
            .{ .t = 1850, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{} } } },
        };
        const preview = [_]Step{
            motion(1700, 38, 95), motion(1800, 45, 80), motion(1900, 57, 60), motion(1950, 57, 59),
        };
        const preview_restore = [_]Step{
            motion(1700, 38, 95), motion(1900, 57, 60), motion(1950, 57, 59),
            .{ .t = 2000, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 57, .y = 59 } } },
            .{ .t = 2010, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 57, .y = 59 } } },
        };
        const close = [_]Step{
            motion(1700, 300, 700),
            .{ .t = 1720, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 300, .y = 700 } } },
            .{ .t = 1730, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 300, .y = 700 } } },
            keyStep(1800, .super, true),
            .{ .t = 1810, .ev = .{ .key = .{ .key = .x, .pressed = true, .mods = .{ .super = true } } } },
            keyStep(1820, .super, false),
        };
        const menu_title = [_]Step{
            motion(1700, 400, 52), motion(1750, 402, 52),
        };
        const panel_buttons = [_]Step{
            motion(1700, 50, 52), motion(1750, 52, 52),
        };
        const minimize_all = [_]Step{
            .{ .t = 1800, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 20, .y = 50 } } },
            .{ .t = 1810, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 20, .y = 50 } } },
            motion(2000, 700, 500),
        };
        // Super, then rest on Notes: its "+" badge shows; click it.
        const new_window = [_]Step{
            keyStep(1700, .super, true),                                             keyStep(1710, .super, false),
            motion(1800, 760, 270), motion(1850, 762, 270),
            .{ .t = 2000, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 809, .y = 241 } } },
            .{ .t = 2010, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 809, .y = 241 } } },
        };
        // Two more Notes windows (Shift+Enter in the launcher), minimize
        // all, then rest on the Notes group in the panel.
        const group = [_]Step{
            keyStep(1700, .super, true),                                             keyStep(1710, .super, false),
            .{ .t = 1750, .ev = .{ .text = core.input.Text.from("notes") } },
            .{ .t = 1800, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{ .shift = true } } } },
            keyStep(2100, .super, true),                                             keyStep(2110, .super, false),
            .{ .t = 2150, .ev = .{ .text = core.input.Text.from("notes") } },
            .{ .t = 2200, .ev = .{ .key = .{ .key = .enter, .pressed = true, .mods = .{ .shift = true } } } },
            .{ .t = 2800, .ev = .{ .pointer_button = .{ .button = .left, .pressed = true, .x = 20, .y = 50 } } },
            .{ .t = 2810, .ev = .{ .pointer_button = .{ .button = .left, .pressed = false, .x = 20, .y = 50 } } },
            motion(3300, 38, 260), motion(3350, 38, 262),
        };
        const group_menu = group ++ [_]Step{
            .{ .t = 3500, .ev = .{ .pointer_button = .{ .button = .right, .pressed = true, .x = 38, .y = 262 } } },
            .{ .t = 3510, .ev = .{ .pointer_button = .{ .button = .right, .pressed = false, .x = 38, .y = 262 } } },
            motion(3600, 60, 272),
        };
        const pulse = [_]Step{
            motion(1700, 38, 190), motion(1750, 40, 192),
        };
        const enlarge = [_]Step{
            motion(1700, 80, 300), motion(1720, 82, 321),
        };
    };
    if (std.mem.eql(u8, name, "map")) return .{ .steps = &S.map, .end = 3300 };
    if (std.mem.eql(u8, name, "launcher")) return .{ .steps = &S.launcher, .end = 2300 };
    if (std.mem.eql(u8, name, "drag")) return .{ .steps = &S.drag, .end = 2300 };
    if (std.mem.eql(u8, name, "swap")) return .{ .steps = &S.swap, .end = 2300 };
    if (std.mem.eql(u8, name, "minimize_mid")) return .{ .steps = &S.minimize, .end = 1950 };
    if (std.mem.eql(u8, name, "minimize")) return .{ .steps = &S.minimize, .end = 2400 };
    if (std.mem.eql(u8, name, "maximize")) return .{ .steps = &S.maximize, .end = 2400 };
    if (std.mem.eql(u8, name, "fullscreen")) return .{ .steps = &S.fullscreen, .end = 2600 };
    if (std.mem.eql(u8, name, "panel_drag")) return .{ .steps = &S.panel_drag, .end = 2200 };
    if (std.mem.eql(u8, name, "restore_icon")) return .{ .steps = &S.restore_icon, .end = 2500 };
    if (std.mem.eql(u8, name, "apps_button")) return .{ .steps = &S.apps_button, .end = 2200 };
    if (std.mem.eql(u8, name, "apps_panel")) return .{ .steps = &S.apps_panel, .end = 900 };
    if (std.mem.eql(u8, name, "control_center")) return .{ .steps = &S.control_center, .end = 2100 };
    if (std.mem.eql(u8, name, "buttons")) return .{ .steps = &S.buttons, .end = 2100 };
    if (std.mem.eql(u8, name, "chooser")) return .{ .steps = &S.chooser, .end = 3500 };
    if (std.mem.eql(u8, name, "cue")) return .{ .steps = &S.cue, .end = 1990 };
    if (std.mem.eql(u8, name, "flash")) return .{ .steps = &S.cue, .end = 2280 };
    if (std.mem.eql(u8, name, "preview")) return .{ .steps = &S.preview, .end = 2200 };
    if (std.mem.eql(u8, name, "preview_restore")) return .{ .steps = &S.preview_restore, .end = 2150 };
    if (std.mem.eql(u8, name, "close")) return .{ .steps = &S.close, .end = 1920 };
    if (std.mem.eql(u8, name, "minimize_flash")) return .{ .steps = &S.minimize, .end = 2230 };
    if (std.mem.eql(u8, name, "menu_title")) return .{ .steps = &S.menu_title, .end = 2100 };
    if (std.mem.eql(u8, name, "panel_buttons")) return .{ .steps = &S.panel_buttons, .end = 2000 };
    if (std.mem.eql(u8, name, "minimize_all")) return .{ .steps = &S.minimize_all, .end = 2500 };
    if (std.mem.eql(u8, name, "new_badge")) return .{ .steps = &S.new_window, .end = 1950 };
    if (std.mem.eql(u8, name, "new_window")) return .{ .steps = &S.new_window, .end = 3200 };
    if (std.mem.eql(u8, name, "group_panel")) return .{ .steps = &S.group, .end = 3250 };
    if (std.mem.eql(u8, name, "group")) return .{ .steps = &S.group, .end = 3700 };
    if (std.mem.eql(u8, name, "group_menu")) return .{ .steps = &S.group_menu, .end = 3800 };
    if (std.mem.eql(u8, name, "pulse")) return .{ .steps = &S.pulse, .end = 3000 };
    if (std.mem.eql(u8, name, "enlarge")) return .{ .steps = &S.enlarge, .end = 3200 };
    return .{ .steps = &S.default, .end = 2200 };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = try parseArgs(args);

    if (!c.SDL_Init(c.INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return error.Sdl;
    }
    defer c.SDL_Quit();
    // After SDL_Init, so these replace SDL's own handlers.
    _ = signal(SIGINT, &onQuitSignal);
    _ = signal(SIGTERM, &onQuitSignal);
    // The window must fit on the screen, or the bottom of the panel (the
    // apps button) is cut off. Scripted runs keep their size.
    var win_w = opts.w;
    var win_h = opts.h;
    if (opts.fullscreen and !opts.size_given and opts.snapshot == null) {
        // Full screen (the VM's console): exactly the display's current
        // mode. A smaller window makes SDL's KMS/DRM driver pick another
        // mode (1280x768 on a 1280x800 screen), which the VM's virtio-gpu
        // never shows: the console stays on screen.
        var full: c.Rect = undefined;
        if (c.SDL_GetDisplayBounds(c.SDL_GetPrimaryDisplay(), &full)) {
            win_w = full.w;
            win_h = full.h;
        }
    } else if (!opts.size_given and opts.snapshot == null) {
        var usable: c.Rect = undefined;
        if (c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &usable)) {
            // Room for the window's own title bar.
            win_w = @min(win_w, usable.w - 16);
            win_h = @min(win_h, usable.h - 40);
        }
    }
    const window = c.SDL_CreateWindow("Tesselix (simulator)", win_w, win_h, c.WINDOW_RESIZABLE | c.WINDOW_HIGH_PIXEL_DENSITY | (if (opts.fullscreen) c.WINDOW_FULLSCREEN else 0)) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
        return error.Sdl;
    };
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
        return error.Sdl;
    };
    defer c.SDL_DestroyRenderer(renderer);
    if (!c.SDL_SetRenderVSync(renderer, 1)) std.log.warn("SDL_SetRenderVSync: {s}", .{c.SDL_GetError()});

    var screen: Screen = .{};
    defer gpa.free(screen.pixels);
    _ = try screen.update(gpa, window, renderer);
    std.log.info("SDL video driver {s}, renderer {s}, window {d}x{d} (pixels {d}x{d}, scale {d})", .{
        c.SDL_GetCurrentVideoDriver() orelse "?", c.SDL_GetRendererName(renderer) orelse "?",
        screen.lw, screen.lh, screen.pw, screen.ph, screen.scale,
    });
    // Render calls that fail are reported (a few times), not ignored: on a
    // new backend a failing present leaves the screen blank without a word.
    var sdl_errors: u32 = 0;
    var presented: u64 = 0;

    const clock = Clock{ .io = io, .start = std.Io.Timestamp.now(io, .awake) };

    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = screen.lw, .h = screen.lh }, screen.scale, .{ .dark = opts.dark });
    defer comp.deinit();
    if (opts.empty) {
        // Nothing started.
    } else if (opts.tiled or opts.snapshot != null) {
        // Three growable windows (Scroll Lab, Notes, Reader) and two small
        // ones (Controls, Stopwatch). Four fit on a screen; the least
        // recently used goes to the panel. Scripted runs start this way.
        for ([_]usize{ 2, 4, 3, 1, 0 }) |a| _ = try comp.launch(a, clock.now());
    } else {
        // As after login: a clean desktop, with Controls, Scroll Lab and
        // Notes started and waiting in the panel. The others are in the
        // launcher.
        for ([_]usize{ 0, 1, 3 }) |a| _ = try comp.launchMinimized(a, clock.now());
    }

    // Same order as core.input.Cursor.
    var cursors: [6]?*c.Cursor = .{
        c.SDL_CreateSystemCursor(.default),
        c.SDL_CreateSystemCursor(.pointer),
        c.SDL_CreateSystemCursor(.text),
        c.SDL_CreateSystemCursor(.ew_resize),
        c.SDL_CreateSystemCursor(.ns_resize),
        c.SDL_CreateSystemCursor(.move),
    };
    defer for (&cursors) |cur| if (cur) |p| c.SDL_DestroyCursor(p);
    var shown_cursor: ?core.input.Cursor = null;

    _ = c.SDL_StartTextInput(window);

    // Timing instrumentation: frame time and input-to-present latency.
    var frame_hist: core.metrics.Histogram = .{};
    var latency_hist: core.metrics.Histogram = .{};
    // Time between presented frames while drawing continuously: the real
    // frame rate (idle pauses are left out).
    var interval_hist: core.metrics.Histogram = .{};
    var last_present: i64 = -1;
    var pending_input: ?i64 = null;

    const sc = script(opts.script);
    var step_i: usize = 0;
    var clock_buf: [16]u8 = undefined;
    var need = true;
    var running = true;

    while (running) {
        if (quit_signal.load(.monotonic)) break;
        var ev: c.Event = undefined;
        // Scripted runs poll, so steps fire on time.
        const timeout: i32 = if (need or opts.snapshot != null) 1 else 250;
        var got = c.SDL_WaitEventTimeout(&ev, timeout);
        while (got) : (got = c.SDL_PollEvent(&ev)) {
            const now = clock.now();
            if (ev.type == c.EVENT_QUIT) running = false;
            if (ev.type == c.EVENT_WINDOW_RESIZED or ev.type == c.EVENT_WINDOW_PIXEL_SIZE_CHANGED or ev.type == c.EVENT_WINDOW_DISPLAY_SCALE_CHANGED) {
                if (try screen.update(gpa, window, renderer)) comp.setScreen(.{ .w = screen.lw, .h = screen.lh }, screen.scale, now);
                need = true;
            }
            if (opts.snapshot != null) continue; // scripted runs ignore real input
            if (translate(&ev)) |e| {
                comp.handleInput(e, now);
                if (pending_input == null) pending_input = now;
                need = true;
            }
        }

        const now = clock.now();
        while (step_i < sc.steps.len and now >= sc.steps[step_i].t * ms) : (step_i += 1) {
            comp.handleInput(sc.steps[step_i].ev, now);
            need = true;
        }

        comp.setClock(clockText(&clock_buf));
        if (comp.tick(now)) need = true;

        const want: core.input.Cursor = comp.cursor;
        if (shown_cursor != want) {
            _ = c.SDL_SetCursor(cursors[@intFromEnum(want)]);
            shown_cursor = want;
        }

        if (need) {
            const t0 = clock.now();
            var cv = tw.Canvas.init(screen.pixels, screen.pw, screen.ph, screen.pw, screen.scale);
            comp.render(&cv, now);
            if (!c.SDL_UpdateTexture(screen.texture.?, null, screen.pixels.ptr, screen.pw * 4)) sdlFailed("SDL_UpdateTexture", &sdl_errors);
            if (!c.SDL_RenderClear(renderer)) sdlFailed("SDL_RenderClear", &sdl_errors);
            if (!c.SDL_RenderTexture(renderer, screen.texture.?, null, null)) sdlFailed("SDL_RenderTexture", &sdl_errors);
            const t1 = clock.now();
            if (c.SDL_RenderPresent(renderer)) {
                presented += 1;
                const tp = clock.now();
                if (last_present >= 0 and tp - last_present <= txcomp.FramePace.idle_gap) interval_hist.record(tp - last_present);
                last_present = tp;
                if (presented == 1) std.log.info("first frame presented", .{});
            } else sdlFailed("SDL_RenderPresent", &sdl_errors);
            frame_hist.record(t1 - t0);
            if (pending_input) |t| latency_hist.record(clock.now() - t);
            pending_input = null;
            need = false;
        }

        if (opts.snapshot) |path| {
            if (now >= sc.end * ms) {
                var cv = tw.Canvas.init(screen.pixels, screen.pw, screen.ph, screen.pw, screen.scale);
                comp.render(&cv, now);
                try writePpm(io, path, &screen);
                running = false;
            }
        }
    }

    std.debug.print("\n-- timing --\n", .{});
    frame_hist.print("frame build (core render + upload)");
    interval_hist.print("frame interval (while drawing)");
    latency_hist.print("input to present");
    // Stopped by a signal: leave now. Tearing down SDL inside a Wayland
    // kiosk (cage) can hang, and the OS frees everything anyway.
    if (quit_signal.load(.monotonic)) std.process.exit(0);
}
