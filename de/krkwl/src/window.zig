//! A Wayland app's top-level window, as the compositor sees it: the same
//! window contract as Kuroko's own apps (krkwidgets Surface).
//!
//! - configure: the compositor gives the size; the app is told
//!   (xdg_toplevel.configure with its state: focused, maximized, full
//!   screen, tiled) and draws a frame of that size.
//! - draw: the app's last frame, its subsurfaces and popups, composited
//!   into the window's tile. A frame of another size is cut or padded,
//!   never stretched.
//! - input: pointer events go to the surface under the pointer (popups
//!   first), keys to the focused window, as Linux key codes.
//! - close: the app is asked; the window stays until the app closes it.

const std = @import("std");
const core = @import("krkcore");
const tw = @import("krkwidgets");
const server_mod = @import("server.zig");
const keymap = @import("keymap.zig");

const Server = server_mod.Server;
const XdgSurf = server_mod.XdgSurf;
const Surf = server_mod.Surf;
const Canvas = tw.Canvas;
const ms = std.time.ns_per_ms;

pub const Win = struct {
    server: *Server,
    /// Null once the app destroyed the window or left.
    xdg: ?*XdgSurf,
    size: core.Size = .{ .w = 0, .h = 0 },
    scale: i32 = 1,
    state: tw.surface.WindowState = .{},
    dark: bool = false,
    dirty: bool = true,
    gone: bool = false,
    configured: bool = false,
    sent_w: i32 = -1,
    sent_h: i32 = -1,
    sent_state: tw.surface.WindowState = .{},
    /// Popups, bottom to top.
    popups: std.ArrayList(*XdgSurf) = .empty,
    pointer_on: ?*Surf = null,
    kb_entered: bool = false,
    mods_sent: u32 = 0,
    /// Kept for the closing animation after the app is gone.
    title_copy: [256]u8 = undefined,
    title_len: usize = 0,
    app_id_copy: [128]u8 = undefined,
    app_id_len: usize = 0,

    pub fn create(server: *Server, x: *XdgSurf) !*Win {
        const w = try server.gpa.create(Win);
        w.* = .{ .server = server, .xdg = x, .scale = server.out_scale };
        return w;
    }

    pub fn surface(self: *Win) tw.Surface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn client(self: *Win) ?*server_mod.Client {
        const x = self.xdg orelse return null;
        return x.client;
    }

    /// The app destroyed the window or disconnected.
    pub fn clientGone(self: *Win) void {
        self.copyNames();
        self.xdg = null;
        self.gone = true;
        self.pointer_on = null;
        self.popups.clearRetainingCapacity();
        self.dirty = true;
    }

    fn copyNames(self: *Win) void {
        const x = self.xdg orelse return;
        self.title_len = @min(x.title.items.len, self.title_copy.len);
        @memcpy(self.title_copy[0..self.title_len], x.title.items[0..self.title_len]);
        self.app_id_len = @min(x.app_id.items.len, self.app_id_copy.len);
        @memcpy(self.app_id_copy[0..self.app_id_len], x.app_id.items[0..self.app_id_len]);
    }

    pub fn hasPopup(self: *const Win, x: *XdgSurf) bool {
        for (self.popups.items) |p| {
            if (p == x) return true;
        }
        return false;
    }

    pub fn removePopup(self: *Win, x: *XdgSurf) void {
        for (self.popups.items, 0..) |p, i| {
            if (p == x) {
                _ = self.popups.orderedRemove(i);
                break;
            }
        }
        if (self.pointer_on) |s| {
            if (s == x.surf) self.pointer_on = null;
        }
        self.dirty = true;
    }

    // ----------------------------------------------------------- geometry

    /// Where an xdg surface's window-geometry origin is, in content
    /// coordinates (logical px).
    pub fn originOf(self: *Win, x: *XdgSurf) struct { x: i32, y: i32 } {
        _ = self;
        if (x.role == .popup) {
            const p = x.parent orelse return .{ .x = 0, .y = 0 };
            const po = originOfStatic(p);
            return .{ .x = po.x + x.rect.x, .y = po.y + x.rect.y };
        }
        return .{ .x = 0, .y = 0 };
    }

    fn originOfStatic(x: *XdgSurf) struct { x: i32, y: i32 } {
        if (x.role == .popup) {
            const p = x.parent orelse return .{ .x = 0, .y = 0 };
            const po = originOfStatic(p);
            return .{ .x = po.x + x.rect.x, .y = po.y + x.rect.y };
        }
        return .{ .x = 0, .y = 0 };
    }

    /// Where an xdg surface's buffer starts: its origin minus its geometry
    /// offset (the client's shadows lie outside the geometry).
    fn surfaceOrigin(x: *XdgSurf) struct { x: i32, y: i32 } {
        const o = originOfStatic(x);
        const g = x.geom();
        return .{ .x = o.x - g.x, .y = o.y - g.y };
    }

    // ---------------------------------------------------------- configure

    /// Tells the app its size and state (xdg_toplevel.configure).
    pub fn sendConfigure(self: *Win) void {
        const x = self.xdg orelse return;
        const cl = x.client;
        if (x.role_id == 0) return;
        var states: [8]u32 = undefined;
        var n: usize = 0;
        if (self.state.maximized) {
            states[n] = 1;
            n += 1;
        }
        if (self.state.fullscreen) {
            states[n] = 2;
            n += 1;
        }
        if (self.state.focused) {
            states[n] = 4;
            n += 1;
        }
        const version = if (cl.objects.get(x.role_id)) |o| o.version else 1;
        // In a tile every edge is fixed: no shadows, square corners.
        if (self.state.tiled and version >= 2) {
            for ([_]u32{ 5, 6, 7, 8 }) |s| {
                states[n] = s;
                n += 1;
            }
        }
        const w_ = if (self.configured) self.size.w else 0;
        const h_ = if (self.configured) self.size.h else 0;
        if (version >= 4) {
            var b = cl.event(x.role_id, 2) catch return; // configure_bounds
            b.int(self.server.out_w) catch return;
            b.int(self.server.out_h) catch return;
            b.end();
        }
        var w = cl.event(x.role_id, 0) catch return;
        w.int(w_) catch return;
        w.int(h_) catch return;
        w.array(std.mem.sliceAsBytes(states[0..n])) catch return;
        w.end();
        var s = cl.event(x.id, 0) catch return;
        s.uint(self.server.nextSerial()) catch return;
        s.end();
        x.configure_sent = true;
        self.sent_w = w_;
        self.sent_h = h_;
        self.sent_state = self.state;
    }

    fn setSize(self: *Win, size: core.Size, scale: i32) void {
        self.size = size;
        self.scale = scale;
        self.configured = true;
        if (size.w != self.sent_w or size.h != self.sent_h) self.sendConfigure();
        self.dirty = true;
    }

    fn setState(self: *Win, st: tw.surface.WindowState) void {
        const was_focused = self.state.focused;
        self.state = st;
        if (@as(u8, @bitCast(st)) != @as(u8, @bitCast(self.sent_state)) and self.configured) self.sendConfigure();
        if (st.focused and !was_focused) {
            const cl = self.client() orelse return;
            for (cl.keyboards.items) |k| self.keyboardEnter(k);
        } else if (!st.focused and was_focused) {
            self.keyboardLeave();
            self.dismissPopups();
        }
    }

    // ------------------------------------------------------------ drawing

    fn draw(self: *Win, cv: *Canvas) void {
        self.dirty = false;
        const th = if (self.dark) core.Theme.darkTheme() else core.Theme.light();
        cv.clear(th.get(.surface));
        const x = self.xdg orelse return;
        const o = surfaceOrigin(x);
        drawTree(cv, x.surf, o.x, o.y);
        for (self.popups.items) |p| {
            const po = surfaceOrigin(p);
            drawTree(cv, p.surf, po.x, po.y);
        }
    }

    /// A surface and its subsurfaces, at logical (lx, ly).
    fn drawTree(cv: *Canvas, s: *Surf, lx: i32, ly: i32) void {
        for (s.children.items) |ch| if (ch.below) drawTree(cv, ch, lx + ch.x, ly + ch.y);
        compose(cv, s, lx, ly);
        for (s.children.items) |ch| if (!ch.below) drawTree(cv, ch, lx + ch.x, ly + ch.y);
    }

    /// Premultiplied ARGB over the canvas; scaled (nearest) when the
    /// buffer scale differs from the canvas scale.
    fn compose(cv: *Canvas, s: *const Surf, lx: i32, ly: i32) void {
        if (s.w <= 0 or s.h <= 0 or s.pixels.len == 0) return;
        const l = s.logical();
        const dst: core.Rect = .{ .x = lx * cv.scale, .y = ly * cv.scale, .w = l.w * cv.scale, .h = l.h * cv.scale };
        const d = dst.intersect(cv.clip);
        if (d.isEmpty()) return;
        var y = d.y;
        while (y < d.bottom()) : (y += 1) {
            const sy: usize = @intCast(@min(s.h - 1, @divTrunc((y - dst.y) * s.h, dst.h)));
            var px = d.x;
            while (px < d.right()) : (px += 1) {
                const sx: usize = @intCast(@min(s.w - 1, @divTrunc((px - dst.x) * s.w, dst.w)));
                const v = s.pixels[sy * @as(usize, @intCast(s.w)) + sx];
                const idx: usize = @intCast(y * cv.stride + px);
                if (v >> 24 == 255) {
                    cv.pixels[idx] = v;
                } else if (v != 0) {
                    cv.pixels[idx] = over(v, cv.pixels[idx]);
                }
            }
        }
    }

    fn over(src: u32, dst: u32) u32 {
        const inv = 255 - (src >> 24);
        var out: u32 = 0;
        inline for ([_]u5{ 0, 8, 16, 24 }) |sh| {
            const sc = (src >> sh) & 0xff;
            const dc = (dst >> sh) & 0xff;
            const v: u32 = @min(255, sc + (dc * inv + 127) / 255);
            out |= v << sh;
        }
        return out;
    }

    // -------------------------------------------------------------- input

    const Hit = struct { s: *Surf, x: f32, y: f32 };

    /// The topmost surface under content point (x, y).
    fn hit(self: *Win, x: f32, y: f32) ?Hit {
        var i = self.popups.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.popups.items[i];
            const o = surfaceOrigin(p);
            if (hitTree(p.surf, x, y, o.x, o.y)) |h| return h;
        }
        const t = self.xdg orelse return null;
        const o = surfaceOrigin(t);
        return hitTree(t.surf, x, y, o.x, o.y);
    }

    fn hitTree(s: *Surf, x: f32, y: f32, lx: i32, ly: i32) ?Hit {
        var i = s.children.items.len;
        while (i > 0) {
            i -= 1;
            const ch = s.children.items[i];
            if (!ch.below) if (hitTree(ch, x, y, lx + ch.x, ly + ch.y)) |h| return h;
        }
        const l = s.logical();
        const fx: f32 = @floatFromInt(lx);
        const fy: f32 = @floatFromInt(ly);
        if (x >= fx and y >= fy and x < fx + @as(f32, @floatFromInt(l.w)) and y < fy + @as(f32, @floatFromInt(l.h))) {
            return .{ .s = s, .x = x - fx, .y = y - fy };
        }
        i = s.children.items.len;
        while (i > 0) {
            i -= 1;
            const ch = s.children.items[i];
            if (ch.below) if (hitTree(ch, x, y, lx + ch.x, ly + ch.y)) |h| return h;
        }
        return null;
    }

    fn pointerEvent(self: *Win, opcode: u16, args: anytype) void {
        const cl = self.client() orelse return;
        for (cl.pointers.items) |p| {
            const version = if (cl.objects.get(p)) |o| o.version else 1;
            var w = cl.event(p, opcode) catch return;
            inline for (args) |arg| {
                switch (@TypeOf(arg)) {
                    u32 => w.uint(arg) catch return,
                    i32 => w.int(arg) catch return,
                    f32 => w.fixed(arg) catch return,
                    else => @compileError("pointer argument"),
                }
            }
            w.end();
            if (version >= 5 and opcode != 5) {
                var f = cl.event(p, 5) catch return; // frame
                f.end();
            }
        }
    }

    /// The pointer leaves the surface it was on. A surface the app has
    /// destroyed gets no leave: its id is free, and an event naming it is
    /// a fatal protocol error in the app (libwayland "unknown object").
    fn leavePointer(self: *Win) void {
        const old = self.pointer_on orelse return;
        self.pointer_on = null;
        if (!old.destroyed) self.pointerEvent(1, .{ self.server.nextSerial(), old.id });
    }

    fn movePointer(self: *Win, x: f32, y: f32, time: u32) void {
        const h = self.hit(x, y);
        const on: ?*Surf = if (h) |hh| hh.s else null;
        if (on != self.pointer_on) {
            self.leavePointer();
            self.pointer_on = on;
            if (h) |hh| self.pointerEvent(0, .{ self.server.nextSerial(), hh.s.id, hh.x, hh.y });
        } else if (h) |hh| {
            self.pointerEvent(2, .{ time, hh.x, hh.y });
        }
    }

    fn input(self: *Win, ev: core.input.Event, now: i64) void {
        const time: u32 = @truncate(@as(u64, @intCast(@max(now, 0))) / ms);
        if (self.xdg == null) return;
        switch (ev) {
            .pointer_motion => |m| self.movePointer(m.x, m.y, time),
            .pointer_leave => self.leavePointer(),
            .pointer_button => |b| {
                self.movePointer(b.x, b.y, time);
                // A click outside the open menus closes them, and does
                // nothing else.
                if (b.pressed and self.grabbing() and !self.onPopup()) {
                    self.dismissPopups();
                    return;
                }
                const code: u32 = switch (b.button) {
                    .left => 0x110,
                    .right => 0x111,
                    .middle => 0x112,
                };
                if (self.pointer_on != null) self.pointerEvent(3, .{ self.server.nextSerial(), time, code, @as(u32, @intFromBool(b.pressed)) });
            },
            .wheel => |wh| {
                if (self.pointer_on == null) return;
                const cl = self.client() orelse return;
                for (cl.pointers.items) |p| {
                    const version = if (cl.objects.get(p)) |o| o.version else 1;
                    for ([_]struct { axis: u32, v: f32 }{ .{ .axis = 0, .v = wh.dy }, .{ .axis = 1, .v = wh.dx } }) |ax| {
                        if (ax.v == 0) continue;
                        if (version >= 5) {
                            var s = cl.event(p, 6) catch return; // axis_source
                            s.uint(if (wh.source == .wheel) 0 else 1) catch return;
                            s.end();
                            if (wh.source == .wheel) {
                                var d = cl.event(p, 8) catch return; // axis_discrete
                                d.uint(ax.axis) catch return;
                                d.int(@intFromFloat(@round(ax.v))) catch return;
                                d.end();
                            }
                        }
                        var w = cl.event(p, 4) catch return;
                        w.uint(time) catch return;
                        w.uint(ax.axis) catch return;
                        // A notch is 15 (libinput's degrees); touchpads in px.
                        w.fixed(if (wh.source == .wheel) ax.v * 15 else ax.v) catch return;
                        w.end();
                    }
                    if (version >= 5) {
                        var f = cl.event(p, 5) catch return;
                        f.end();
                    }
                }
            },
            .key => |k| {
                if (k.code == 0 or k.repeat or !self.kb_entered) return;
                const cl = self.client() orelse return;
                for (cl.keyboards.items) |kb| {
                    var w = cl.event(kb, 3) catch return;
                    w.uint(self.server.nextSerial()) catch return;
                    w.uint(time) catch return;
                    w.uint(k.code) catch return;
                    w.uint(@intFromBool(k.pressed)) catch return;
                    w.end();
                }
                self.sendModifiers(k.mods);
            },
            .text => {}, // apps make text from key codes and the keymap
        }
    }

    fn grabbing(self: *const Win) bool {
        for (self.popups.items) |p| {
            if (p.grab) return true;
        }
        return false;
    }

    fn onPopup(self: *const Win) bool {
        const s = self.pointer_on orelse return false;
        for (self.popups.items) |p| {
            if (treeHas(p.surf, s)) return true;
        }
        return false;
    }

    fn treeHas(root: *Surf, s: *Surf) bool {
        if (root == s) return true;
        for (root.children.items) |ch| if (treeHas(ch, s)) return true;
        return false;
    }

    /// Closes every popup, topmost first (xdg_popup.popup_done).
    fn dismissPopups(self: *Win) void {
        const cl = self.client() orelse return;
        var i = self.popups.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.popups.items[i];
            if (p.role_id != 0) {
                var w = cl.event(p.role_id, 1) catch continue;
                w.end();
            }
        }
        self.popups.clearRetainingCapacity();
        self.pointer_on = null;
        self.dirty = true;
    }

    pub fn keyboardEnter(self: *Win, kb: u32) void {
        const cl = self.client() orelse return;
        const x = self.xdg orelse return;
        var w = cl.event(kb, 1) catch return;
        w.uint(self.server.nextSerial()) catch return;
        w.uint(x.surf.id) catch return;
        w.array(&.{}) catch return;
        w.end();
        self.kb_entered = true;
        self.mods_sent = 0xffff_ffff;
        self.sendModifiers(.{});
    }

    fn keyboardLeave(self: *Win) void {
        if (!self.kb_entered) return;
        self.kb_entered = false;
        const cl = self.client() orelse return;
        const x = self.xdg orelse return;
        if (x.surf.destroyed) return;
        for (cl.keyboards.items) |kb| {
            var w = cl.event(kb, 2) catch return;
            w.uint(self.server.nextSerial()) catch return;
            w.uint(x.surf.id) catch return;
            w.end();
        }
    }

    fn sendModifiers(self: *Win, m: core.input.Mods) void {
        var mask: u32 = 0;
        if (m.shift) mask |= keymap.mod_shift;
        if (m.ctrl) mask |= keymap.mod_ctrl;
        if (m.alt) mask |= keymap.mod_alt;
        if (m.super) mask |= keymap.mod_super;
        if (mask == self.mods_sent) return;
        self.mods_sent = mask;
        const cl = self.client() orelse return;
        for (cl.keyboards.items) |kb| {
            var w = cl.event(kb, 4) catch return;
            w.uint(self.server.nextSerial()) catch return;
            w.uint(mask) catch return;
            w.uint(0) catch return;
            w.uint(0) catch return;
            w.uint(0) catch return;
            w.end();
        }
    }

    // ---------------------------------------------------- window contract

    fn cursor(self: *Win) core.input.Cursor {
        if (self.pointer_on == null) return .arrow;
        const cl = self.client() orelse return .arrow;
        // wp_cursor_shape_device_v1 shapes.
        return switch (cl.cursor_shape) {
            4 => .hand, // pointer
            9, 10 => .text,
            13, 16, 17 => .grab, // move, grab, grabbing
            18, 22, 24 => .resize_ew, // e, w, ew resize
            19, 23, 25 => .resize_ns, // n, s, ns resize
            else => .arrow,
        };
    }

    fn requestClose(self: *Win) bool {
        if (self.gone) return false;
        const x = self.xdg orelse return false;
        if (x.role_id == 0) return false;
        var w = x.client.event(x.role_id, 1) catch return false;
        w.end();
        return true;
    }

    fn destroy(self: *Win) void {
        if (self.xdg) |x| {
            // The compositor dropped the window: the app is told to close.
            _ = self.requestClose();
            x.win = null;
        }
        self.popups.deinit(self.server.gpa);
        self.server.gpa.destroy(self);
    }

    fn cast(p: *anyopaque) *Win {
        return @ptrCast(@alignCast(p));
    }

    const vtable: tw.Surface.VTable = .{
        .title = struct {
            fn f(p: *anyopaque) []const u8 {
                const w = cast(p);
                if (w.xdg) |x| return x.title.items;
                return w.title_copy[0..w.title_len];
            }
        }.f,
        .app_id = struct {
            fn f(p: *anyopaque) []const u8 {
                const w = cast(p);
                if (w.xdg) |x| return x.app_id.items;
                return w.app_id_copy[0..w.app_id_len];
            }
        }.f,
        .menu = struct {
            fn f(_: *anyopaque) []const []const u8 {
                return &.{};
            }
        }.f,
        .optimal_size = struct {
            fn f(p: *anyopaque) core.Size {
                const w = cast(p);
                const x = w.xdg orelse return .{ .w = 960, .h = 720 };
                return .{ .w = @max(x.min_w, 960), .h = @max(x.min_h, 720) };
            }
        }.f,
        .growable = struct {
            fn f(_: *anyopaque) bool {
                return true;
            }
        }.f,
        .configure = struct {
            fn f(p: *anyopaque, size: core.Size, scale: i32) void {
                cast(p).setSize(size, scale);
            }
        }.f,
        .set_dark = struct {
            fn f(p: *anyopaque, dark: bool) void {
                cast(p).dark = dark;
            }
        }.f,
        .draw = struct {
            fn f(p: *anyopaque, cv: *Canvas) void {
                cast(p).draw(cv);
            }
        }.f,
        .input = struct {
            fn f(p: *anyopaque, ev: core.input.Event, now: i64) void {
                cast(p).input(ev, now);
            }
        }.f,
        .tick = struct {
            fn f(p: *anyopaque, _: i64) bool {
                return cast(p).dirty;
            }
        }.f,
        .status = struct {
            fn f(_: *anyopaque) tw.surface.Status {
                return .{};
            }
        }.f,
        .cursor = struct {
            fn f(p: *anyopaque) core.input.Cursor {
                return cast(p).cursor();
            }
        }.f,
        .wants_close = struct {
            fn f(p: *anyopaque) bool {
                return cast(p).gone;
            }
        }.f,
        .destroy = struct {
            fn f(p: *anyopaque) void {
                cast(p).destroy();
            }
        }.f,
        .window_state = struct {
            fn f(p: *anyopaque, st: tw.surface.WindowState) void {
                cast(p).setState(st);
            }
        }.f,
        .request_close = struct {
            fn f(p: *anyopaque) bool {
                return cast(p).requestClose();
            }
        }.f,
    };
};
