//! The Wayland server: Kuroko as the display server apps connect to.
//!
//! Apps never choose their own place or size. The compositor gives each
//! window its area and state (xdg_toplevel.configure: tiled, maximized,
//! full screen, focused); the app draws a frame of that size into shared
//! memory and the compositor puts it in the window's tile. Move and resize
//! requests are ignored; title bars are the compositor's (xdg-decoration,
//! server side).
//!
//! Globals: wl_compositor, wl_subcompositor, wl_shm, wl_output, wl_seat
//! (pointer, keyboard), xdg_wm_base (toplevels, popups), the decoration
//! manager, a data device manager that accepts and ignores (no clipboard
//! yet) and cursor shapes. GPU buffers (linux-dmabuf) come later; apps fall
//! back to shared memory.
//!
//! The compositor never waits: sockets are non-blocking and `dispatch` and
//! `flush` handle what is there. Objects a client destroys keep their
//! memory until the client leaves (other objects may still point at them);
//! their pixels and mappings go at once.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("txcore");
const tw = @import("txwidgets");
const wire = @import("wire.zig");
const conn_mod = @import("conn.zig");
const keymap = @import("keymap.zig");
const pos_mod = @import("positioner.zig");
const window_mod = @import("window.zig");
const c = std.c;

pub const Win = window_mod.Win;
pub const Rect = pos_mod.Rect;

/// What the server tells the compositor.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// A new top-level window: the compositor adopts it (and configures it).
    new_window: *const fn (ctx: *anyopaque, surface: tw.Surface, info: WindowInfo) void,
};

pub const WindowInfo = struct {
    pid: i32,
    /// The client's binary (/proc/<pid>/exe), "" when unknown.
    exe: []const u8,
};

pub const Kind = enum {
    display,
    registry,
    callback,
    compositor,
    surface,
    region,
    subcompositor,
    subsurface,
    shm,
    shm_pool,
    buffer,
    output,
    seat,
    pointer,
    keyboard,
    touch,
    wm_base,
    positioner,
    xdg_surface,
    toplevel,
    popup,
    decoration_manager,
    decoration,
    data_device_manager,
    data_source,
    data_device,
    cursor_shape_manager,
    cursor_shape_device,
};

const Global = struct { name: u32, iface: []const u8, version: u32, kind: Kind };

const globals = [_]Global{
    .{ .name = 1, .iface = "wl_compositor", .version = 6, .kind = .compositor },
    .{ .name = 2, .iface = "wl_subcompositor", .version = 1, .kind = .subcompositor },
    .{ .name = 3, .iface = "wl_shm", .version = 1, .kind = .shm },
    .{ .name = 4, .iface = "wl_output", .version = 4, .kind = .output },
    .{ .name = 5, .iface = "wl_seat", .version = 7, .kind = .seat },
    .{ .name = 6, .iface = "xdg_wm_base", .version = 5, .kind = .wm_base },
    .{ .name = 7, .iface = "zxdg_decoration_manager_v1", .version = 1, .kind = .decoration_manager },
    .{ .name = 8, .iface = "wl_data_device_manager", .version = 3, .kind = .data_device_manager },
    .{ .name = 9, .iface = "wp_cursor_shape_manager_v1", .version = 1, .kind = .cursor_shape_manager },
};

pub const Object = struct {
    kind: Kind,
    version: u32,
    /// Surf (surface, subsurface), Pool, Buffer, Positioner, XdgSurf
    /// (xdg_surface, toplevel, popup, decoration).
    ptr: ?*anyopaque = null,
};

