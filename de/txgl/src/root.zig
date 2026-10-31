//! txgl: Kuroko's GPU renderer. Draws the compositor's recorded frames
//! (txwidgets draw lists) with OpenGL 3.3 core or OpenGL ES 3.0. Shared by
//! every backend: the simulator (SDL's GL context) and the DRM/KMS backend
//! (EGL on GBM).

pub const gl = @import("gl.zig");
pub const glyph_pack = @import("glyph_pack.zig");
pub const renderer = @import("renderer.zig");

pub const Renderer = renderer.Renderer;
pub const Api = renderer.Api;
pub const Gl = gl.Gl;

test {
    @import("std").testing.refAllDecls(@This());
}
