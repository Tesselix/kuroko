//! Unix-socket helpers shared by the compositor and desktop services.
//!
//! Sockets live in `$XDG_RUNTIME_DIR/tesselix/` (mode 0700). macOS has no
//! XDG_RUNTIME_DIR, so the simulator falls back to `$TMPDIR/tesselix/`,
//! which macOS already makes per-user.
//!
//! These calls go straight to libc: the compositor needs non-blocking
//! sockets inside its own event loop, and std.Io's networking (Zig 0.16)
//! blocks the calling task. Every Tesselix process links libc anyway
//! (wlroots, SDL3).
//!
//! TODO(linux): check peers with SO_PEERCRED (Tessel Store, Authorization).

const std = @import("std");
const c = std.c;

pub const compositor_socket = "compositor.sock";

pub const Fd = c.fd_t;

pub const Error = error{
    WouldBlock,
    Closed,
    NameTooLong,
    SystemError,
};

fn errno() c.E {
    return c.errno(@as(c_int, -1));
}

fn toZ(buf: []u8, s: []const u8) ![:0]const u8 {
    if (s.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Writes "<runtime dir>/tesselix/<name>" into `buf` and creates the
/// directory with mode 0700 if needed.
pub fn socketPath(buf: []u8, name: []const u8) ![]const u8 {
    const base_z = c.getenv("XDG_RUNTIME_DIR") orelse c.getenv("TMPDIR") orelse "/tmp";
    const base = std.mem.trimEnd(u8, std.mem.span(base_z), "/");
    const dir_len = base.len + "/tesselix".len;
    if (dir_len + 2 + name.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..dir_len], "/tesselix");
    buf[dir_len] = 0;
    const dir_z: [*:0]const u8 = buf[0..dir_len :0];
    _ = c.mkdir(dir_z, 0o700); // EEXIST is fine
    _ = c.chmod(dir_z, 0o700);
    buf[dir_len] = '/';
    @memcpy(buf[dir_len + 1 ..][0..name.len], name);
    return buf[0 .. dir_len + 1 + name.len];
}

pub fn setNonBlocking(fd: Fd) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SystemError;
    var o: c.O = @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(c.O)), @intCast(flags)));
    o.NONBLOCK = true;
    const v: c_int = @intCast(@as(std.meta.Int(.unsigned, @bitSizeOf(c.O)), @bitCast(o)));
    if (c.fcntl(fd, c.F.SETFL, v) < 0) return error.SystemError;
}

/// Writing to a socket whose peer died must return an error, never kill
/// the compositor with SIGPIPE.
pub fn ignoreSigpipe() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

fn unixAddr(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// A non-blocking listening socket. Removes a stale socket file first.
pub fn listen(path: []const u8) !Fd {
    var zbuf: [512]u8 = undefined;
    _ = c.unlink(try toZ(&zbuf, path));
    const addr = try unixAddr(path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemError;
    errdefer close(fd);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.SystemError;
    if (c.listen(fd, 8) != 0) return error.SystemError;
    try setNonBlocking(fd);
    return fd;
}

/// Accepts one pending connection, or null if none is waiting.
pub fn acceptNonBlocking(fd: Fd) !?Fd {
    const conn = c.accept(fd, null, null);
    if (conn < 0) {
        return switch (errno()) {
            .AGAIN, .INTR, .CONNABORTED => null,
            else => error.SystemError,
        };
    }
    try setNonBlocking(conn);
    return conn;
}

pub fn connect(path: []const u8) !Fd {
    const addr = try unixAddr(path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemError;
    errdefer close(fd);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.SystemError;
    return fd;
}

/// Writes what the socket accepts now; WouldBlock if nothing fits.
pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    const n = c.write(fd, bytes.ptr, bytes.len);
    if (n < 0) {
        return switch (errno()) {
            .AGAIN, .INTR => error.WouldBlock,
            .PIPE, .CONNRESET => error.Closed,
            else => error.SystemError,
        };
    }
    return @intCast(n);
}

/// Blocking read; 0 means the peer closed the connection.
pub fn read(fd: Fd, buf: []u8) Error!usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        switch (errno()) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return 0,
            else => return error.SystemError,
        }
    }
}

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

pub fn unlink(path: []const u8) void {
    var zbuf: [512]u8 = undefined;
    const z = toZ(&zbuf, path) catch return;
    _ = c.unlink(z);
}

test "socket round trip" {
    var buf: [512]u8 = undefined;
    const path = try socketPath(&buf, "ipc-test.sock");
    const server = try listen(path);
    defer {
        close(server);
        unlink(path);
    }
    try std.testing.expect((try acceptNonBlocking(server)) == null);
    const client = try connect(path);
    defer close(client);
    var conn: ?Fd = null;
    var tries: usize = 0;
    while (conn == null and tries < 1000) : (tries += 1) conn = try acceptNonBlocking(server);
    defer close(conn.?);
    _ = try write(conn.?, "hello");
    var rb: [16]u8 = undefined;
    const n = try read(client, &rb);
    try std.testing.expectEqualStrings("hello", rb[0..n]);
}
