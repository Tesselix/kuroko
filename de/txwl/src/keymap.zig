//! The keyboard map every client gets (wl_keyboard.keymap): XKB text in a
//! memory file the client maps read-only. Key events carry Linux (evdev)
//! key codes; the client turns them into characters with this map.
//!
//! The map names the standard US layout; libxkbcommon in the client
//! resolves the includes from the system's XKB data (xkb-data). Layouts
//! the user chooses come with the settings.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const us =
    \\xkb_keymap {
    \\  xkb_keycodes { include "evdev+aliases(qwerty)" };
    \\  xkb_types { include "complete" };
    \\  xkb_compat { include "complete" };
    \\  xkb_symbols { include "pc+us+inet(evdev)" };
    \\  xkb_geometry { include "pc(pc105)" };
    \\};
    \\
;

/// XKB modifier masks of the standard map.
pub const mod_shift: u32 = 1 << 0;
pub const mod_lock: u32 = 1 << 1;
pub const mod_ctrl: u32 = 1 << 2;
pub const mod_alt: u32 = 1 << 3; // Mod1
pub const mod_super: u32 = 1 << 6; // Mod4

/// A file holding `text` and its NUL, for wl_keyboard.keymap. The caller
/// owns the fd. Returns the size to announce.
pub fn file(text: []const u8) !struct { fd: c.fd_t, size: u32 } {
    const fd: c.fd_t = if (builtin.os.tag == .linux) blk: {
        const f = c.memfd_create("kuroko-keymap", 1); // MFD_CLOEXEC
        if (f < 0) return error.MemFd;
        break :blk f;
    } else blk: {
        var name = "/tmp/kuroko-keymap-XXXXXX".*;
        const f = mkstemp(&name);
        if (f < 0) return error.TempFile;
        _ = c.unlink(&name);
        break :blk f;
    };
    errdefer _ = c.close(fd);
    var rest: []const u8 = text;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.Write;
        rest = rest[@intCast(n)..];
    }
    if (c.write(fd, "\x00", 1) != 1) return error.Write;
    return .{ .fd = fd, .size = @intCast(text.len + 1) };
}

test "the keymap file holds the text and its NUL" {
    const f = try file(us);
    defer _ = c.close(f.fd);
    try std.testing.expectEqual(@as(u32, us.len + 1), f.size);
    var buf: [16]u8 = undefined;
    const n = c.pread(f.fd, &buf, buf.len, 0);
    try std.testing.expectEqualStrings("xkb_keymap {", buf[0..12]);
    try std.testing.expect(n == 16);
}
