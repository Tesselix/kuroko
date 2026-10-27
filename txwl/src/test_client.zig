//! A minimal Wayland client for tests: it talks to the server over a socket
//! pair the way an app would, and records the events it gets.

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const wire = @import("wire.zig");
const conn_mod = @import("conn.zig");
const server_mod = @import("server.zig");
const c = std.c;

const Event = struct { object: u32, opcode: u16, args: []u8 };

const TestClient = struct {
    gpa: std.mem.Allocator,
    conn: conn_mod.Conn,
    next_id: u32 = 2,
    events: std.ArrayList(Event) = .empty,
    fds: std.ArrayList(c.fd_t) = .empty,

    fn deinit(self: *TestClient) void {
        for (self.events.items) |e| self.gpa.free(e.args);
        self.events.deinit(self.gpa);
        for (self.fds.items) |f| _ = c.close(f);
        self.fds.deinit(self.gpa);
        self.conn.deinit(self.gpa);
    }

    fn id(self: *TestClient) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    fn req(self: *TestClient, object: u32, op: u16) !wire.Writer {
        return wire.Writer.begin(self.gpa, &self.conn.out, object, op);
    }

    fn send(self: *TestClient, object: u32, op: u16, args: anytype) !void {
        var w = try self.req(object, op);
        inline for (args) |arg| {
            switch (@TypeOf(arg)) {
                u32, comptime_int => try w.uint(arg),
                i32 => try w.int(arg),
                []const u8 => try w.string(arg),
                else => @compileError("argument"),
            }
        }
        w.end();
        self.conn.flush();
    }

    /// Reads what the server sent.
    fn pump(self: *TestClient) !void {
        self.conn.read(self.gpa);
        while (self.conn.takeFd()) |f| try self.fds.append(self.gpa, f);
        var off: usize = 0;
        while (wire.readHeader(self.conn.in.items[off..])) |h| {
            if (self.conn.in.items.len - off < h.size) break;
            try self.events.append(self.gpa, .{
                .object = h.object,
                .opcode = h.opcode,
                .args = try self.gpa.dupe(u8, self.conn.in.items[off + 8 .. off + h.size]),
            });
            off += h.size;
        }
        self.conn.in.replaceRangeAssumeCapacity(0, off, &.{});
    }

    fn find(self: *TestClient, object: u32, opcode: u16) ?wire.Args {
        var i = self.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.events.items[i];
            if (e.object == object and e.opcode == opcode) return .{ .bytes = e.args };
        }
        return null;
    }

    fn count(self: *TestClient, object: u32, opcode: u16) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e.object == object and e.opcode == opcode) n += 1;
        }
        return n;
    }

    /// The name a global was announced under.
    fn global(self: *TestClient, registry: u32, iface: []const u8) ?u32 {
        for (self.events.items) |e| {
            if (e.object != registry or e.opcode != 0) continue;
            var a: wire.Args = .{ .bytes = e.args };
            const name = a.uint();
            if (std.mem.eql(u8, a.string() orelse "", iface)) return name;
        }
        return null;
    }

    fn bind(self: *TestClient, registry: u32, iface: []const u8, version: u32) !u32 {
        const name = self.global(registry, iface) orelse return error.NoGlobal;
        const nid = self.id();
        var w = try self.req(registry, 0);
        try w.uint(name);
        try w.string(iface);
        try w.uint(version);
        try w.uint(nid);
        w.end();
        self.conn.flush();
        return nid;
    }
};

const Adopted = struct {
    surface: ?tw.Surface = null,
    info: server_mod.WindowInfo = .{ .pid = 0, .exe = "" },

    fn newWindow(ctx: *anyopaque, s: tw.Surface, info: server_mod.WindowInfo) void {
        const self: *Adopted = @ptrCast(@alignCast(ctx));
        self.surface = s;
        self.info = info;
        // The compositor gives its size and state at once.
        s.configure(.{ .w = 40, .h = 20 }, 1);
        s.windowState(.{ .focused = true, .tiled = true });
    }
};

fn shmFile(size: usize, color: u32) !c.fd_t {
    var name = "/tmp/txwl-test-XXXXXX".*;
    const fd = mkstemp(&name);
    if (fd < 0) return error.TempFile;
    _ = c.unlink(&name);
    var px: [4]u8 = undefined;
    std.mem.writeInt(u32, &px, color, .little);
    var i: usize = 0;
    while (i < size) : (i += 4) _ = c.write(fd, &px, 4);
    return fd;
}

extern "c" fn mkstemp(template: [*:0]u8) c_int;

