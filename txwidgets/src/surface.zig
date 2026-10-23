//! What a framework window offers the compositor.
//!
//! On Linux a window reaches the compositor through Wayland (xdg-shell
//! buffers) plus the Tesselix protocol for menus, status and content size.
//! In the simulator, apps run in-process and the compositor calls this
//! interface directly. Keep it to what the real protocols can carry.

const std = @import("std");
const core = @import("txcore");
const Canvas = @import("canvas.zig").Canvas;

pub const Status = struct {
    kind: core.types.Status = .normal,
    /// 0..1 for `progress`.
    progress: f32 = 0,
};

/// How the compositor shows a window (Wayland: xdg_toplevel states).
pub const WindowState = packed struct(u8) {
    /// Has the keyboard.
    focused: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// In a tile: every edge is fixed by its neighbours.
    tiled: bool = false,
    _pad: u4 = 0,
};

pub const Surface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        title: *const fn (*anyopaque) []const u8,
        app_id: *const fn (*anyopaque) []const u8,
        /// Top-level menu labels, shown in the compositor's title bar.
        menu: *const fn (*anyopaque) []const []const u8,
        /// Optimal content size in logical px (feeds attention tiling).
        optimal_size: *const fn (*anyopaque) core.Size,
        /// The content can use more room than its optimal size (reflowable
        /// text, documents); the tiling gives such windows the leftover.
        growable: *const fn (*anyopaque) bool,
        /// The compositor decides the size (Wayland `configure`).
        configure: *const fn (*anyopaque, core.Size, i32) void,
        /// Theme changed (Mode B: the "theme changed" message).
        set_dark: *const fn (*anyopaque, bool) void,
        draw: *const fn (*anyopaque, *Canvas) void,
        /// Pointer coordinates are local to the content area.
        input: *const fn (*anyopaque, core.input.Event, i64) void,
        /// Returns true when the window needs to be drawn again.
        tick: *const fn (*anyopaque, i64) bool,
        status: *const fn (*anyopaque) Status,
        cursor: *const fn (*anyopaque) core.input.Cursor,
        /// The app asked to close (e.g. a Quit button).
        wants_close: *const fn (*anyopaque) bool,
        /// The compositor closed the window; free everything.
        destroy: *const fn (*anyopaque) void,
        /// The window's state changed (focus, maximized, ...).
        window_state: *const fn (*anyopaque, WindowState) void = noState,
        /// The user closes the window. True: the app was asked and closes
        /// in its own time (it may ask to save first); `wants_close` turns
        /// true when it is done. False: close it now.
        request_close: *const fn (*anyopaque) bool = closeNow,
    };

    fn noState(_: *anyopaque, _: WindowState) void {}
    fn closeNow(_: *anyopaque) bool {
        return false;
    }

    pub fn title(s: Surface) []const u8 {
        return s.vtable.title(s.ptr);
    }
    pub fn appId(s: Surface) []const u8 {
        return s.vtable.app_id(s.ptr);
    }
    pub fn menu(s: Surface) []const []const u8 {
        return s.vtable.menu(s.ptr);
    }
    pub fn optimalSize(s: Surface) core.Size {
        return s.vtable.optimal_size(s.ptr);
    }
    pub fn growable(s: Surface) bool {
        return s.vtable.growable(s.ptr);
    }
    pub fn configure(s: Surface, size: core.Size, scale: i32) void {
        s.vtable.configure(s.ptr, size, scale);
    }
    pub fn setDark(s: Surface, dark: bool) void {
        s.vtable.set_dark(s.ptr, dark);
    }
    pub fn draw(s: Surface, c: *Canvas) void {
        s.vtable.draw(s.ptr, c);
    }
    pub fn input(s: Surface, ev: core.input.Event, now: i64) void {
        s.vtable.input(s.ptr, ev, now);
    }
    pub fn tick(s: Surface, now: i64) bool {
        return s.vtable.tick(s.ptr, now);
    }
    pub fn status(s: Surface) Status {
        return s.vtable.status(s.ptr);
    }
    pub fn cursor(s: Surface) core.input.Cursor {
        return s.vtable.cursor(s.ptr);
    }
    pub fn wantsClose(s: Surface) bool {
        return s.vtable.wants_close(s.ptr);
    }
    pub fn destroy(s: Surface) void {
        s.vtable.destroy(s.ptr);
    }
    pub fn windowState(s: Surface, st: WindowState) void {
        s.vtable.window_state(s.ptr, st);
    }
    pub fn requestClose(s: Surface) bool {
        return s.vtable.request_close(s.ptr);
    }
};
