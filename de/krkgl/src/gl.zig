//! The part of OpenGL (3.3 core) / OpenGL ES (3.0) the renderer uses,
//! declared by hand and loaded at run time from the backend's loader
//! (SDL_GL_GetProcAddress in the simulator, eglGetProcAddress on DRM).
//! Nothing links against libGL, so cross-compiling needs no GL libraries.

const std = @import("std");

pub const Enum = u32;
pub const Uint = u32;
pub const Int = i32;
pub const Sizei = i32;

pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const BLEND: Enum = 0x0BE2;
pub const SCISSOR_TEST: Enum = 0x0C11;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const CULL_FACE: Enum = 0x0B44;
pub const ONE: Enum = 1;
pub const ONE_MINUS_SRC_ALPHA: Enum = 0x0303;
pub const TRIANGLES: Enum = 0x0004;
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const STREAM_DRAW: Enum = 0x88E0;
pub const FLOAT: Enum = 0x1406;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const TEXTURE_2D: Enum = 0x0DE1;
pub const TEXTURE0: Enum = 0x84C0;
pub const RGBA: Enum = 0x1908;
pub const RGBA8: Enum = 0x8058;
pub const RED: Enum = 0x1903;
pub const R8: Enum = 0x8229;
pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
pub const TEXTURE_WRAP_S: Enum = 0x2802;
pub const TEXTURE_WRAP_T: Enum = 0x2803;
pub const NEAREST: Int = 0x2600;
pub const LINEAR: Int = 0x2601;
pub const CLAMP_TO_EDGE: Int = 0x812F;
pub const UNPACK_ALIGNMENT: Enum = 0x0CF5;
pub const UNPACK_ROW_LENGTH: Enum = 0x0CF2;
pub const PACK_ALIGNMENT: Enum = 0x0D05;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const VENDOR: Enum = 0x1F00;
pub const RENDERER: Enum = 0x1F01;
pub const VERSION: Enum = 0x1F02;
pub const MAX_TEXTURE_SIZE: Enum = 0x0D33;

/// Function table. Field names are the GL names, so `load` can find them.
pub const Gl = struct {
    glGetString: *const fn (name: Enum) callconv(.c) ?[*:0]const u8,
    glGetError: *const fn () callconv(.c) Enum,
    glGetIntegerv: *const fn (name: Enum, out: *Int) callconv(.c) void,
    glViewport: *const fn (x: Int, y: Int, w: Sizei, h: Sizei) callconv(.c) void,
    glClearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    glClear: *const fn (mask: u32) callconv(.c) void,
    glEnable: *const fn (cap: Enum) callconv(.c) void,
    glDisable: *const fn (cap: Enum) callconv(.c) void,
    glBlendFunc: *const fn (s: Enum, d: Enum) callconv(.c) void,
    glScissor: *const fn (x: Int, y: Int, w: Sizei, h: Sizei) callconv(.c) void,
    glPixelStorei: *const fn (name: Enum, v: Int) callconv(.c) void,
    glReadPixels: *const fn (x: Int, y: Int, w: Sizei, h: Sizei, format: Enum, kind: Enum, out: ?*anyopaque) callconv(.c) void,
    glFinish: *const fn () callconv(.c) void,

    glCreateShader: *const fn (kind: Enum) callconv(.c) Uint,
    glShaderSource: *const fn (s: Uint, n: Sizei, src: [*]const [*:0]const u8, len: ?[*]const Int) callconv(.c) void,
    glCompileShader: *const fn (s: Uint) callconv(.c) void,
    glGetShaderiv: *const fn (s: Uint, name: Enum, out: *Int) callconv(.c) void,
    glGetShaderInfoLog: *const fn (s: Uint, max: Sizei, len: ?*Sizei, log: [*]u8) callconv(.c) void,
    glDeleteShader: *const fn (s: Uint) callconv(.c) void,
    glCreateProgram: *const fn () callconv(.c) Uint,
    glAttachShader: *const fn (p: Uint, s: Uint) callconv(.c) void,
    glLinkProgram: *const fn (p: Uint) callconv(.c) void,
    glGetProgramiv: *const fn (p: Uint, name: Enum, out: *Int) callconv(.c) void,
    glGetProgramInfoLog: *const fn (p: Uint, max: Sizei, len: ?*Sizei, log: [*]u8) callconv(.c) void,
    glDeleteProgram: *const fn (p: Uint) callconv(.c) void,
    glUseProgram: *const fn (p: Uint) callconv(.c) void,
    glGetUniformLocation: *const fn (p: Uint, name: [*:0]const u8) callconv(.c) Int,
    glUniform1i: *const fn (loc: Int, v: Int) callconv(.c) void,
    glUniform2f: *const fn (loc: Int, x: f32, y: f32) callconv(.c) void,

    glGenBuffers: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glDeleteBuffers: *const fn (n: Sizei, ids: [*]const Uint) callconv(.c) void,
    glBindBuffer: *const fn (target: Enum, b: Uint) callconv(.c) void,
    glBufferData: *const fn (target: Enum, size: isize, data: ?*const anyopaque, usage: Enum) callconv(.c) void,
    glGenVertexArrays: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glDeleteVertexArrays: *const fn (n: Sizei, ids: [*]const Uint) callconv(.c) void,
    glBindVertexArray: *const fn (a: Uint) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (i: Uint) callconv(.c) void,
    glVertexAttribPointer: *const fn (i: Uint, size: Int, kind: Enum, normalized: u8, stride: Sizei, offset: usize) callconv(.c) void,
    glDrawArrays: *const fn (mode: Enum, first: Int, count: Sizei) callconv(.c) void,

    glGenTextures: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glDeleteTextures: *const fn (n: Sizei, ids: [*]const Uint) callconv(.c) void,
    glBindTexture: *const fn (target: Enum, t: Uint) callconv(.c) void,
    glActiveTexture: *const fn (unit: Enum) callconv(.c) void,
    glTexParameteri: *const fn (target: Enum, name: Enum, v: Int) callconv(.c) void,
    glTexImage2D: *const fn (target: Enum, level: Int, internal: Int, w: Sizei, h: Sizei, border: Int, format: Enum, kind: Enum, data: ?*const anyopaque) callconv(.c) void,
    glTexSubImage2D: *const fn (target: Enum, level: Int, x: Int, y: Int, w: Sizei, h: Sizei, format: Enum, kind: Enum, data: ?*const anyopaque) callconv(.c) void,

    pub const GetProc = *const fn (name: [*:0]const u8) callconv(.c) ?*const anyopaque;

    /// Fills the table from the backend's loader; names any function that
    /// is missing.
    pub fn load(get: GetProc) error{MissingGlFunction}!Gl {
        var gl: Gl = undefined;
        inline for (std.meta.fields(Gl)) |f| {
            const p = get(f.name ++ "\x00") orelse {
                std.log.err("GL: {s} is missing", .{f.name});
                return error.MissingGlFunction;
            };
            @field(gl, f.name) = @ptrCast(@alignCast(p));
        }
        return gl;
    }
};