test "an app's window: configure, draw, input, popup, close" {
    const gpa = std.testing.allocator;
    const srv = try server_mod.Server.createForTest(gpa);
    defer srv.destroy();
    var adopted: Adopted = .{};
    srv.hooks = .{ .ctx = &adopted, .new_window = Adopted.newWindow };

    const pair = try conn_mod.testPair();
    _ = try srv.addClient(pair[0]);
    var cl: TestClient = .{ .gpa = gpa, .conn = .{ .fd = pair[1] } };
    defer cl.deinit();

    // Registry and globals.
    const registry = cl.id();
    try cl.send(1, 1, .{registry});
    srv.dispatch();
    srv.flush();
    try cl.pump();
    const comp = try cl.bind(registry, "wl_compositor", 6);
    const shm = try cl.bind(registry, "wl_shm", 1);
    const seat = try cl.bind(registry, "wl_seat", 7);
    const wm = try cl.bind(registry, "xdg_wm_base", 5);
    const subcomp = try cl.bind(registry, "wl_subcompositor", 1);
    const deco_mgr = try cl.bind(registry, "zxdg_decoration_manager_v1", 1);
    _ = try cl.bind(registry, "wl_output", 4);

    // A window, the way every app opens one.
    const surface = cl.id();
    try cl.send(comp, 0, .{surface});
    const xdg = cl.id();
    try cl.send(wm, 2, .{ xdg, surface });
    const toplevel = cl.id();
    try cl.send(xdg, 1, .{toplevel});
    try cl.send(toplevel, 2, .{@as([]const u8, "Test window")});
    const deco = cl.id();
    try cl.send(deco_mgr, 1, .{ deco, toplevel });
    const pointer = cl.id();
    try cl.send(seat, 0, .{pointer});
    const keyboard = cl.id();
    try cl.send(seat, 1, .{keyboard});
    try cl.send(surface, 6, .{}); // initial commit, no buffer
    srv.dispatch();
    srv.flush();
    try cl.pump();

    // The compositor adopted it and set its size; the frame is ours.
    const s = adopted.surface orelse return error.NotAdopted;
    defer s.destroy();
    try std.testing.expectEqualStrings("Test window", s.title());
    var cfg = cl.find(toplevel, 0) orelse return error.NoConfigure;
    try std.testing.expectEqual(@as(i32, 40), cfg.int());
    try std.testing.expectEqual(@as(i32, 20), cfg.int());
    const states = std.mem.bytesAsSlice(u32, @as([]align(1) const u8, cfg.array()));
    var activated = false;
    for (states) |st| {
        if (st == 4) activated = true;
    }
    try std.testing.expect(activated);
    try std.testing.expect(cl.find(xdg, 0) != null); // xdg_surface.configure
    var dm = cl.find(deco, 0).?;
    try std.testing.expectEqual(@as(u32, 2), dm.uint()); // server-side frame
    try std.testing.expect(cl.find(keyboard, 0) != null); // keymap
    try std.testing.expect(cl.fds.items.len == 1); // its file
    try std.testing.expect(cl.find(keyboard, 1) != null); // enter: focused

    // A 40x20 frame, all one color, through shared memory.
    const fd = try shmFile(40 * 20 * 4, 0xFF336699);
    {
        var w = try cl.req(shm, 0);
        const pool = cl.next_id;
        try w.uint(cl.id());
        try w.int(40 * 20 * 4);
        w.end();
        try cl.conn.queueFd(gpa, fd);
        cl.conn.flush();
        const buffer = cl.id();
        try cl.send(pool, 0, .{ buffer, @as(i32, 0), @as(i32, 40), @as(i32, 20), @as(i32, 160), @as(u32, 1) });
        try cl.send(surface, 1, .{ buffer, @as(i32, 0), @as(i32, 0) });
        const frame_cb = cl.id();
        try cl.send(surface, 3, .{frame_cb});
        try cl.send(surface, 6, .{});
        srv.dispatch();
        srv.flush();
        try cl.pump();
        try std.testing.expect(cl.find(buffer, 0) != null); // released at once
        try std.testing.expect(s.tick(0)); // needs drawing

        var px: [40 * 20]u32 = @splat(0);
        var cv = tw.Canvas.init(&px, 40, 20, 40, 1);
        s.draw(&cv);
        try std.testing.expectEqual(@as(u32, 0xFF336699), px[0]);
        try std.testing.expectEqual(@as(u32, 0xFF336699), px[40 * 20 - 1]);

        srv.presented(1234);
        try cl.pump();
        var done = cl.find(frame_cb, 0) orelse return error.NoFrameDone;
        try std.testing.expectEqual(@as(u32, 1234), done.uint());
    }

    // Pointer: enter, motion, button, in surface coordinates.
    s.input(.{ .pointer_motion = .{ .x = 5, .y = 6 } }, 10 * std.time.ns_per_ms);
    s.input(.{ .pointer_motion = .{ .x = 7, .y = 6 } }, 11 * std.time.ns_per_ms);
    s.input(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 7, .y = 6 } }, 12 * std.time.ns_per_ms);
    srv.flush();
    try cl.pump();
    var enter = cl.find(pointer, 0) orelse return error.NoEnter;
    _ = enter.uint();
    try std.testing.expectEqual(surface, enter.uint());
    try std.testing.expectEqual(@as(f32, 5), enter.fixed());
    var motion = cl.find(pointer, 2).?;
    _ = motion.uint();
    try std.testing.expectEqual(@as(f32, 7), motion.fixed());
    var button = cl.find(pointer, 3).?;
    _ = button.uint();
    _ = button.uint();
    try std.testing.expectEqual(@as(u32, 0x110), button.uint());
    try std.testing.expectEqual(@as(u32, 1), button.uint());

    // Keyboard: key codes, not characters.
    s.input(.{ .key = .{ .key = .a, .pressed = true, .mods = .{ .shift = true }, .code = 30 } }, 20 * std.time.ns_per_ms);
    srv.flush();
    try cl.pump();
    var key = cl.find(keyboard, 3) orelse return error.NoKey;
    _ = key.uint();
    _ = key.uint();
    try std.testing.expectEqual(@as(u32, 30), key.uint());
    var mods = cl.find(keyboard, 4).?;
    _ = mods.uint();
    try std.testing.expectEqual(@as(u32, 1), mods.uint()); // shift

    // A subsurface under the pointer (Chrome draws its notifications so)
    // is destroyed by the app: the pointer moving on must not name it in
    // a leave, since its id is free (libwayland ends the app on that).
    {
        const sub_surface = cl.id();
        try cl.send(comp, 0, .{sub_surface});
        const sub = cl.id();
        try cl.send(subcomp, 1, .{ sub, sub_surface, surface });
        try cl.send(sub, 1, .{ @as(i32, 20), @as(i32, 5) });
        const sub_fd = try shmFile(10 * 10 * 4, 0xFFCC3300);
        var w = try cl.req(shm, 0);
        const pool = cl.next_id;
        try w.uint(cl.id());
        try w.int(10 * 10 * 4);
        w.end();
        try cl.conn.queueFd(gpa, sub_fd);
        cl.conn.flush();
        const buffer = cl.id();
        try cl.send(pool, 0, .{ buffer, @as(i32, 0), @as(i32, 10), @as(i32, 10), @as(i32, 40), @as(u32, 1) });
        try cl.send(sub_surface, 1, .{ buffer, @as(i32, 0), @as(i32, 0) });
        try cl.send(sub_surface, 6, .{});
        srv.dispatch();
        s.input(.{ .pointer_motion = .{ .x = 25, .y = 8 } }, 21 * std.time.ns_per_ms);
        srv.flush();
        try cl.pump();
        var sub_enter = cl.find(pointer, 0) orelse return error.NoEnter;
        _ = sub_enter.uint();
        try std.testing.expectEqual(sub_surface, sub_enter.uint());

        try cl.send(sub, 0, .{});
        try cl.send(sub_surface, 0, .{});
        srv.dispatch();
        const before = cl.events.items.len;
        s.input(.{ .pointer_motion = .{ .x = 3, .y = 3 } }, 22 * std.time.ns_per_ms);
        srv.flush();
        try cl.pump();
        for (cl.events.items[before..]) |e| {
            if (e.object != pointer or e.opcode != 1) continue;
            var a: wire.Args = .{ .bytes = e.args };
            _ = a.uint();
            try std.testing.expect(a.uint() != sub_surface);
        }
        var back = cl.find(pointer, 0) orelse return error.NoEnter;
        _ = back.uint();
        try std.testing.expectEqual(surface, back.uint());
    }

    // A popup menu under (2, 2), grabbing; a click outside closes it.
    const pop_surface = cl.id();
    try cl.send(comp, 0, .{pop_surface});
    const pop_xdg = cl.id();
    try cl.send(wm, 2, .{ pop_xdg, pop_surface });
    const positioner = cl.id();
    try cl.send(wm, 1, .{positioner});
    try cl.send(positioner, 1, .{ @as(i32, 10), @as(i32, 8) });
    try cl.send(positioner, 2, .{ @as(i32, 2), @as(i32, 2), @as(i32, 1), @as(i32, 1) });
    try cl.send(positioner, 3, .{@as(u32, 8)}); // anchor bottom_right
    try cl.send(positioner, 4, .{@as(u32, 8)}); // gravity bottom_right
    const popup = cl.id();
    try cl.send(pop_xdg, 2, .{ popup, xdg, positioner });
    try cl.send(popup, 1, .{ seat, @as(u32, 0) }); // grab
    try cl.send(pop_surface, 6, .{});
    srv.dispatch();
    srv.flush();
    try cl.pump();
    var pc = cl.find(popup, 0) orelse return error.NoPopupConfigure;
    try std.testing.expectEqual(@as(i32, 3), pc.int());
    try std.testing.expectEqual(@as(i32, 3), pc.int());
    s.input(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 35, .y = 18 } }, 30 * std.time.ns_per_ms);
    srv.flush();
    try cl.pump();
    try std.testing.expect(cl.find(popup, 1) != null); // popup_done

    // The user closes the window: the app is asked, the window stays.
    try std.testing.expect(s.requestClose());
    srv.flush();
    try cl.pump();
    try std.testing.expect(cl.find(toplevel, 1) != null); // close
    try std.testing.expect(!s.wantsClose());
    // The app goes away: now the compositor may close the window.
    cl.conn.deinit(gpa);
    cl.conn = .{ .fd = -1 };
    srv.dispatch();
    try std.testing.expect(s.wantsClose());
    try std.testing.expectEqual(@as(usize, 0), srv.clientCount());
}
