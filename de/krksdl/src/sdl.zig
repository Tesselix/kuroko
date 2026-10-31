//! The part of SDL3 the simulator uses, declared by hand.
//!
//! Hand-written instead of @cImport: Zig 0.16's C importer fails on the
//! Apple ARM vector headers that SDL's headers include, and Zig 0.17 removes
//! @cImport. SDL3's ABI is stable within 3.x. Layouts were checked against
//! SDL 3.4.18 with offsetof(); the comptime asserts below keep them honest.

const std = @import("std");

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};
pub const Cursor = opaque {};

pub const FRect = extern struct { x: f32, y: f32, w: f32, h: f32 };
pub const Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
pub extern "c" fn SDL_GetPrimaryDisplay() u32;
pub extern "c" fn SDL_GetDisplayUsableBounds(display: u32, rect: *Rect) bool;
pub extern "c" fn SDL_GetDisplayBounds(display: u32, rect: *Rect) bool;

// ------------------------------------------------------------- events

pub const EVENT_QUIT: u32 = 0x100;
pub const EVENT_WINDOW_RESIZED: u32 = 518;
pub const EVENT_WINDOW_PIXEL_SIZE_CHANGED: u32 = 519;
pub const EVENT_WINDOW_MOUSE_LEAVE: u32 = 525;
pub const EVENT_WINDOW_DISPLAY_SCALE_CHANGED: u32 = 532;
pub const EVENT_KEY_DOWN: u32 = 0x300;
pub const EVENT_KEY_UP: u32 = 0x301;
pub const EVENT_TEXT_INPUT: u32 = 0x303;
pub const EVENT_MOUSE_MOTION: u32 = 0x400;
pub const EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
pub const EVENT_MOUSE_BUTTON_UP: u32 = 0x402;
pub const EVENT_MOUSE_WHEEL: u32 = 0x403;

pub const MouseMotionEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    state: u32,
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
};

pub const MouseButtonEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    button: u8,
    down: bool,
    clicks: u8,
    padding: u8,
    x: f32,
    y: f32,
};

pub const MOUSEWHEEL_FLIPPED: u32 = 1;

pub const MouseWheelEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    x: f32,
    y: f32,
    direction: u32,
    mouse_x: f32,
    mouse_y: f32,
    integer_x: i32,
    integer_y: i32,
};

pub const KeyboardEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    scancode: u32,
    key: u32,
    mod: u16,
    raw: u16,
    down: bool,
    repeat: bool,
};

pub const TextInputEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    _pad: u32,
    text: ?[*:0]const u8,
};

pub const Event = extern union {
    type: u32,
    motion: MouseMotionEvent,
    button: MouseButtonEvent,
    wheel: MouseWheelEvent,
    key: KeyboardEvent,
    text: TextInputEvent,
    padding: [128]u8,
};

comptime {
    std.debug.assert(@sizeOf(Event) == 128);
    std.debug.assert(@offsetOf(MouseMotionEvent, "x") == 28);
    std.debug.assert(@sizeOf(MouseButtonEvent) == 40 and @offsetOf(MouseButtonEvent, "x") == 28);
    std.debug.assert(@sizeOf(MouseWheelEvent) == 56 and @offsetOf(MouseWheelEvent, "direction") == 32 and @offsetOf(MouseWheelEvent, "integer_y") == 48);
    std.debug.assert(@sizeOf(KeyboardEvent) == 40 and @offsetOf(KeyboardEvent, "mod") == 32 and @offsetOf(KeyboardEvent, "repeat") == 37);
    std.debug.assert(@sizeOf(TextInputEvent) == 32 and @offsetOf(TextInputEvent, "text") == 24);
}

// --------------------------------------------------------------- keys

pub const K_RETURN: u32 = 13;
pub const K_ESCAPE: u32 = 27;
pub const K_BACKSPACE: u32 = 8;
pub const K_TAB: u32 = 9;
pub const K_SPACE: u32 = 32;
pub const K_DELETE: u32 = 127;
pub const K_A: u32 = 'a';
pub const K_C: u32 = 'c';
pub const K_F: u32 = 'f';
pub const K_Q: u32 = 'q';
pub const K_V: u32 = 'v';
pub const K_W: u32 = 'w';
pub const K_X: u32 = 'x';
pub const K_Z: u32 = 'z';
const scancode_mask: u32 = 1 << 30;
pub const K_F5: u32 = 62 | scancode_mask;
pub const K_F12: u32 = 69 | scancode_mask;
pub const K_HOME: u32 = 74 | scancode_mask;
pub const K_PAGEUP: u32 = 75 | scancode_mask;
pub const K_END: u32 = 77 | scancode_mask;
pub const K_PAGEDOWN: u32 = 78 | scancode_mask;
pub const K_RIGHT: u32 = 79 | scancode_mask;
pub const K_LEFT: u32 = 80 | scancode_mask;
pub const K_DOWN: u32 = 81 | scancode_mask;
pub const K_UP: u32 = 82 | scancode_mask;
pub const K_KP_ENTER: u32 = 88 | scancode_mask;
pub const K_LGUI: u32 = 227 | scancode_mask;
pub const K_RGUI: u32 = 231 | scancode_mask;

