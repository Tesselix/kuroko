//! Input events as the compositor core sees them. A backend (wlroots on
//! Linux, the simulator on macOS) translates its native events into these.

const std = @import("std");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,

    pub fn none(m: Mods) bool {
        return !m.shift and !m.ctrl and !m.alt and !m.super;
    }
};

pub const Button = enum(u8) { left, middle, right };

pub const Key = enum(u16) {
    unknown,
    escape,
    enter,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    space,
    super,
    f5,
    f12,
    a,
    c,
    f,
    q,
    v,
    w,
    x,
    z,
};

pub const WheelSource = enum(u8) {
    /// A notched wheel. Values are in notches.
    wheel,
    /// A touchpad or smooth wheel. Values are in logical pixels and follow
    /// the fingers (natural direction is applied by the compositor).
    touchpad,
};

/// Wheel motion. Positive `dy` scrolls forward (toward the end of the
/// document); the backend has already removed any direction flip done by
/// the host system, and the compositor applies Tesselix's own default.
pub const Wheel = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    source: WheelSource = .wheel,
    /// Modifiers held during the motion (filled by the backend).
    mods: Mods = .{},
    /// Speed band and notch rate (filled by the compositor's input path).
    band: @import("wheel.zig").Band = .slow,
    rate: f32 = 0,
};

pub const Text = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn from(s: []const u8) Text {
        var t: Text = .{};
        const n: u8 = @intCast(@min(s.len, t.buf.len));
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = n;
        return t;
    }
};

pub const Event = union(enum) {
    pointer_motion: struct { x: f32, y: f32 },
    /// `mods` are the modifier keys held at the click (Shift+click).
    pointer_button: struct { button: Button, pressed: bool, x: f32, y: f32, mods: Mods = .{} },
    pointer_leave,
    wheel: Wheel,
    /// `code` is the Linux (evdev) key code, 0 when unknown: Wayland apps
    /// get every key by its code and make text with their keymap.
    key: struct { key: Key, pressed: bool, mods: Mods, repeat: bool = false, code: u16 = 0 },
    text: Text,
};

/// The cursor shape the core asks the backend to show.
pub const Cursor = enum { arrow, hand, text, resize_ew, resize_ns, grab };