pub const Pool = struct {
    fd: c.fd_t,
    map: []align(std.heap.page_size_min) u8,
    /// The pool object and every buffer made from it.
    refs: u32 = 1,

    fn unref(self: *Pool) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        if (self.map.len > 0) _ = c.munmap(self.map.ptr, self.map.len);
        self.map = &.{};
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

pub const Buffer = struct {
    id: u32,
    pool: *Pool,
    offset: i32,
    w: i32,
    h: i32,
    stride: i32,
    format: u32,
    destroyed: bool = false,
};

pub const Surf = struct {
    client: *Client,
    id: u32,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_scale: i32 = 1,
    pending_frames: std.ArrayList(u32) = .empty,
    /// The last committed picture, copied out of the client's buffer.
    pixels: []u32 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,
    /// Frame callbacks waiting for the next presented frame.
    frames: std.ArrayList(u32) = .empty,
    xdg: ?*XdgSurf = null,
    /// As a subsurface: its parent and position in the parent.
    parent: ?*Surf = null,
    x: i32 = 0,
    y: i32 = 0,
    pending_x: i32 = 0,
    pending_y: i32 = 0,
    below: bool = false,
    /// Subsurfaces, bottom to top.
    children: std.ArrayList(*Surf) = .empty,
    entered: bool = false,
    destroyed: bool = false,

    /// Size in logical px.
    pub fn logical(self: *const Surf) struct { w: i32, h: i32 } {
        const s = @max(self.scale, 1);
        return .{ .w = @divTrunc(self.w, s), .h = @divTrunc(self.h, s) };
    }

    fn free(self: *Surf, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.pixels = &.{};
        self.pending_frames.deinit(gpa);
        self.frames.deinit(gpa);
        self.children.deinit(gpa);
    }

    fn detach(self: *Surf) void {
        if (self.parent) |p| {
            for (p.children.items, 0..) |ch, i| {
                if (ch == self) {
                    _ = p.children.orderedRemove(i);
                    break;
                }
            }
        }
        self.parent = null;
    }
};

pub const Role = enum { none, toplevel, popup };

pub const XdgSurf = struct {
    client: *Client,
    surf: *Surf,
    id: u32,
    role: Role = .none,
    role_id: u32 = 0,
    /// The visible part of the surface (no shadows), in surface coordinates.
    geometry: ?Rect = null,
    configure_sent: bool = false,
    initial_commit: bool = false,
    destroyed: bool = false,
    // Toplevel.
    title: std.ArrayList(u8) = .empty,
    app_id: std.ArrayList(u8) = .empty,
    win: ?*Win = null,
    min_w: i32 = 0,
    min_h: i32 = 0,
    // Popup.
    parent: ?*XdgSurf = null,
    pos: pos_mod.Positioner = .{},
    /// Relative to the parent's window geometry.
    rect: Rect = .{},
    grab: bool = false,

    /// The geometry, or the whole surface.
    pub fn geom(self: *const XdgSurf) Rect {
        if (self.geometry) |g| return g;
        const l = self.surf.logical();
        return .{ .w = l.w, .h = l.h };
    }

    /// The toplevel this popup chain belongs to.
    pub fn root(self: *XdgSurf) *XdgSurf {
        var x = self;
        while (x.role == .popup) x = x.parent orelse break;
        return x;
    }

    fn free(self: *XdgSurf, gpa: std.mem.Allocator) void {
        self.title.deinit(gpa);
        self.app_id.deinit(gpa);
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    listen_fd: c.fd_t = -1,
    lock_fd: c.fd_t = -1,
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,
    name_len: usize = 0,
    clients: std.ArrayList(*Client) = .empty,
    hooks: ?Hooks = null,
    serial: u32 = 0,
    out_w: i32 = 1280,
    out_h: i32 = 800,
    out_scale: i32 = 1,
    keymap_text: []const u8 = keymap.us,

    /// Listens on `$XDG_RUNTIME_DIR/wayland-kuroko-N`, the first N free
    /// (a lock file per name, as libwayland does).
    pub fn create(gpa: std.mem.Allocator) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        const base_z = c.getenv("XDG_RUNTIME_DIR") orelse c.getenv("TMPDIR") orelse "/tmp";
        const base = std.mem.trimEnd(u8, std.mem.span(base_z), "/");
        var n: u32 = 0;
        while (n < 10) : (n += 1) {
            const path = try std.fmt.bufPrint(&self.path_buf, "{s}/wayland-kuroko-{d}", .{ base, n });
            var lock_buf: [280]u8 = undefined;
            const lock = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
            const lfd = c.open(lock, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o660));
            if (lfd < 0) continue;
            if (c.flock(lfd, c.LOCK.EX | c.LOCK.NB) != 0) {
                _ = c.close(lfd);
                continue;
            }
            self.lock_fd = lfd;
            self.path_len = path.len;
            self.name_len = path.len - base.len - 1;
            self.listen_fd = try core.ipc.listen(path);
            return self;
        }
        return error.NoFreeSocket;
    }

    /// No socket: clients come in through `addClient` (tests).
    pub fn createForTest(gpa: std.mem.Allocator) !*Server {
        const self = try gpa.create(Server);
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Server) void {
        for (self.clients.items) |cl| cl.destroy();
        self.clients.deinit(self.gpa);
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            core.ipc.unlink(self.path_buf[0..self.path_len]);
        }
        if (self.lock_fd >= 0) _ = c.close(self.lock_fd);
        self.gpa.destroy(self);
    }

    /// For WAYLAND_DISPLAY: the socket's name in the runtime directory.
    pub fn displayName(self: *const Server) []const u8 {
        return self.path_buf[self.path_len - self.name_len .. self.path_len];
    }

    pub fn nextSerial(self: *Server) u32 {
        self.serial +%= 1;
        return self.serial;
    }

    /// The screen apps see (wl_output).
    pub fn setOutput(self: *Server, w: i32, h: i32, scale: i32) void {
        self.out_w = w;
        self.out_h = h;
        self.out_scale = scale;
    }

    pub fn addClient(self: *Server, fd: c.fd_t) !*Client {
        const cl = try self.gpa.create(Client);
        cl.* = .{ .server = self, .conn = .{ .fd = fd } };
        cl.pid = cl.conn.peerPid();
        cl.exe_len = conn_mod.exePath(&cl.exe_buf, cl.pid).len;
        try cl.objects.put(self.gpa, 1, .{ .kind = .display, .version = 1 });
        try self.clients.append(self.gpa, cl);
        return cl;
    }

    /// Accepts new clients and handles every complete request waiting.
    pub fn dispatch(self: *Server) void {
        if (self.listen_fd >= 0) {
            while (core.ipc.acceptNonBlocking(self.listen_fd) catch null) |fd| {
                _ = self.addClient(fd) catch {
                    _ = c.close(fd);
                    break;
                };
            }
        }
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const cl = self.clients.items[i];
            cl.conn.read(self.gpa);
            cl.handleAll();
            if (cl.conn.dead) {
                cl.destroy();
                _ = self.clients.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn flush(self: *Server) void {
        for (self.clients.items) |cl| cl.conn.flush();
    }

    /// A frame is on screen: frame callbacks are answered.
    pub fn presented(self: *Server, time_ms: u32) void {
        for (self.clients.items) |cl| {
            for (cl.surfs.items) |s| {
                for (s.frames.items) |cb| {
                    cl.callbackDone(cb, time_ms);
                }
                s.frames.clearRetainingCapacity();
            }
        }
        self.flush();
    }

    pub fn clientCount(self: *const Server) usize {
        return self.clients.items.len;
    }
};

pub const Client = struct {
    server: *Server,
    conn: conn_mod.Conn,
    pid: i32 = 0,
    exe_buf: [1024]u8 = undefined,
    exe_len: usize = 0,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    pointers: std.ArrayList(u32) = .empty,
    keyboards: std.ArrayList(u32) = .empty,
    outputs: std.ArrayList(u32) = .empty,
    /// The cursor shape the client asked for (wp_cursor_shape).
    cursor_shape: u32 = 1,
    surfs: std.ArrayList(*Surf) = .empty,
    xdgs: std.ArrayList(*XdgSurf) = .empty,
    buffers: std.ArrayList(*Buffer) = .empty,
    pools: std.ArrayList(*Pool) = .empty,
    positioners: std.ArrayList(*pos_mod.Positioner) = .empty,

    fn gpa(self: *Client) std.mem.Allocator {
        return self.server.gpa;
    }

    pub fn exe(self: *const Client) []const u8 {
        return self.exe_buf[0..self.exe_len];
    }

    fn destroy(self: *Client) void {
        const a = self.gpa();
        // Its windows are gone; the compositor closes them.
        for (self.xdgs.items) |x| {
            if (x.win) |w| w.clientGone();
            x.free(a);
            a.destroy(x);
        }
        for (self.surfs.items) |s| {
            s.free(a);
            a.destroy(s);
        }
        for (self.buffers.items) |b| a.destroy(b);
        for (self.pools.items) |p| {
            if (p.map.len > 0) _ = c.munmap(p.map.ptr, p.map.len);
            if (p.fd >= 0) _ = c.close(p.fd);
            a.destroy(p);
        }
        for (self.positioners.items) |p| a.destroy(p);
        self.surfs.deinit(a);
        self.xdgs.deinit(a);
        self.buffers.deinit(a);
        self.pools.deinit(a);
        self.positioners.deinit(a);
        self.pointers.deinit(a);
        self.keyboards.deinit(a);
        self.outputs.deinit(a);
        self.objects.deinit(a);
        self.conn.deinit(a);
        a.destroy(self);
    }

    // ------------------------------------------------------------ events

    pub fn event(self: *Client, object: u32, opcode: u16) !wire.Writer {
        return wire.Writer.begin(self.gpa(), &self.conn.out, object, opcode);
    }

    fn callbackDone(self: *Client, id: u32, data: u32) void {
        var w = self.event(id, 0) catch return;
        w.uint(data) catch return;
        w.end();
        self.deleteId(id);
    }

    /// The object is gone: the client may reuse its id.
    fn deleteId(self: *Client, id: u32) void {
        _ = self.objects.remove(id);
        var w = self.event(1, 1) catch return;
        w.uint(id) catch return;
        w.end();
    }

    fn postError(self: *Client, object: u32, code: u32, msg: []const u8) void {
        std.log.warn("wayland client {d}: protocol error on object {d}: {s}", .{ self.pid, object, msg });
        if (self.event(1, 0)) |w0| {
            var w = w0;
            w.uint(object) catch {};
            w.uint(code) catch {};
            w.string(msg) catch {};
            w.end();
        } else |_| {}
        self.conn.flush();
        self.conn.dead = true;
    }

    fn newObject(self: *Client, id: u32, kind: Kind, version: u32, ptr: ?*anyopaque) !void {
        if (id == 0 or self.objects.contains(id)) return error.BadId;
        try self.objects.put(self.gpa(), id, .{ .kind = kind, .version = version, .ptr = ptr });
    }

    fn get(self: *Client, id: u32, kind: Kind) ?Object {
        const o = self.objects.get(id) orelse return null;
        return if (o.kind == kind) o else null;
    }

    fn ptrOf(self: *Client, comptime T: type, id: u32, kind: Kind) ?*T {
        const o = self.get(id, kind) orelse return null;
        return @ptrCast(@alignCast(o.ptr orelse return null));
    }

    // ---------------------------------------------------------- requests

    fn handleAll(self: *Client) void {
        var off: usize = 0;
        defer {
            self.conn.in.replaceRangeAssumeCapacity(0, off, &.{});
        }
        while (!self.conn.dead) {
            const rest = self.conn.in.items[off..];
            const h = wire.readHeader(rest) orelse return;
            if (h.size < wire.header_size or h.size % 4 != 0) return self.postError(1, 1, "bad message size");
            if (rest.len < h.size) return;
            var args: wire.Args = .{ .bytes = rest[wire.header_size..h.size] };
            self.handle(h.object, h.opcode, &args) catch |err| {
                return self.postError(h.object, 1, @errorName(err));
            };
            if (args.bad) return self.postError(h.object, 1, "bad arguments");
            off += h.size;
        }
    }

    fn handle(self: *Client, id: u32, op: u16, a: *wire.Args) !void {
        const obj = self.objects.get(id) orelse return error.InvalidObject;
        switch (obj.kind) {
            .display => switch (op) {
                0 => { // sync
                    const cb = a.uint();
                    self.callbackDone(cb, self.server.serial);
                },
                1 => { // get_registry
                    const reg = a.uint();
                    try self.newObject(reg, .registry, 1, null);
                    for (globals) |g| {
                        var w = try self.event(reg, 0);
                        try w.uint(g.name);
                        try w.string(g.iface);
                        try w.uint(g.version);
                        w.end();
                    }
                },
                else => return error.BadOpcode,
            },
            .registry => if (op == 0) try self.bind(a) else return error.BadOpcode,
            .compositor => switch (op) {
                0 => { // create_surface
                    const sid = a.uint();
                    const s = try self.gpa().create(Surf);
                    s.* = .{ .client = self, .id = sid };
                    try self.surfs.append(self.gpa(), s);
                    try self.newObject(sid, .surface, obj.version, s);
                },
                1 => try self.newObject(a.uint(), .region, 1, null),
                else => return error.BadOpcode,
            },
            .region => if (op == 0) self.deleteId(id),
            .surface => try self.surfaceRequest(id, obj, op, a),
            .subcompositor => switch (op) {
                0 => self.deleteId(id),
                1 => { // get_subsurface(id, surface, parent)
                    const sub = a.uint();
                    const s = self.ptrOf(Surf, a.uint(), .surface) orelse return error.InvalidObject;
                    const p = self.ptrOf(Surf, a.uint(), .surface) orelse return error.InvalidObject;
                    if (s == p or s.xdg != null) return error.BadSurface;
                    s.detach();
                    s.parent = p;
                    try p.children.append(self.gpa(), s);
                    try self.newObject(sub, .subsurface, 1, s);
                },
                else => return error.BadOpcode,
            },
            .subsurface => {
                const s: *Surf = @ptrCast(@alignCast(obj.ptr.?));
                switch (op) {
                    0 => {
                        s.detach();
                        self.deleteId(id);
                    },
                    1 => {
                        s.pending_x = a.int();
                        s.pending_y = a.int();
                        // Applied at once (no synchronized commits yet).
                        s.x = s.pending_x;
                        s.y = s.pending_y;
                        self.markDirty(s);
                    },
                    2, 3 => { // place_above, place_below(sibling)
                        const sib = self.ptrOf(Surf, a.uint(), .surface);
                        s.below = op == 3 and sib == s.parent;
                        if (op == 2 and sib == s.parent) s.below = false;
                    },
                    else => {}, // set_sync, set_desync
                }
            },
            .shm => switch (op) {
                0 => try self.createPool(a),
                1 => self.deleteId(id),
                else => return error.BadOpcode,
            },
            .shm_pool => {
                const p: *Pool = @ptrCast(@alignCast(obj.ptr.?));
                switch (op) {
                    0 => { // create_buffer
                        const bid = a.uint();
                        const b = try self.gpa().create(Buffer);
                        b.* = .{ .id = bid, .pool = p, .offset = a.int(), .w = a.int(), .h = a.int(), .stride = a.int(), .format = a.uint() };
                        try self.buffers.append(self.gpa(), b);
                        if (b.format > 1) return error.BadFormat;
                        if (b.w <= 0 or b.h <= 0 or b.stride < b.w * 4 or b.offset < 0) return error.BadBuffer;
                        if (@as(u64, @intCast(b.offset)) + @as(u64, @intCast(b.stride)) * @as(u64, @intCast(b.h)) > p.map.len) return error.BadBuffer;
                        p.refs += 1;
                        try self.newObject(bid, .buffer, 1, b);
                    },
                    1 => {
                        p.unref();
                        self.deleteId(id);
                    },
                    2 => { // resize: map the larger file again
                        const size = a.int();
                        if (size < p.map.len) return error.BadSize;
                        const m = try mapPool(p.fd, @intCast(size));
                        _ = c.munmap(p.map.ptr, p.map.len);
                        p.map = m;
                    },
                    else => return error.BadOpcode,
                }
            },
            .buffer => if (op == 0) {
                const b: *Buffer = @ptrCast(@alignCast(obj.ptr.?));
                if (!b.destroyed) {
                    b.destroyed = true;
                    b.pool.unref();
                }
                self.deleteId(id);
            },
            .output, .keyboard, .touch, .seat => switch (obj.kind) {
                .seat => switch (op) {
                    0 => {
                        const pid = a.uint();
                        try self.newObject(pid, .pointer, obj.version, null);
                        try self.pointers.append(self.gpa(), pid);
                    },
                    1 => try self.getKeyboard(a.uint(), obj.version),
                    2 => try self.newObject(a.uint(), .touch, obj.version, null),
                    3 => self.deleteId(id),
                    else => return error.BadOpcode,
                },
                else => if (op == 0) {
                    removeId(&self.keyboards, id);
                    removeId(&self.outputs, id);
                    self.deleteId(id);
                },
            },
            .pointer => switch (op) {
                0 => { // set_cursor(serial, surface, hx, hy): an image of its own
                    _ = a.uint();
                    const sid = a.uint();
                    if (sid != 0) self.cursor_shape = 1;
                },
                1 => {
                    removeId(&self.pointers, id);
                    self.deleteId(id);
                },
                else => return error.BadOpcode,
            },
            .wm_base => switch (op) {
                0 => self.deleteId(id),
                1 => {
                    const pid = a.uint();
                    const p = try self.gpa().create(pos_mod.Positioner);
                    p.* = .{};
                    try self.positioners.append(self.gpa(), p);
                    try self.newObject(pid, .positioner, obj.version, p);
                },
                2 => { // get_xdg_surface(id, surface)
                    const xid = a.uint();
                    const s = self.ptrOf(Surf, a.uint(), .surface) orelse return error.InvalidObject;
                    if (s.xdg != null or s.parent != null) return error.AlreadyHasRole;
                    const x = try self.gpa().create(XdgSurf);
                    x.* = .{ .client = self, .surf = s, .id = xid };
                    try self.xdgs.append(self.gpa(), x);
                    s.xdg = x;
                    try self.newObject(xid, .xdg_surface, obj.version, x);
                },
                3 => {}, // pong
                else => return error.BadOpcode,
            },
            .positioner => {
                const p: *pos_mod.Positioner = @ptrCast(@alignCast(obj.ptr.?));
                switch (op) {
                    0 => self.deleteId(id),
                    1 => {
                        p.w = a.int();
                        p.h = a.int();
                    },
                    2 => p.anchor_rect = .{ .x = a.int(), .y = a.int(), .w = a.int(), .h = a.int() },
                    3 => p.anchor = @enumFromInt(a.uint()),
                    4 => p.gravity = @enumFromInt(a.uint()),
                    5 => p.adjust = a.uint(),
                    6 => {
                        p.off_x = a.int();
                        p.off_y = a.int();
                    },
                    else => {}, // reactive, parent size, parent configure
                }
            },
            .xdg_surface => try self.xdgSurfaceRequest(id, obj, op, a),
            .toplevel => try self.toplevelRequest(id, obj, op, a),
            .popup => {
                const x: *XdgSurf = @ptrCast(@alignCast(obj.ptr.?));
                switch (op) {
                    0 => {
                        self.unmapPopup(x);
                        x.role_id = 0;
                        self.deleteId(id);
                    },
                    1 => x.grab = true,
                    2 => { // reposition(positioner, token)
                        const p = self.ptrOf(pos_mod.Positioner, a.uint(), .positioner) orelse return error.InvalidObject;
                        const token = a.uint();
                        x.pos = p.*;
                        var w = try self.event(x.role_id, 2);
                        try w.uint(token);
                        w.end();
                        try self.configurePopup(x);
                    },
                    else => return error.BadOpcode,
                }
            },
            .decoration_manager => switch (op) {
                0 => self.deleteId(id),
                1 => { // get_toplevel_decoration(id, toplevel)
                    const did = a.uint();
                    const x = self.ptrOf(XdgSurf, a.uint(), .toplevel) orelse return error.InvalidObject;
                    try self.newObject(did, .decoration, 1, x);
                    try self.sendDecoration(did);
                },
                else => return error.BadOpcode,
            },
            .decoration => switch (op) {
                0 => self.deleteId(id),
                // Whatever the client asks, the compositor draws the frame.
                else => {
                    if (op == 1) _ = a.uint();
                    try self.sendDecoration(id);
                },
            },
            .data_device_manager => switch (op) {
                0 => try self.newObject(a.uint(), .data_source, obj.version, null),
                1 => try self.newObject(a.uint(), .data_device, obj.version, null),
                else => return error.BadOpcode,
            },
            .data_source => if (op == 1) self.deleteId(id),
            .data_device => if (op == 2) self.deleteId(id),
            .cursor_shape_manager => switch (op) {
                0 => self.deleteId(id),
                1, 2 => {
                    const did = a.uint();
                    _ = a.uint();
                    try self.newObject(did, .cursor_shape_device, 1, null);
                },
                else => return error.BadOpcode,
            },
            .cursor_shape_device => switch (op) {
                0 => self.deleteId(id),
                1 => {
                    _ = a.uint();
                    self.cursor_shape = a.uint();
                },
                else => return error.BadOpcode,
            },
            .callback => {},
        }
    }

    fn removeId(list: *std.ArrayList(u32), id: u32) void {
        for (list.items, 0..) |x, i| {
            if (x == id) {
                _ = list.swapRemove(i);
                return;
            }
        }
    }

    fn bind(self: *Client, a: *wire.Args) !void {
        const name = a.uint();
        const iface = a.string() orelse return error.BadInterface;
        const version = a.uint();
        const id = a.uint();
        const g = for (globals) |g| {
            if (g.name == name) break g;
        } else return error.NoSuchGlobal;
        if (!std.mem.eql(u8, iface, g.iface) or version == 0) return error.BadInterface;
        const v = @min(version, g.version);
        try self.newObject(id, g.kind, v, null);
        const srv = self.server;
        switch (g.kind) {
            .shm => for ([_]u32{ 0, 1 }) |fmt| { // ARGB8888, XRGB8888
                var w = try self.event(id, 0);
                try w.uint(fmt);
                w.end();
            },
            .output => {
                try self.outputs.append(self.gpa(), id);
                var w = try self.event(id, 0); // geometry
                try w.int(0);
                try w.int(0);
                try w.int(@divTrunc(srv.out_w * 254, 960)); // ~96 dpi
                try w.int(@divTrunc(srv.out_h * 254, 960));
                try w.int(0);
                try w.string("Kuroko");
                try w.string("Screen");
                try w.int(0);
                w.end();
                w = try self.event(id, 1); // mode: current, preferred
                try w.uint(3);
                try w.int(srv.out_w * srv.out_scale);
                try w.int(srv.out_h * srv.out_scale);
                try w.int(60000);
                w.end();
                if (v >= 2) {
                    w = try self.event(id, 3);
                    try w.int(srv.out_scale);
                    w.end();
                }
                if (v >= 4) {
                    w = try self.event(id, 4);
                    try w.string("TX-1");
                    w.end();
                }
                if (v >= 2) {
                    w = try self.event(id, 2);
                    w.end();
                }
            },
            .seat => {
                var w = try self.event(id, 0);
                try w.uint(3); // pointer | keyboard
                w.end();
                if (v >= 2) {
                    w = try self.event(id, 1);
                    try w.string("seat0");
                    w.end();
                }
            },
            else => {},
        }
    }

    fn getKeyboard(self: *Client, id: u32, version: u32) !void {
        try self.newObject(id, .keyboard, version, null);
        try self.keyboards.append(self.gpa(), id);
        const f = try keymap.file(self.server.keymap_text);
        try self.conn.queueFd(self.gpa(), f.fd);
        var w = try self.event(id, 0);
        try w.uint(1); // xkb_v1
        try w.uint(f.size);
        w.end();
        if (version >= 4) {
            w = try self.event(id, 5); // repeat_info: 25/s after 400 ms
            try w.int(25);
            try w.int(400);
            w.end();
        }
        // A focused window of this client gets the keyboard at once.
        for (self.xdgs.items) |x| {
            if (x.win) |win| if (win.state.focused) win.keyboardEnter(id);
        }
    }

    fn createPool(self: *Client, a: *wire.Args) !void {
        const id = a.uint();
        const fd = self.conn.takeFd() orelse return error.MissingFd;
        errdefer _ = c.close(fd);
        const size = a.int();
        if (size <= 0) return error.BadSize;
        const m = try mapPool(fd, @intCast(size));
        const p = try self.gpa().create(Pool);
        p.* = .{ .fd = fd, .map = m };
        try self.pools.append(self.gpa(), p);
        try self.newObject(id, .shm_pool, 1, p);
    }

    fn mapPool(fd: c.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
        // The file must really be this large, or reading it would fault.
        const end = c.lseek(fd, 0, c.SEEK.END);
        if (end < 0 or @as(u64, @intCast(end)) < size) return error.BadPool;
        const p = c.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (p == c.MAP_FAILED) return error.MapFailed;
        const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
        return base[0..size];
    }

    // ----------------------------------------------------------- surface

    fn surfaceRequest(self: *Client, id: u32, obj: Object, op: u16, a: *wire.Args) !void {
        const s: *Surf = @ptrCast(@alignCast(obj.ptr.?));
        switch (op) {
            0 => { // destroy
                s.destroyed = true;
                s.detach();
                self.gpa().free(s.pixels);
                s.pixels = &.{};
                s.w = 0;
                s.h = 0;
                self.deleteId(id);
            },
            1 => { // attach(buffer, x, y)
                const bid = a.uint();
                _ = a.int();
                _ = a.int();
                s.pending_attach = true;
                s.pending_buffer = if (bid == 0) null else (self.ptrOf(Buffer, bid, .buffer) orelse return error.InvalidObject);
            },
            2, 9 => { // damage, damage_buffer: the whole picture is copied anyway
                for (0..4) |_| _ = a.int();
            },
            3 => {
                const cb = a.uint();
                try self.newObject(cb, .callback, 1, null);
                try s.pending_frames.append(self.gpa(), cb);
            },
            4, 5 => _ = a.uint(), // opaque and input regions
            6 => try self.commit(s),
            7 => _ = a.int(), // transform: normal only
            8 => {
                const sc = a.int();
                if (sc < 1) return error.BadScale;
                s.pending_scale = sc;
            },
            10 => { // offset
                _ = a.int();
                _ = a.int();
            },
            else => return error.BadOpcode,
        }
    }

    fn commit(self: *Client, s: *Surf) !void {
        const g = self.gpa();
        if (s.pending_attach) {
            s.pending_attach = false;
            if (s.pending_buffer) |b| {
                if (!b.destroyed) {
                    copyBuffer(g, s, b) catch |err| return err;
                    // The pixels are ours now: the client may reuse it.
                    var w = try self.event(b.id, 0);
                    w.end();
                }
            } else {
                g.free(s.pixels);
                s.pixels = &.{};
                s.w = 0;
                s.h = 0;
            }
            s.pending_buffer = null;
        }
        s.scale = s.pending_scale;
        try s.frames.appendSlice(g, s.pending_frames.items);
        s.pending_frames.clearRetainingCapacity();
        if (s.w > 0 and !s.entered) {
            s.entered = true;
            for (self.outputs.items) |o| {
                var w = try self.event(s.id, 0);
                try w.uint(o);
                w.end();
            }
        }
        if (s.xdg) |x| try self.xdgCommit(x);
        self.markDirty(s);
    }

    fn copyBuffer(gpa_: std.mem.Allocator, s: *Surf, b: *Buffer) !void {
        const p = b.pool;
        const need = @as(usize, @intCast(b.offset)) + @as(usize, @intCast(b.stride)) * @as(usize, @intCast(b.h));
        if (need > p.map.len) return error.BadBuffer;
        const n: usize = @intCast(b.w * b.h);
        if (s.pixels.len != n) s.pixels = try gpa_.realloc(s.pixels, n);
        s.w = b.w;
        s.h = b.h;
        const opaque_ = b.format == 1;
        var y: usize = 0;
        while (y < b.h) : (y += 1) {
            const row = p.map[@as(usize, @intCast(b.offset)) + y * @as(usize, @intCast(b.stride)) ..][0 .. @as(usize, @intCast(b.w)) * 4];
            const dst = s.pixels[y * @as(usize, @intCast(b.w)) ..][0..@intCast(b.w)];
            for (dst, 0..) |*px, i| {
                const v = std.mem.readInt(u32, row[i * 4 ..][0..4], .little);
                px.* = if (opaque_) v | 0xFF000000 else v;
            }
        }
    }

    /// New content: the window it belongs to is drawn again.
    fn markDirty(self: *Client, s: *Surf) void {
        _ = self;
        var top = s;
        while (top.parent) |p| top = p;
        const x = top.xdg orelse return;
        if (x.root().win) |w| w.dirty = true;
    }

    // ---------------------------------------------------------------- xdg

    fn xdgSurfaceRequest(self: *Client, id: u32, obj: Object, op: u16, a: *wire.Args) !void {
        const x: *XdgSurf = @ptrCast(@alignCast(obj.ptr.?));
        switch (op) {
            0 => {
                x.destroyed = true;
                x.surf.xdg = null;
                self.deleteId(id);
            },
            1 => { // get_toplevel
                const tid = a.uint();
                if (x.role != .none) return error.AlreadyHasRole;
                x.role = .toplevel;
                x.role_id = tid;
                try self.newObject(tid, .toplevel, obj.version, x);
                if (obj.version >= 5) {
                    // What the compositor does: maximize, full screen, minimize.
                    var w = try self.event(tid, 3);
                    const caps = [_]u32{ 2, 3, 4 };
                    try w.array(std.mem.sliceAsBytes(&caps));
                    w.end();
                }
            },
            2 => { // get_popup(id, parent, positioner)
                const pid = a.uint();
                const parent_id = a.uint();
                const p = self.ptrOf(pos_mod.Positioner, a.uint(), .positioner) orelse return error.InvalidObject;
                if (x.role != .none) return error.AlreadyHasRole;
                x.role = .popup;
                x.role_id = pid;
                x.pos = p.*;
                x.parent = if (parent_id == 0) null else (self.ptrOf(XdgSurf, parent_id, .xdg_surface) orelse return error.InvalidObject);
                try self.newObject(pid, .popup, obj.version, x);
            },
            3 => {
                x.geometry = .{ .x = a.int(), .y = a.int(), .w = a.int(), .h = a.int() };
                self.markDirty(x.surf);
            },
            4 => _ = a.uint(), // ack_configure
            else => return error.BadOpcode,
        }
    }

    fn toplevelRequest(self: *Client, id: u32, obj: Object, op: u16, a: *wire.Args) !void {
        const x: *XdgSurf = @ptrCast(@alignCast(obj.ptr.?));
        const g = self.gpa();
        switch (op) {
            0 => {
                if (x.win) |w| w.clientGone();
                x.win = null;
                x.role_id = 0;
                self.deleteId(id);
            },
            2 => {
                x.title.clearRetainingCapacity();
                try x.title.appendSlice(g, a.string() orelse "");
                if (x.win) |w| w.dirty = true;
            },
            3 => {
                x.app_id.clearRetainingCapacity();
                try x.app_id.appendSlice(g, a.string() orelse "");
            },
            8 => {
                x.min_w = a.int();
                x.min_h = a.int();
            },
            // Maximize, full screen, minimize, move, resize, window menu:
            // the compositor decides. The client gets its current state.
            9, 10, 12, 13 => if (x.win) |w| w.sendConfigure(),
            11 => {
                _ = a.uint();
                if (x.win) |w| w.sendConfigure();
            },
            else => {}, // set_parent, show_window_menu, move, resize, set_max_size
        }
    }

    fn xdgCommit(self: *Client, x: *XdgSurf) !void {
        if (x.destroyed) return;
        switch (x.role) {
            .none => {},
            .toplevel => {
                if (!x.initial_commit) {
                    x.initial_commit = true;
                    const win = try Win.create(self.server, x);
                    x.win = win;
                    if (self.server.hooks) |h| {
                        h.new_window(h.ctx, win.surface(), .{ .pid = self.pid, .exe = self.exe() });
                    }
                    // Not configured by the compositor yet: let the app pick.
                    if (!x.configure_sent) win.sendConfigure();
                }
            },
            .popup => {
                if (!x.initial_commit) {
                    x.initial_commit = true;
                    try self.configurePopup(x);
                }
            },
        }
    }

    /// Places a popup and tells it where it is.
    fn configurePopup(self: *Client, x: *XdgSurf) !void {
        const parent = x.parent orelse return;
        const root = x.root();
        // Popups stay inside the window's content.
        var bounds: Rect = .{ .w = self.server.out_w, .h = self.server.out_h };
        var ox: i32 = 0;
        var oy: i32 = 0;
        if (root.win) |w| {
            bounds = .{ .w = w.size.w, .h = w.size.h };
            if (!w.hasPopup(x)) try w.popups.append(self.gpa(), x);
            const o = w.originOf(parent);
            ox = o.x;
            oy = o.y;
        }
        // Bounds in the parent's geometry coordinates.
        bounds.x -= ox;
        bounds.y -= oy;
        x.rect = x.pos.place(bounds);
        var w = try self.event(x.role_id, 0);
        try w.int(x.rect.x);
        try w.int(x.rect.y);
        try w.int(x.rect.w);
        try w.int(x.rect.h);
        w.end();
        w = try self.event(x.id, 0);
        try w.uint(self.server.nextSerial());
        w.end();
        x.configure_sent = true;
        if (root.win) |win| win.dirty = true;
    }

    fn unmapPopup(self: *Client, x: *XdgSurf) void {
        _ = self;
        const root = x.root();
        if (root.win) |w| w.removePopup(x);
        x.role = .none;
    }

    fn sendDecoration(self: *Client, id: u32) !void {
        var w = try self.event(id, 0);
        try w.uint(2); // server_side
        w.end();
    }
};
