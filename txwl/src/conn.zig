//! One client's socket: non-blocking reads and writes, with file
//! descriptors passed beside the bytes (SCM_RIGHTS), and the peer's process
//! id. The compositor never waits: a write that does not fit stays queued;
//! a client that stops reading and fills the queue is disconnected.
//!
//! libc directly (std.Io blocks the calling task; see txcore/src/ipc.zig).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Fd = c.fd_t;

/// Most fds one sendmsg carries (libwayland's limit).
const max_fds_out = 28;
/// A client that lets this much pile up unread is dropped.
const max_out = 4 * 1024 * 1024;

const is_linux = builtin.os.tag == .linux;

/// The control-message header (struct cmsghdr): size_t length on Linux,
/// socklen_t on the BSDs and macOS; the data is aligned to that size.
const CmsgLen = if (is_linux) usize else u32;
const cmsg_align = @sizeOf(CmsgLen);
const cmsg_hdr = std.mem.alignForward(usize, @sizeOf(CmsgLen) + 2 * @sizeOf(c_int), cmsg_align);

fn cmsgSpace(n: usize) usize {
    return cmsg_hdr + std.mem.alignForward(usize, n, cmsg_align);
}

pub const Conn = struct {
    fd: Fd,
    in: std.ArrayList(u8) = .empty,
    in_fds: std.ArrayList(Fd) = .empty,
    out: std.ArrayList(u8) = .empty,
    out_fds: std.ArrayList(Fd) = .empty,
    dead: bool = false,

    pub fn deinit(self: *Conn, gpa: std.mem.Allocator) void {
        _ = c.close(self.fd);
        for (self.in_fds.items) |f| _ = c.close(f);
        for (self.out_fds.items) |f| _ = c.close(f);
        self.in.deinit(gpa);
        self.in_fds.deinit(gpa);
        self.out.deinit(gpa);
        self.out_fds.deinit(gpa);
    }

    /// Reads everything available now. Marks the connection dead when the
    /// peer closed it.
    pub fn read(self: *Conn, gpa: std.mem.Allocator) void {
        while (!self.dead) {
            var buf: [16 * 1024]u8 = undefined;
            var iov = [_]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
            var control: [cmsgSpace(max_fds_out * @sizeOf(Fd))]u8 align(8) = undefined;
            var msg = std.mem.zeroes(c.msghdr);
            msg.iov = &iov;
            msg.iovlen = 1;
            msg.control = &control;
            msg.controllen = @intCast(control.len);
            // Received fds are not inherited by programs Tesselix starts.
            const flags: u32 = if (is_linux) 0x40000000 else 0; // MSG_CMSG_CLOEXEC
            const n = c.recvmsg(self.fd, &msg, flags);
            if (n < 0) {
                switch (c.errno(@as(c_int, -1))) {
                    .AGAIN, .INTR => return,
                    else => {
                        self.dead = true;
                        return;
                    },
                }
            }
            self.takeFds(gpa, control[0..@intCast(msg.controllen)]) catch {
                self.dead = true;
                return;
            };
            if (n == 0) {
                self.dead = true;
                return;
            }
            self.in.appendSlice(gpa, buf[0..@intCast(n)]) catch {
                self.dead = true;
                return;
            };
        }
    }

    fn takeFds(self: *Conn, gpa: std.mem.Allocator, control: []const u8) !void {
        var off: usize = 0;
        while (off + cmsg_hdr <= control.len) {
            const len: usize = std.mem.readInt(CmsgLen, control[off..][0..@sizeOf(CmsgLen)], builtin.cpu.arch.endian());
            if (len < cmsg_hdr or off + len > control.len) break;
            const level = std.mem.readInt(c_int, control[off + @sizeOf(CmsgLen) ..][0..@sizeOf(c_int)], builtin.cpu.arch.endian());
            const kind = std.mem.readInt(c_int, control[off + @sizeOf(CmsgLen) + @sizeOf(c_int) ..][0..@sizeOf(c_int)], builtin.cpu.arch.endian());
            if (level == c.SOL.SOCKET and kind == c.SCM.RIGHTS) {
                const data = control[off + cmsg_hdr .. off + len];
                var i: usize = 0;
                while (i + @sizeOf(Fd) <= data.len) : (i += @sizeOf(Fd)) {
                    try self.in_fds.append(gpa, std.mem.readInt(Fd, data[i..][0..@sizeOf(Fd)], builtin.cpu.arch.endian()));
                }
            }
            off += std.mem.alignForward(usize, len, cmsg_align);
        }
    }

    /// The next fd a message carried, in order; the caller owns it.
    pub fn takeFd(self: *Conn) ?Fd {
        if (self.in_fds.items.len == 0) return null;
        return self.in_fds.orderedRemove(0);
    }

    /// Queues `fd` to go with the next bytes written; the connection owns it.
    pub fn queueFd(self: *Conn, gpa: std.mem.Allocator, fd: Fd) !void {
        try self.out_fds.append(gpa, fd);
    }

    /// Writes what the socket takes now.
    pub fn flush(self: *Conn) void {
        while (!self.dead and (self.out.items.len > 0 or self.out_fds.items.len > 0)) {
            if (self.out.items.len == 0) {
                // fds need at least one byte to travel with; Wayland never
                // sends fds without a message, so this is a bug guard.
                for (self.out_fds.items) |f| _ = c.close(f);
                self.out_fds.clearRetainingCapacity();
                return;
            }
            var iov = [_]std.posix.iovec_const{.{ .base = self.out.items.ptr, .len = self.out.items.len }};
            var control: [cmsgSpace(max_fds_out * @sizeOf(Fd))]u8 align(8) = @splat(0);
            const nfds = @min(self.out_fds.items.len, max_fds_out);
            var msg = std.mem.zeroes(c.msghdr_const);
            msg.iov = &iov;
            msg.iovlen = 1;
            if (nfds > 0) {
                const data_len = nfds * @sizeOf(Fd);
                std.mem.writeInt(CmsgLen, control[0..@sizeOf(CmsgLen)], @intCast(cmsg_hdr + data_len), builtin.cpu.arch.endian());
                std.mem.writeInt(c_int, control[@sizeOf(CmsgLen)..][0..@sizeOf(c_int)], c.SOL.SOCKET, builtin.cpu.arch.endian());
                std.mem.writeInt(c_int, control[@sizeOf(CmsgLen) + @sizeOf(c_int) ..][0..@sizeOf(c_int)], c.SCM.RIGHTS, builtin.cpu.arch.endian());
                for (self.out_fds.items[0..nfds], 0..) |f, i| {
                    std.mem.writeInt(Fd, control[cmsg_hdr + i * @sizeOf(Fd) ..][0..@sizeOf(Fd)], f, builtin.cpu.arch.endian());
                }
                msg.control = &control;
                msg.controllen = @intCast(cmsgSpace(data_len));
            }
            const flags: u32 = if (is_linux) 0x4000 else 0; // MSG_NOSIGNAL
            const n = c.sendmsg(self.fd, &msg, flags);
            if (n < 0) {
                switch (c.errno(@as(c_int, -1))) {
                    .AGAIN, .INTR => {
                        if (self.out.items.len > max_out) self.dead = true;
                        return;
                    },
                    else => {
                        self.dead = true;
                        return;
                    },
                }
            }
            // The fds went with these bytes; close our copies.
            for (self.out_fds.items[0..nfds]) |f| _ = c.close(f);
            self.out_fds.replaceRangeAssumeCapacity(0, nfds, &.{});
            self.out.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
        }
    }

    /// The peer's process id, or 0 when the system does not say.
    pub fn peerPid(self: *const Conn) i32 {
        if (is_linux) {
            const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
            var cred: Ucred = undefined;
            var len: c.socklen_t = @sizeOf(Ucred);
            if (c.getsockopt(self.fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0) return 0;
            return cred.pid;
        }
        if (builtin.os.tag == .macos) {
            var pid: i32 = 0;
            var len: c.socklen_t = @sizeOf(i32);
            // SOL_LOCAL, LOCAL_PEERPID
            if (c.getsockopt(self.fd, 0, 0x002, &pid, &len) != 0) return 0;
            return pid;
        }
        return 0;
    }
};

/// The binary a process runs (/proc/<pid>/exe), symlinks resolved; "" when
/// unknown (not Linux, or the process is gone).
pub fn exePath(buf: []u8, pid: i32) []const u8 {
    if (!is_linux or pid <= 0) return "";
    var pbuf: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pbuf, "/proc/{d}/exe", .{pid}) catch return "";
    const n = c.readlink(p, buf.ptr, buf.len);
    if (n <= 0) return "";
    var s = buf[0..@intCast(n)];
    // A binary replaced while running (an upgrade) reads "... (deleted)".
    if (std.mem.endsWith(u8, s, " (deleted)")) s = s[0 .. s.len - " (deleted)".len];
    return s;
}

