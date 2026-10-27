//! Draws a recorded frame (txwidgets draw list) with OpenGL 3.3 core or
//! OpenGL ES 3.0. Backend-independent: the backend makes a context current
//! and hands over its function loader; this file does the rest.
//!
//! Every primitive becomes one quad drawn by one shader:
//!   - fills are plain color,
//!   - rounded rects, circles and lines are signed distances, with the same
//!     coverage formula as the CPU canvas (0.5 - d, at pixel centers),
//!   - glyphs come from one shared R8 texture (glyph_pack.zig),
//!   - images are textures kept by `Image.id` and uploaded again only when
//!     `Image.version` changes. Pixels are 0xAARRGGBB in memory (B, G, R, A
//!     bytes), uploaded as RGBA bytes and swizzled in the shader.
//! Clips are scissor rects; quads are batched until the clip or the image
//! changes. Output is premultiplied (ONE, ONE_MINUS_SRC_ALPHA).

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const gl_mod = @import("gl.zig");
const GlyphPack = @import("glyph_pack.zig").GlyphPack;

const Gl = gl_mod.Gl;
const Rect = core.Rect;
const DrawList = tw.DrawList;

pub const Api = enum { gl33, gles30 };

const Kind = enum(u8) { fill, image, glyph, round_fill, round_stroke, line };

const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: [4]u8,
    kind: f32,
    /// Shape parameters: rect corners (x0, y0, x1, y1) or line ends.
    p: [4]f32,
    /// Radius or half width, stroke width.
    q: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 56);
}

const vertex_src =
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in vec4 a_color;
    \\layout(location = 3) in float a_kind;
    \\layout(location = 4) in vec4 a_p;
    \\layout(location = 5) in vec4 a_q;
    \\uniform vec2 u_view;
    \\out vec2 v_pos;
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\flat out float v_kind;
    \\flat out vec4 v_p;
    \\flat out vec4 v_q;
    \\void main() {
    \\    v_pos = a_pos;
    \\    v_uv = a_uv;
    \\    v_color = a_color;
    \\    v_kind = a_kind;
    \\    v_p = a_p;
    \\    v_q = a_q;
    \\    gl_Position = vec4(a_pos.x / u_view.x * 2.0 - 1.0, 1.0 - a_pos.y / u_view.y * 2.0, 0.0, 1.0);
    \\}
;

const fragment_src =
    \\uniform sampler2D u_image;
    \\uniform sampler2D u_mask;
    \\in vec2 v_pos;
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\flat in float v_kind;
    \\flat in vec4 v_p;
    \\flat in vec4 v_q;
    \\out vec4 o_color;
    \\float roundRectDist(vec2 p, vec4 r, float rad) {
    \\    vec2 c = (r.xy + r.zw) * 0.5;
    \\    vec2 h = (r.zw - r.xy) * 0.5 - vec2(rad);
    \\    vec2 q = abs(p - c) - h;
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    \\}
    \\void main() {
    \\    int k = int(v_kind + 0.5);
    \\    vec3 rgb = v_color.rgb;
    \\    float a = v_color.a;
    \\    if (k == 1) {
    \\        rgb = texture(u_image, v_uv).bgr;
    \\    } else if (k == 2) {
    \\        a *= texture(u_mask, v_uv).r;
    \\    } else if (k == 3) {
    \\        a *= clamp(0.5 - roundRectDist(v_pos, v_p, v_q.x), 0.0, 1.0);
    \\    } else if (k == 4) {
    \\        float d = roundRectDist(v_pos, v_p, v_q.x);
    \\        a *= clamp(0.5 - d, 0.0, 1.0) - clamp(0.5 - (d + v_q.y), 0.0, 1.0);
    \\    } else if (k == 5) {
    \\        vec2 pa = v_pos - v_p.xy;
    \\        vec2 ba = v_p.zw - v_p.xy;
    \\        float t = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    \\        a *= clamp(0.5 - (length(pa - ba * t) - v_q.x), 0.0, 1.0);
    \\    }
    \\    o_color = vec4(rgb * a, a);
    \\}
;

fn header(api: Api) [:0]const u8 {
    return switch (api) {
        .gl33 => "#version 330 core\n",
        .gles30 => "#version 300 es\nprecision highp float;\nprecision highp int;\n",
    };
}

const Tex = struct {
    name: gl_mod.Uint,
    w: i32,
    h: i32,
    version: u64,
    last_used: u64,
};

