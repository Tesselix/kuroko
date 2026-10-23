//! Starting programs without waiting for them (the compositor starts apps
//! from the launcher and never waits). Children are reaped by the kernel:
//! SIGCHLD is ignored, so no zombies are left behind.
//!
//! libc's posix_spawnp, declared here: std.c has it on macOS only.

const std = @import("std");
const c = std.c;

extern "c" fn posix_spawnp(
    pid: *c.pid_t,
    file: [*:0]const u8,
    file_actions: ?*const anyopaque,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

var reaping = false;

/// Ignore SIGCHLD once: the kernel reaps exited children.
fn reapChildren() void {
    if (reaping) return;
    reaping = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &act, null);
}

/// Starts `argv` (absolute command first) with this process's environment,
/// changed by `env`: "NAME=value" sets, "NAME" removes. Returns the child's
/// process id.
pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, env: []const []const u8) !c.pid_t {
    if (argv.len == 0) return error.NoCommand;
    reapChildren();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| args[i] = try a.dupeZ(u8, s);
    args[argv.len] = null;
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        const name = e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
        const changed = for (env) |x| {
            const xn = x[0 .. std.mem.indexOfScalar(u8, x, '=') orelse x.len];
            if (std.mem.eql(u8, xn, name)) break true;
        } else false;
        if (!changed) try envp.append(a, entry);
    }
    for (env) |x| {
        if (std.mem.indexOfScalar(u8, x, '=') != null) try envp.append(a, try a.dupeZ(u8, x));
    }
    try envp.append(a, null);
    var pid: c.pid_t = 0;
    const rc = posix_spawnp(&pid, args[0].?, null, null, @ptrCast(args.ptr), @ptrCast(envp.items.ptr));
    if (rc != 0) return error.SpawnFailed;
    return pid;
}

/// The command a launcher runs: desktop field codes (%U, %f, ...) are
/// removed, since nothing is being opened; "%%" was already turned into
/// "%" when the entry was read.
pub fn withoutFieldCodes(argv: []const []const u8, out: [][]const u8) []const []const u8 {
    var n: usize = 0;
    for (argv) |arg| {
        if (arg.len == 2 and arg[0] == '%') continue;
        if (n == out.len) break;
        out[n] = arg;
        n += 1;
    }
    return out[0..n];
}

test "spawn starts a program" {
    const pid = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "test \"$TX_TEST\" = yes" }, &.{ "TX_TEST=yes", "DISPLAY" });
    try std.testing.expect(pid > 0);
}

test "field codes are dropped" {
    var buf: [8][]const u8 = undefined;
    const out = withoutFieldCodes(&.{ "/usr/bin/google-chrome-stable", "--new-window", "%U" }, &buf);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("--new-window", out[1]);
}
