//! txcomp: the compositor core. Backend-independent; the simulator backend
//! (tools/txsim) and, later, Tesselix's own DRM/KMS backend drive it.

pub const tiling = @import("tiling.zig");
pub const chrome = @import("chrome.zig");
pub const shell = @import("shell.zig");
pub const publish = @import("publish.zig");
pub const apps = @import("apps.zig");
pub const compositor = @import("compositor.zig");

pub const Compositor = compositor.Compositor;
pub const AppEntry = compositor.AppEntry;
pub const Params = compositor.Params;
pub const FramePace = compositor.FramePace;

test {
    @import("std").testing.refAllDecls(@This());
}
