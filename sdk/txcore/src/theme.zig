//! Colors and theme roles. Widgets and chrome use roles, never hard-coded
//! colors, so light/dark, contrast and the user's accent apply everywhere.

const std = @import("std");

/// 0xAARRGGBB, straight (not premultiplied) alpha.
pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex), .a = 255 };
    }
    pub fn rgba(hex: u24, a: u8) Color {
        var c = rgb(hex);
        c.a = a;
        return c;
    }
    pub fn withAlpha(c: Color, a: u8) Color {
        var out = c;
        out.a = a;
        return out;
    }
    /// Scales alpha by `f` in 0..1 (for fades).
    pub fn fade(c: Color, f: f32) Color {
        var out = c;
        const a: f32 = @as(f32, @floatFromInt(c.a)) * std.math.clamp(f, 0, 1);
        out.a = @intFromFloat(@round(a));
        return out;
    }
    pub fn mix(a: Color, b: Color, t: f32) Color {
        const tt = std.math.clamp(t, 0, 1);
        return .{
            .r = mixByte(a.r, b.r, tt),
            .g = mixByte(a.g, b.g, tt),
            .b = mixByte(a.b, b.b, tt),
            .a = mixByte(a.a, b.a, tt),
        };
    }
    fn mixByte(x: u8, y: u8, t: f32) u8 {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        return @intFromFloat(@round(fx + (fy - fx) * t));
    }
    pub fn toU32(c: Color) u32 {
        return @bitCast(c);
    }
};

pub const Role = enum {
    background, // desktop behind windows
    surface, // window content
    surface_alt, // panels, fields, cards
    surface_sunken, // tracks, wells
    text,
    text_dim,
    text_disabled,
    accent,
    accent_hover,
    accent_text, // text on accent
    border,
    hairline,
    chrome, // title bar, unfocused
    chrome_focused,
    chrome_text,
    danger, // errors, elevated-privilege frame (reserved red)
    success,
    viewport_marker, // orange (document map)
    center_marker, // green, semi-transparent
    footprint,
    focus_ring,
    shadow,
    overlay_tint, // launcher tint
};

pub const Theme = struct {
    dark: bool,
    colors: std.EnumArray(Role, Color),

    pub fn get(self: *const Theme, role: Role) Color {
        return self.colors.get(role);
    }

    pub fn light() Theme {
        return .{ .dark = false, .colors = .init(.{
            .background = .rgb(0xDCE3EC),
            .surface = .rgb(0xFBFCFD),
            .surface_alt = .rgb(0xF1F4F8),
            .surface_sunken = .rgb(0xE4E9F0),
            .text = .rgb(0x1E2733),
            .text_dim = .rgb(0x5C6878),
            .text_disabled = .rgb(0xA3ADBA),
            .accent = .rgb(0x2F6BD0),
            .accent_hover = .rgb(0x255CB8),
            .accent_text = .rgb(0xFFFFFF),
            .border = .rgb(0xC3CCD8),
            .hairline = .rgb(0xB4BFCD),
            .chrome = .rgb(0xE9EDF2),
            .chrome_focused = .rgb(0xF6F8FA),
            .chrome_text = .rgb(0x2A3442),
            .danger = .rgb(0xC9302C),
            .success = .rgb(0x2E8B57),
            .viewport_marker = .rgb(0xE07A1F),
            .center_marker = .rgba(0x1F9D5A, 150),
            .footprint = .rgba(0x7A8BA3, 140),
            .focus_ring = .rgb(0x2F6BD0),
            .shadow = .rgba(0x0B1626, 40),
            .overlay_tint = .rgba(0xE9EEF5, 248),
        }) };
    }

    pub fn darkTheme() Theme {
        return .{ .dark = true, .colors = .init(.{
            .background = .rgb(0x161C24),
            .surface = .rgb(0x1F2630),
            .surface_alt = .rgb(0x27303B),
            .surface_sunken = .rgb(0x161C24),
            .text = .rgb(0xE3E8EF),
            .text_dim = .rgb(0x9AA6B5),
            .text_disabled = .rgb(0x5B6676),
            .accent = .rgb(0x5B95EE),
            .accent_hover = .rgb(0x74A6F2),
            .accent_text = .rgb(0x0E1520),
            .border = .rgb(0x3A4553),
            .hairline = .rgb(0x465262),
            .chrome = .rgb(0x232B35),
            .chrome_focused = .rgb(0x2B3440),
            .chrome_text = .rgb(0xDCE2EA),
            .danger = .rgb(0xE5534B),
            .success = .rgb(0x3FB27F),
            .viewport_marker = .rgb(0xF0953A),
            .center_marker = .rgba(0x3CC47A, 160),
            .footprint = .rgba(0x8FA0B8, 140),
            .focus_ring = .rgb(0x5B95EE),
            .shadow = .rgba(0x000000, 90),
            .overlay_tint = .rgba(0x1A212B, 248),
        }) };
    }
};
