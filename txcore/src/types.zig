//! Tesselix structure type IDs and shared message structures.
//!
//! Open question (Top-Level Design): one 16-bit space or split by component.
//! For now the high byte names the component:
//!   0x01xx  assets (fonts, icons)
//!   0x02xx  compositor → desktop services (scene graph)
//!   0x03xx  desktop services → compositor (actions)
//!   0x04xx  widget protocol (Mode B), reserved
//!   0x05xx  app registry (txdesk's apps.tslx)
//!   0x7Fxx  tests

const std = @import("std");
const format = @import("format.zig");

pub const font_atlas: u16 = 0x0101;
pub const scene_window: u16 = 0x0201;
pub const apps_header: u16 = 0x0501;
pub const app_entry: u16 = 0x0502;
pub const scan_entry: u16 = 0x0503;
pub const search_path: u16 = 0x0504;

/// Every type this build understands, with its newest version.
pub const known = [_]format.Known{
    .{ .type_id = font_atlas, .max_version = 1 },
    .{ .type_id = scene_window, .max_version = 1 },
    .{ .type_id = apps_header, .max_version = 1 },
    .{ .type_id = app_entry, .max_version = 1 },
    .{ .type_id = scan_entry, .max_version = 1 },
    .{ .type_id = search_path, .max_version = 1 },
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

// ------------------------------------------------------- app registry
//
// apps.tslx, kept by txdesk: one AppsHeader, then AppEntry, ScanEntry and
// SearchPath records in any order. Enums are non-exhaustive: a value this
// build does not know reads as itself, never as illegal behavior.

pub const AppsHeader = extern struct {
    /// Goes up by one with every save.
    save_count: u64,
    /// End of the last scan, Unix seconds.
    last_scan_s: i64,
};

pub const AppStatus = enum(u8) { installed, missing, hidden, _ };
pub const AppDisplay = enum(u8) { unknown, wayland, x11, _ };
pub const PackageManager = enum(u8) { manual, apt, snap, flatpak, appimage, _ };

/// One app. Trailing data: `string_count` strings, each a u16 length then
/// the bytes, in `AppString` order; lists hold their items separated by
/// NUL. A newer writer may add strings at the end; missing ones are empty.
pub const AppEntry = extern struct {
    status: AppStatus,
    display: AppDisplay,
    manager: PackageManager,
    _pad0: u8 = 0,
    string_count: u32,
    /// The binary as last seen, to notice an upgrade without reading it.
    binary_size: u64,
    binary_mtime_ns: i64,
    binary_inode: u64,
    /// Unix seconds; 0 while installed.
    missing_since_s: i64,
    first_seen_s: i64,
};

pub const AppString = enum(u16) {
    id,
    name,
    /// The real binary, symlinks resolved: the app's key.
    binary,
    /// List: absolute command and arguments; desktop field codes (%U) kept.
    exec,
    icon,
    desktop_entry,
    /// List.
    groups,
    /// List: why it counts as graphical.
    evidence,
    package,
    version,
    available_version,
};

pub const ScanKind = enum(u8) { binary, desktop_entry, _ };
pub const ScanVerdict = enum(u8) {
    /// Not graphical (or a desktop entry a launcher does not show).
    none,
    /// Talks to the display server without opening windows (xrandr).
    display_client,
    /// A display server or compositor (Xwayland, cage).
    server,
    /// Opens windows through X11 only; skipped unless asked for.
    x11_only,
    /// Graphical: has an AppEntry.
    app,
    _,
};
pub const ScanOverride = enum(u8) { none, always_skip, always_app, _ };

/// A file the scanner has looked at, so the next scan skips it while it is
/// unchanged. Trailing data: the absolute path.
pub const ScanEntry = extern struct {
    kind: ScanKind,
    verdict: ScanVerdict,
    /// Set by the user (the Apps tool); the scanner never changes it.
    override: ScanOverride,
    _pad0: u8 = 0,
    path_len: u32,
    size: u64,
    mtime_ns: i64,
    inode: u64,
};

pub const SearchKind = enum(u8) { binaries, desktop_entries, _ };
pub const SearchOrigin = enum(u8) { default, provider, user, _ };

/// A folder the scanner walks. Trailing data: the absolute path.
pub const SearchPath = extern struct {
    kind: SearchKind,
    /// 1 = the folder's own files; /opt uses 3 (/opt/google/chrome/chrome).
    depth: u8,
    enabled: u8,
    origin: SearchOrigin,
    path_len: u32,
};

comptime {
    format.checkPortable(AppsHeader);
    format.checkPortable(AppEntry);
    format.checkPortable(ScanEntry);
    format.checkPortable(SearchPath);
    std.debug.assert(@sizeOf(AppsHeader) == 16);
    std.debug.assert(@sizeOf(AppEntry) == 48);
    std.debug.assert(@sizeOf(ScanEntry) == 32);
    std.debug.assert(@sizeOf(SearchPath) == 8);
}