/// Per-frame counts, for the timing summary and the debugger.
pub const Stats = struct {
    draw_calls: u32 = 0,
    quads: u32 = 0,
    uploads: u32 = 0,
    upload_bytes: u64 = 0,
};

/// Image textures not drawn for this many frames are deleted.
const keep_frames = 120;
const glyph_size = 2048;
/// Texture unit for uploads, so units 0 and 1 keep what pending quads use.
const upload_unit = 2;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    gl: Gl,
    api: Api,
    program: gl_mod.Uint = 0,
    vao: gl_mod.Uint = 0,
    vbo: gl_mod.Uint = 0,
    u_view: gl_mod.Int = -1,
    glyph_tex: gl_mod.Uint = 0,
    /// 1x1 white on unit 0 while no image is bound: a sampler is never
    /// left without a texture.
    blank_tex: gl_mod.Uint = 0,
    pack: GlyphPack,
    images: std.AutoHashMapUnmanaged(u64, Tex) = .empty,
    /// Textures for images without an id, deleted after the frame.
    temps: std.ArrayList(gl_mod.Uint) = .empty,
    verts: std.ArrayList(Vertex) = .empty,
    max_tex: i32 = 2048,
    frame: u64 = 0,
    stats: Stats = .{},

    fb_h: i32 = 0,
    cur_clip: Rect = .{},
    cur_tex: gl_mod.Uint = 0,
    cur_exact: bool = false,
    warned_full: bool = false,
    warned_big: bool = false,

    pub fn create(gpa: std.mem.Allocator, get_proc: Gl.GetProc, api: Api) !*Renderer {
        const gl = try Gl.load(get_proc);
        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .gl = gl, .api = api, .pack = GlyphPack.init(gpa, glyph_size) };
        errdefer self.pack.deinit();

        std.log.info("GL: {s} | {s} | {s}", .{
            gl.glGetString(gl_mod.VENDOR) orelse "?",
            gl.glGetString(gl_mod.RENDERER) orelse "?",
            gl.glGetString(gl_mod.VERSION) orelse "?",
        });
        gl.glGetIntegerv(gl_mod.MAX_TEXTURE_SIZE, &self.max_tex);

        self.program = try self.buildProgram();
        gl.glUseProgram(self.program);
        self.u_view = gl.glGetUniformLocation(self.program, "u_view");
        gl.glUniform1i(gl.glGetUniformLocation(self.program, "u_image"), 0);
        gl.glUniform1i(gl.glGetUniformLocation(self.program, "u_mask"), 1);

        gl.glGenVertexArrays(1, @ptrCast(&self.vao));
        gl.glBindVertexArray(self.vao);
        gl.glGenBuffers(1, @ptrCast(&self.vbo));
        gl.glBindBuffer(gl_mod.ARRAY_BUFFER, self.vbo);
        const stride: gl_mod.Sizei = @sizeOf(Vertex);
        const attrs = [_]struct { size: i32, kind: gl_mod.Enum, norm: u8, off: usize }{
            .{ .size = 2, .kind = gl_mod.FLOAT, .norm = 0, .off = @offsetOf(Vertex, "x") },
            .{ .size = 2, .kind = gl_mod.FLOAT, .norm = 0, .off = @offsetOf(Vertex, "u") },
            .{ .size = 4, .kind = gl_mod.UNSIGNED_BYTE, .norm = 1, .off = @offsetOf(Vertex, "color") },
            .{ .size = 1, .kind = gl_mod.FLOAT, .norm = 0, .off = @offsetOf(Vertex, "kind") },
            .{ .size = 4, .kind = gl_mod.FLOAT, .norm = 0, .off = @offsetOf(Vertex, "p") },
            .{ .size = 4, .kind = gl_mod.FLOAT, .norm = 0, .off = @offsetOf(Vertex, "q") },
        };
        for (attrs, 0..) |a, i| {
            gl.glEnableVertexAttribArray(@intCast(i));
            gl.glVertexAttribPointer(@intCast(i), a.size, a.kind, a.norm, stride, a.off);
        }

        // The glyph texture starts cleared, so the padding around glyphs
        // is empty.
        const zeros = try gpa.alloc(u8, glyph_size * glyph_size);
        defer gpa.free(zeros);
        @memset(zeros, 0);
        gl.glGenTextures(1, @ptrCast(&self.glyph_tex));
        gl.glActiveTexture(gl_mod.TEXTURE0 + 1);
        gl.glBindTexture(gl_mod.TEXTURE_2D, self.glyph_tex);
        gl.glPixelStorei(gl_mod.UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl_mod.TEXTURE_2D, 0, @intCast(gl_mod.R8), glyph_size, glyph_size, 0, gl_mod.RED, gl_mod.UNSIGNED_BYTE, zeros.ptr);
        setFilter(&gl, gl_mod.NEAREST);
        gl.glActiveTexture(gl_mod.TEXTURE0);
        const white = [4]u8{ 255, 255, 255, 255 };
        gl.glGenTextures(1, @ptrCast(&self.blank_tex));
        gl.glBindTexture(gl_mod.TEXTURE_2D, self.blank_tex);
        gl.glPixelStorei(gl_mod.UNPACK_ALIGNMENT, 4);
        gl.glTexImage2D(gl_mod.TEXTURE_2D, 0, @intCast(gl_mod.RGBA8), 1, 1, 0, gl_mod.RGBA, gl_mod.UNSIGNED_BYTE, &white);
        setFilter(&gl, gl_mod.NEAREST);
        return self;
    }

    pub fn destroy(self: *Renderer) void {
        const gl = &self.gl;
        var it = self.images.valueIterator();
        while (it.next()) |t| gl.glDeleteTextures(1, @ptrCast(&t.name));
        self.images.deinit(self.gpa);
        self.deleteTemps();
        self.temps.deinit(self.gpa);
        gl.glDeleteTextures(1, @ptrCast(&self.glyph_tex));
        gl.glDeleteTextures(1, @ptrCast(&self.blank_tex));
        gl.glDeleteBuffers(1, @ptrCast(&self.vbo));
        gl.glDeleteVertexArrays(1, @ptrCast(&self.vao));
        gl.glDeleteProgram(self.program);
        self.verts.deinit(self.gpa);
        self.pack.deinit();
        self.gpa.destroy(self);
    }

    fn buildProgram(self: *Renderer) !gl_mod.Uint {
        const gl = &self.gl;
        const vs = try self.compile(gl_mod.VERTEX_SHADER, vertex_src);
        defer gl.glDeleteShader(vs);
        const fs = try self.compile(gl_mod.FRAGMENT_SHADER, fragment_src);
        defer gl.glDeleteShader(fs);
        const p = gl.glCreateProgram();
        gl.glAttachShader(p, vs);
        gl.glAttachShader(p, fs);
        gl.glLinkProgram(p);
        var ok: gl_mod.Int = 0;
        gl.glGetProgramiv(p, gl_mod.LINK_STATUS, &ok);
        if (ok == 0) {
            var buf: [2048]u8 = undefined;
            var n: gl_mod.Sizei = 0;
            gl.glGetProgramInfoLog(p, buf.len, &n, &buf);
            std.log.err("GL link: {s}", .{buf[0..@intCast(n)]});
            return error.GlShader;
        }
        return p;
    }

    fn compile(self: *Renderer, kind: gl_mod.Enum, body: [:0]const u8) !gl_mod.Uint {
        const gl = &self.gl;
        const s = gl.glCreateShader(kind);
        const parts = [_][*:0]const u8{ header(self.api), body };
        gl.glShaderSource(s, parts.len, &parts, null);
        gl.glCompileShader(s);
        var ok: gl_mod.Int = 0;
        gl.glGetShaderiv(s, gl_mod.COMPILE_STATUS, &ok);
        if (ok == 0) {
            var buf: [2048]u8 = undefined;
            var n: gl_mod.Sizei = 0;
            gl.glGetShaderInfoLog(s, buf.len, &n, &buf);
            std.log.err("GL compile: {s}", .{buf[0..@intCast(n)]});
            gl.glDeleteShader(s);
            return error.GlShader;
        }
        return s;
    }

    fn setFilter(gl: *const Gl, f: gl_mod.Int) void {
        gl.glTexParameteri(gl_mod.TEXTURE_2D, gl_mod.TEXTURE_MIN_FILTER, f);
        gl.glTexParameteri(gl_mod.TEXTURE_2D, gl_mod.TEXTURE_MAG_FILTER, f);
        gl.glTexParameteri(gl_mod.TEXTURE_2D, gl_mod.TEXTURE_WRAP_S, gl_mod.CLAMP_TO_EDGE);
        gl.glTexParameteri(gl_mod.TEXTURE_2D, gl_mod.TEXTURE_WRAP_T, gl_mod.CLAMP_TO_EDGE);
    }

    /// Draws `list` into the current framebuffer (physical size fb_w x fb_h).
    pub fn draw(self: *Renderer, list: *const DrawList, fb_w: i32, fb_h: i32) void {
        const gl = &self.gl;
        self.frame += 1;
        self.stats = .{};
        self.fb_h = fb_h;
        const screen = Rect{ .x = 0, .y = 0, .w = fb_w, .h = fb_h };

        gl.glViewport(0, 0, fb_w, fb_h);
        gl.glDisable(gl_mod.DEPTH_TEST);
        gl.glDisable(gl_mod.CULL_FACE);
        gl.glEnable(gl_mod.BLEND);
        gl.glBlendFunc(gl_mod.ONE, gl_mod.ONE_MINUS_SRC_ALPHA);
        gl.glDisable(gl_mod.SCISSOR_TEST);
        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl_mod.COLOR_BUFFER_BIT);
        gl.glEnable(gl_mod.SCISSOR_TEST);

        gl.glUseProgram(self.program);
        gl.glUniform2f(self.u_view, @floatFromInt(fb_w), @floatFromInt(fb_h));
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl_mod.ARRAY_BUFFER, self.vbo);
        gl.glActiveTexture(gl_mod.TEXTURE0 + 1);
        gl.glBindTexture(gl_mod.TEXTURE_2D, self.glyph_tex);
        gl.glActiveTexture(gl_mod.TEXTURE0);
        gl.glBindTexture(gl_mod.TEXTURE_2D, self.blank_tex);
        self.cur_clip = .{ .x = -1, .y = -1, .w = 0, .h = 0 };
        self.cur_tex = self.blank_tex;

        for (list.cmds.items) |cmd| {
            const clip = cmd.clip.intersect(screen);
            if (clip.isEmpty()) continue;
            const c = cmd.color;
            const col = [4]u8{ c.r, c.g, c.b, c.a };
            switch (cmd.op) {
                .fill => |r| {
                    self.use(clip, null, false);
                    self.quad(fr(r), .{ 0, 0, 0, 0 }, col, .fill, @splat(0), @splat(0));
                },
                .round => |o| {
                    self.use(clip, null, false);
                    const b = fr(o.r);
                    self.quad(b, .{ 0, 0, 0, 0 }, col, if (o.stroke > 0) .round_stroke else .round_fill, b, .{ o.rad, o.stroke, 0, 0 });
                },
                .circle => |o| {
                    self.use(clip, null, false);
                    const shape = [4]f32{ o.cx - o.r, o.cy - o.r, o.cx + o.r, o.cy + o.r };
                    self.quad(grow(shape, 1), .{ 0, 0, 0, 0 }, col, .round_fill, shape, .{ o.r, 0, 0, 0 });
                },
                .line => |o| {
                    self.use(clip, null, false);
                    const box = [4]f32{ @min(o.x0, o.x1), @min(o.y0, o.y1), @max(o.x0, o.x1), @max(o.y0, o.y1) };
                    self.quad(grow(box, o.hw + 1), .{ 0, 0, 0, 0 }, col, .line, .{ o.x0, o.y0, o.x1, o.y1 }, .{ o.hw, 0, 0, 0 });
                },
                .glyph => |o| {
                    const g = o.glyph;
                    const found = self.pack.find(g) orelse {
                        if (!self.warned_full) std.log.warn("GL: glyph texture full", .{});
                        self.warned_full = true;
                        continue;
                    };
                    if (found.new) self.uploadGlyph(g, found.slot.x, found.slot.y);
                    self.use(clip, null, false);
                    const s: f32 = glyph_size;
                    const tu = @as(f32, @floatFromInt(found.slot.x)) / s;
                    const tv = @as(f32, @floatFromInt(found.slot.y)) / s;
                    const box = [4]f32{ @floatFromInt(o.x), @floatFromInt(o.y), @floatFromInt(o.x + @as(i32, g.w)), @floatFromInt(o.y + @as(i32, g.h)) };
                    self.quad(box, .{ tu, tv, tu + @as(f32, @floatFromInt(g.w)) / s, tv + @as(f32, @floatFromInt(g.h)) / s }, col, .glyph, @splat(0), @splat(0));
                },
                .image => |o| {
                    const tex = self.imageTexture(o.img) orelse continue;
                    self.use(clip, tex, o.exact);
                    const dst = if (o.exact) Rect{ .x = o.dst.x, .y = o.dst.y, .w = o.img.w, .h = o.img.h } else o.dst;
                    self.quad(fr(dst), .{ 0, 0, 1, 1 }, .{ 255, 255, 255, o.alpha }, .image, @splat(0), @splat(0));
                },
            }
        }
        self.flush();
        self.deleteTemps();
        self.evict();
    }

    /// Reads the drawn frame back as 0xAARRGGBB, top row first (tests and
    /// scripted snapshots; slow).
    pub fn readPixels(self: *Renderer, out: []u32, w: i32, h: i32) void {
        const gl = &self.gl;
        gl.glFinish();
        gl.glPixelStorei(gl_mod.PACK_ALIGNMENT, 4);
        gl.glReadPixels(0, 0, w, h, gl_mod.RGBA, gl_mod.UNSIGNED_BYTE, out.ptr);
        const W: usize = @intCast(w);
        const H: usize = @intCast(h);
        // RGBA bytes, bottom row first.
        for (out[0 .. W * H]) |*p| {
            const b: [4]u8 = @bitCast(p.*);
            p.* = (@as(u32, b[3]) << 24) | (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
        }
        for (0..H / 2) |y| {
            const top = out[y * W ..][0..W];
            const bot = out[(H - 1 - y) * W ..][0..W];
            for (top, bot) |*a, *b| std.mem.swap(u32, a, b);
        }
    }

    fn fr(r: Rect) [4]f32 {
        return .{ @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.right()), @floatFromInt(r.bottom()) };
    }

    /// A box grown by `m` and snapped out to whole pixels.
    fn grow(b: [4]f32, m: f32) [4]f32 {
        return .{ @floor(b[0] - m), @floor(b[1] - m), @ceil(b[2] + m), @ceil(b[3] + m) };
    }

    /// Switches clip and image; draws what is batched when either changes.
    /// Shapes and glyphs (`tex` null) draw under any bound image.
    fn use(self: *Renderer, clip: Rect, tex: ?gl_mod.Uint, exact: bool) void {
        const clip_changed = !std.meta.eql(clip, self.cur_clip);
        const tex_changed = if (tex) |t| t != self.cur_tex or exact != self.cur_exact else false;
        if (!clip_changed and !tex_changed) return;
        self.flush();
        const gl = &self.gl;
        if (clip_changed) {
            gl.glScissor(clip.x, self.fb_h - clip.bottom(), clip.w, clip.h);
            self.cur_clip = clip;
        }
        if (tex_changed) {
            gl.glBindTexture(gl_mod.TEXTURE_2D, tex.?);
            setFilter(gl, if (exact) gl_mod.NEAREST else gl_mod.LINEAR);
            self.cur_tex = tex.?;
            self.cur_exact = exact;
        }
    }

    fn quad(self: *Renderer, b: [4]f32, uv: [4]f32, col: [4]u8, kind: Kind, p: [4]f32, q: [4]f32) void {
        const k: f32 = @floatFromInt(@intFromEnum(kind));
        const corners = [6][2]u1{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const v = self.verts.addManyAsArray(self.gpa, 6) catch return;
        for (corners, v) |cn, *out| {
            out.* = .{
                .x = if (cn[0] == 0) b[0] else b[2],
                .y = if (cn[1] == 0) b[1] else b[3],
                .u = if (cn[0] == 0) uv[0] else uv[2],
                .v = if (cn[1] == 0) uv[1] else uv[3],
                .color = col,
                .kind = k,
                .p = p,
                .q = q,
            };
        }
        self.stats.quads += 1;
    }

    fn flush(self: *Renderer) void {
        const n = self.verts.items.len;
        if (n == 0) return;
        const gl = &self.gl;
        gl.glBufferData(gl_mod.ARRAY_BUFFER, @intCast(n * @sizeOf(Vertex)), self.verts.items.ptr, gl_mod.STREAM_DRAW);
        gl.glDrawArrays(gl_mod.TRIANGLES, 0, @intCast(n));
        self.verts.clearRetainingCapacity();
        self.stats.draw_calls += 1;
    }

    fn uploadGlyph(self: *Renderer, g: *const tw.font.Glyph, x: u16, y: u16) void {
        const gl = &self.gl;
        gl.glActiveTexture(gl_mod.TEXTURE0 + upload_unit);
        gl.glBindTexture(gl_mod.TEXTURE_2D, self.glyph_tex);
        gl.glPixelStorei(gl_mod.UNPACK_ALIGNMENT, 1);
        gl.glPixelStorei(gl_mod.UNPACK_ROW_LENGTH, 0);
        gl.glTexSubImage2D(gl_mod.TEXTURE_2D, 0, x, y, g.w, g.h, gl_mod.RED, gl_mod.UNSIGNED_BYTE, g.bitmap.ptr);
        gl.glActiveTexture(gl_mod.TEXTURE0);
        self.stats.uploads += 1;
        self.stats.upload_bytes += g.bitmap.len;
    }

    /// The texture for an image, uploading it if it is new or changed.
    fn imageTexture(self: *Renderer, img: tw.Image) ?gl_mod.Uint {
        if (img.w <= 0 or img.h <= 0 or img.pixels.len < @as(usize, @intCast(img.w * img.h))) return null;
        if (img.w > self.max_tex or img.h > self.max_tex) {
            if (!self.warned_big) std.log.warn("GL: image {d}x{d} over the texture limit {d}", .{ img.w, img.h, self.max_tex });
            self.warned_big = true;
            return null;
        }
        const gl = &self.gl;
        if (img.id == 0) {
            var name: gl_mod.Uint = 0;
            gl.glGenTextures(1, @ptrCast(&name));
            self.temps.append(self.gpa, name) catch {
                gl.glDeleteTextures(1, @ptrCast(&name));
                return null;
            };
            self.upload(name, img, true);
            return name;
        }
        const gop = self.images.getOrPut(self.gpa, img.id) catch return null;
        if (!gop.found_existing) {
            var name: gl_mod.Uint = 0;
            gl.glGenTextures(1, @ptrCast(&name));
            gop.value_ptr.* = .{ .name = name, .w = img.w, .h = img.h, .version = img.version, .last_used = self.frame };
            self.upload(name, img, true);
        } else {
            const t = gop.value_ptr;
            if (t.version != img.version or t.w != img.w or t.h != img.h) {
                // A texture still waiting to be drawn must not change under
                // the batch.
                if (t.name == self.cur_tex) self.flush();
                self.upload(t.name, img, t.w != img.w or t.h != img.h);
                t.* = .{ .name = t.name, .w = img.w, .h = img.h, .version = img.version, .last_used = self.frame };
            }
        }
        gop.value_ptr.last_used = self.frame;
        return gop.value_ptr.name;
    }

    fn upload(self: *Renderer, name: gl_mod.Uint, img: tw.Image, new_size: bool) void {
        const gl = &self.gl;
        gl.glActiveTexture(gl_mod.TEXTURE0 + upload_unit);
        gl.glBindTexture(gl_mod.TEXTURE_2D, name);
        gl.glPixelStorei(gl_mod.UNPACK_ALIGNMENT, 4);
        gl.glPixelStorei(gl_mod.UNPACK_ROW_LENGTH, 0);
        if (new_size) {
            gl.glTexImage2D(gl_mod.TEXTURE_2D, 0, @intCast(gl_mod.RGBA8), img.w, img.h, 0, gl_mod.RGBA, gl_mod.UNSIGNED_BYTE, img.pixels.ptr);
            setFilter(gl, gl_mod.NEAREST);
        } else {
            gl.glTexSubImage2D(gl_mod.TEXTURE_2D, 0, 0, 0, img.w, img.h, gl_mod.RGBA, gl_mod.UNSIGNED_BYTE, img.pixels.ptr);
        }
        gl.glActiveTexture(gl_mod.TEXTURE0);
        self.stats.uploads += 1;
        self.stats.upload_bytes += @as(u64, @intCast(img.w * img.h)) * 4;
    }

    fn deleteTemps(self: *Renderer) void {
        if (self.temps.items.len == 0) return;
        self.gl.glDeleteTextures(@intCast(self.temps.items.len), self.temps.items.ptr);
        self.temps.clearRetainingCapacity();
    }

    fn evict(self: *Renderer) void {
        var it = self.images.iterator();
        while (it.next()) |e| {
            if (self.frame - e.value_ptr.last_used > keep_frames) {
                self.gl.glDeleteTextures(1, @ptrCast(&e.value_ptr.name));
                self.images.removeByPtr(e.key_ptr);
                // Removing invalidates the iterator: finish next frame.
                return;
            }
        }
    }
};