/// A socket pair for tests: both ends non-blocking.
pub fn testPair() ![2]Fd {
    var fds: [2]Fd = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    for (fds) |f| {
        const flags = c.fcntl(f, c.F.GETFL, @as(c_int, 0));
        _ = c.fcntl(f, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    return fds;
}

test "bytes and fds travel together" {
    const gpa = std.testing.allocator;
    const pair = try testPair();
    var a: Conn = .{ .fd = pair[0] };
    defer a.deinit(gpa);
    var b: Conn = .{ .fd = pair[1] };
    defer b.deinit(gpa);

    // Send a duplicate of stdin's... a fresh pipe end, to have a real fd.
    var p: [2]Fd = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[0]);
    try a.out.appendSlice(gpa, "hello");
    try a.queueFd(gpa, p[1]);
    a.flush();
    try std.testing.expectEqual(@as(usize, 0), a.out.items.len);

    b.read(gpa);
    try std.testing.expectEqualStrings("hello", b.in.items);
    const got = b.takeFd().?;
    // The received fd is the pipe's write end: writing shows up at p[0].
    try std.testing.expectEqual(@as(isize, 2), c.write(got, "ok", 2));
    _ = c.close(got);
    var rb: [2]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 2), c.read(p[0], &rb, 2));
    try std.testing.expect(b.peerPid() >= 0);
}
