//! txcore: what every Tesselix component shares. Pure Zig, no OS
//! dependencies beyond std, builds and tests on macOS and Linux.

pub const format = @import("format.zig");
pub const registry = @import("registry.zig");
pub const geom = @import("geom.zig");
pub const input = @import("input.zig");
pub const theme = @import("theme.zig");
pub const anim = @import("anim.zig");
pub const wheel = @import("wheel.zig");
pub const metrics = @import("metrics.zig");
pub const types = @import("types.zig");
pub const ipc = @import("ipc.zig");

pub const Handle = registry.Handle;
pub const Registry = registry.Registry;
pub const Rect = geom.Rect;
pub const Size = geom.Size;
pub const Color = theme.Color;
pub const Theme = theme.Theme;

test {
    @import("std").testing.refAllDecls(@This());
}
