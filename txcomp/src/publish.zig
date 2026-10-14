//! Event publisher (Top-Level Design, Architecture): scene-graph deltas to
//! desktop services over a Unix socket.
//!
//! The compositor never waits: writes are non-blocking, and a subscriber
//! that falls behind loses its queued deltas and gets a full snapshot.

const std = @import("std");
const core = @import("txcore");

const max_pending = 256 * 1024;

pub const Publisher = struct {
    gpa: std.mem.Allocator,
    listen_fd: ?core.ipc.Fd = null,
    subs: std.ArrayList(Sub) = .empty,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    const Sub = struct {
        fd: core.ipc.Fd,
        pending: std.ArrayList(u8) = .empty,
        needs_snapshot: bool = true,
    };

    /// Returned by value: keeps no pointers into itself.
    pub fn init(gpa: std.mem.Allocator) Publisher {
        var p: Publisher = .{ .gpa = gpa };
        core.ipc.ignoreSigpipe();
        const path = core.ipc.socketPath(&p.path_buf, core.ipc.compositor_socket) catch |err| {
            std.log.warn("publisher: no socket directory: {s}", .{@errorName(err)});
            return p;
        };
        p.path_len = path.len;
        p.listen_fd = core.ipc.listen(path) catch |err| {
            std.log.warn("publisher: cannot listen on {s}: {s}", .{ path, @errorName(err) });
            return p;
        };
        std.log.info("publisher: listening on {s}", .{path});
        return p;
    }

    pub fn deinit(self: *Publisher) void {
        for (self.subs.items) |*s| {
            core.ipc.close(s.fd);
            s.pending.deinit(self.gpa);
        }
        self.subs.deinit(self.gpa);
        if (self.listen_fd) |fd| {
            core.ipc.close(fd);
            core.ipc.unlink(self.path_buf[0..self.path_len]);
        }
    }

    /// Accepts new subscribers. Returns true if any needs a snapshot.
    pub fn poll(self: *Publisher) bool {
        if (self.listen_fd) |fd| {
            while (core.ipc.acceptNonBlocking(fd) catch null) |conn| {
                self.subs.append(self.gpa, .{ .fd = conn }) catch {
                    core.ipc.close(conn);
                    break;
                };
            }
        }
        for (self.subs.items) |s| {
            if (s.needs_snapshot) return true;
        }
        return false;
    }

    /// Queues a snapshot for every subscriber that needs one.
    pub fn sendSnapshot(self: *Publisher, bytes: []const u8) void {
        for (self.subs.items) |*s| {
            if (!s.needs_snapshot) continue;
            s.pending.clearRetainingCapacity();
            s.pending.appendSlice(self.gpa, bytes) catch continue;
            s.needs_snapshot = false;
        }
    }

    pub fn broadcast(self: *Publisher, bytes: []const u8) void {
        for (self.subs.items) |*s| {
            if (s.needs_snapshot) continue;
            if (s.pending.items.len + bytes.len > max_pending) {
                // Fell behind: drop the deltas, resync from a snapshot.
                s.pending.clearRetainingCapacity();
                s.needs_snapshot = true;
                continue;
            }
            s.pending.appendSlice(self.gpa, bytes) catch {
                s.needs_snapshot = true;
            };
        }
    }

    pub fn flush(self: *Publisher) void {
        var i: usize = 0;
        while (i < self.subs.items.len) {
            const s = &self.subs.items[i];
            var dead = false;
            while (s.pending.items.len > 0) {
                const n = core.ipc.write(s.fd, s.pending.items) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        dead = true;
                        break;
                    },
                };
                if (n == 0) break;
                s.pending.replaceRange(self.gpa, 0, n, &.{}) catch {};
            }
            if (dead) {
                // Client death is detected from the socket, nothing else.
                core.ipc.close(s.fd);
                s.pending.deinit(self.gpa);
                _ = self.subs.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn subscriberCount(self: *const Publisher) usize {
        return self.subs.items.len;
    }
};
