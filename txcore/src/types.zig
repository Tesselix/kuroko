//! Tesselix structure type IDs and shared message structures.
//!
//! Open question (Top-Level Design): one 16-bit space or split by component.
//! For now the high byte names the component:
//!   0x01xx  assets (fonts, icons)
//!   0x02xx  compositor → desktop services (scene graph)
//!   0x03xx  desktop services → compositor (actions)
//!   0x04xx  widget protocol (Mode B), reserved
//!   0x7Fxx  tests

const std = @import("std");
const format = @import("format.zig");

pub const font_atlas: u16 = 0x0101;
pub const scene_window: u16 = 0x0201;

/// Every type this build understands, with its newest version.
pub const known = [_]format.Known{
    .{ .type_id = font_atlas, .max_version = 1 },
    .{ .type_id = scene_window, .max_version = 1 },
};

/// Window status shown on the bottom border (Top-Level Design, "Bottom
/// border: status line").
pub const Status = enum(u8) { normal, progress, working, failed };

pub const SceneKind = enum(u8) {
    opened,
    closed,
    changed,
    /// Begins a full snapshot; a subscriber that fell behind discards its
    /// state and rebuilds from the records that follow.
    snapshot_begin,
    snapshot_end,
};

/// A scene-graph delta for one window. Trailing data: title bytes, then
/// app_id bytes (UTF-8).
pub const SceneWindow = extern struct {
    kind: SceneKind,
    status: Status,
    focused: u8,
    shelved: u8,
    _pad0: u32 = 0,
    window_id: u64,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    progress: f32,
    title_len: u16,
    app_id_len: u16,
};

comptime {
    format.checkPortable(SceneWindow);
    std.debug.assert(@sizeOf(SceneWindow) == 40);
}

/// Font atlas asset (written by tools/fontgen, read by txwidgets).
/// Trailing data: `glyph_count` FontGlyph entries, then the alpha bitmap.
pub const FontAtlas = extern struct {
    pixel_size: u16,
    glyph_count: u16,
    ascent: i16,
    descent: i16,
    line_height: u16,
    weight: u16,
    _pad0: u32 = 0,
};

pub const FontGlyph = extern struct {
    codepoint: u32,
    /// Advance in 1/64 pixel.
    advance: u16,
    w: u8,
    h: u8,
    bearing_x: i8,
    /// Distance from the baseline up to the top of the bitmap.
    bearing_y: i8,
    _pad0: u16 = 0,
    offset: u32,
};

comptime {
    format.checkPortable(FontAtlas);
    format.checkPortable(FontGlyph);
    std.debug.assert(@sizeOf(FontAtlas) == 16);
    std.debug.assert(@sizeOf(FontGlyph) == 16);
}