pub const KMOD_SHIFT: u16 = 0x0003;
pub const KMOD_CTRL: u16 = 0x00C0;
pub const KMOD_ALT: u16 = 0x0300;
pub const KMOD_GUI: u16 = 0x0C00;

pub const BUTTON_LEFT: u8 = 1;
pub const BUTTON_MIDDLE: u8 = 2;
pub const BUTTON_RIGHT: u8 = 3;

// ------------------------------------------------------------ setup

pub const INIT_VIDEO: u32 = 0x20;
pub const WINDOW_FULLSCREEN: u64 = 0x1;
pub const WINDOW_RESIZABLE: u64 = 0x20;
pub const WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x2000;
pub const PIXELFORMAT_ARGB8888: u32 = 0x16362004;
pub const TEXTUREACCESS_STREAMING: c_int = 1;
pub const SCALEMODE_NEAREST: c_int = 0;

pub const SystemCursor = enum(c_int) {
    default = 0,
    text = 1,
    ew_resize = 7,
    ns_resize = 8,
    move = 9,
    pointer = 11,
};

// -------------------------------------------------------------- calls

pub extern "c" fn SDL_Init(flags: u32) bool;
pub extern "c" fn SDL_Quit() void;
pub extern "c" fn SDL_GetError() [*:0]const u8;
pub extern "c" fn SDL_GetCurrentVideoDriver() ?[*:0]const u8;
pub extern "c" fn SDL_GetRendererName(r: *Renderer) ?[*:0]const u8;
pub extern "c" fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*Window;
pub extern "c" fn SDL_DestroyWindow(w: *Window) void;
pub extern "c" fn SDL_GetWindowSize(w: *Window, width: *c_int, height: *c_int) bool;
pub extern "c" fn SDL_GetWindowSizeInPixels(w: *Window, width: *c_int, height: *c_int) bool;
pub extern "c" fn SDL_StartTextInput(w: *Window) bool;
pub extern "c" fn SDL_CreateRenderer(w: *Window, name: ?[*:0]const u8) ?*Renderer;
pub extern "c" fn SDL_DestroyRenderer(r: *Renderer) void;
pub extern "c" fn SDL_SetRenderVSync(r: *Renderer, vsync: c_int) bool;
pub extern "c" fn SDL_RenderClear(r: *Renderer) bool;
pub extern "c" fn SDL_RenderTexture(r: *Renderer, t: *Texture, src: ?*const FRect, dst: ?*const FRect) bool;
pub extern "c" fn SDL_RenderPresent(r: *Renderer) bool;
pub extern "c" fn SDL_CreateTexture(r: *Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
pub extern "c" fn SDL_DestroyTexture(t: *Texture) void;
pub extern "c" fn SDL_SetTextureScaleMode(t: *Texture, mode: c_int) bool;
pub extern "c" fn SDL_UpdateTexture(t: *Texture, rect: ?*const anyopaque, pixels: *const anyopaque, pitch: c_int) bool;
// OpenGL context (the GPU path).
pub const WINDOW_OPENGL: u64 = 0x2;
pub const GLContext = opaque {};
pub const GL_DOUBLEBUFFER: c_int = 5;
pub const GL_DEPTH_SIZE: c_int = 6;
pub const GL_CONTEXT_MAJOR_VERSION: c_int = 17;
pub const GL_CONTEXT_MINOR_VERSION: c_int = 18;
pub const GL_CONTEXT_FLAGS: c_int = 19;
pub const GL_CONTEXT_PROFILE_MASK: c_int = 20;
pub const GL_CONTEXT_PROFILE_CORE: c_int = 0x1;
pub const GL_CONTEXT_PROFILE_ES: c_int = 0x4;
pub const GL_CONTEXT_FORWARD_COMPATIBLE_FLAG: c_int = 0x2;
pub extern "c" fn SDL_GL_SetAttribute(attr: c_int, value: c_int) bool;
pub extern "c" fn SDL_GL_CreateContext(w: *Window) ?*GLContext;
pub extern "c" fn SDL_GL_DestroyContext(ctx: *GLContext) bool;
pub extern "c" fn SDL_GL_MakeCurrent(w: *Window, ctx: ?*GLContext) bool;
pub extern "c" fn SDL_GL_SetSwapInterval(interval: c_int) bool;
pub extern "c" fn SDL_GL_SwapWindow(w: *Window) bool;
pub extern "c" fn SDL_GL_GetProcAddress(name: [*:0]const u8) ?*const anyopaque;

pub extern "c" fn SDL_WaitEventTimeout(ev: *Event, timeout_ms: i32) bool;
pub extern "c" fn SDL_PollEvent(ev: *Event) bool;
pub extern "c" fn SDL_GetModState() u16;
pub extern "c" fn SDL_CreateSystemCursor(id: SystemCursor) ?*Cursor;
pub extern "c" fn SDL_SetCursor(c: ?*Cursor) bool;
pub extern "c" fn SDL_DestroyCursor(c: *Cursor) void;

// ------------------------------------------------- local time (libc)

/// `struct tm`, same layout on glibc and macOS (64-bit).
pub const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
pub extern "c" fn time(t: ?*c_long) c_long;
pub extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;
