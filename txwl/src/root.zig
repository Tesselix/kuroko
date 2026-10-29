//! txwl: Kuroko as a Wayland server. Apps connect to it, and their
//! windows are compositor windows like Kuroko's own (see server.zig).
//! Pure Zig on libc sockets; builds and tests on macOS too.

pub const wire = @import("wire.zig");
pub const conn = @import("conn.zig");
pub const keymap = @import("keymap.zig");
pub const positioner = @import("positioner.zig");
pub const server = @import("server.zig");
pub const window = @import("window.zig");
const test_client = @import("test_client.zig");

pub const Server = server.Server;
pub const Hooks = server.Hooks;
pub const WindowInfo = server.WindowInfo;

test {
    @import("std").testing.refAllDecls(@This());
    _ = test_client;
}
