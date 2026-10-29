//! Kuroko structure type IDs and shared message structures.
//!
//! Open question (Top-Level Design): one 16-bit space or split by component.
//! For now the high byte names the component:
//!   0x01xx  assets (fonts, icons)
//!   0x02xx  compositor → desktop services (scene graph)
//!   0x03xx  desktop services → compositor (actions)
//!   0x04xx  widget protocol (Mode B), reserved
//!   0x05xx  app registry (txdesk's apps.krkde)
//!   0x06xx  trust marks (txdesk's trust.krkde)
//!   0x08xx  facts and influence (facts.krkde, focus.krkde), app icons
//!           (icons.krkde)
//!   0x7Fxx  tests

const std = @import("std");
const format = @import("format.zig");

pub const font_atlas: u16 = 0x0101;
pub const scene_window: u16 = 0x0201;
pub const desk_request: u16 = 0x0202;
pub const scene_identity: u16 = 0x0203;
pub const trust_request: u16 = 0x0204;
pub const scene_session: u16 = 0x0205;
pub const desk_app: u16 = 0x0301;
pub const desk_trust: u16 = 0x0302;
pub const desk_notice: u16 = 0x0303;
pub const apps_header: u16 = 0x0501;
pub const app_entry: u16 = 0x0502;
pub const scan_entry: u16 = 0x0503;
pub const search_path: u16 = 0x0504;
pub const trust_header: u16 = 0x0601;
pub const trust_mark: u16 = 0x0602;
pub const facts_header: u16 = 0x0801;
pub const fact_use: u16 = 0x0802;
pub const influence_header: u16 = 0x0811;
pub const influence_entry: u16 = 0x0812;
pub const icon_image: u16 = 0x0821;

/// Every type this build understands, with its newest version.
pub const known = [_]format.Known{
    .{ .type_id = font_atlas, .max_version = 1 },
    .{ .type_id = scene_window, .max_version = 1 },
    .{ .type_id = desk_request, .max_version = 1 },
    .{ .type_id = desk_app, .max_version = 1 },
    .{ .type_id = apps_header, .max_version = 1 },
    .{ .type_id = app_entry, .max_version = 1 },
    .{ .type_id = scan_entry, .max_version = 1 },
    .{ .type_id = search_path, .max_version = 1 },
    .{ .type_id = scene_identity, .max_version = 1 },
    .{ .type_id = trust_request, .max_version = 1 },
    .{ .type_id = desk_trust, .max_version = 1 },
    .{ .type_id = trust_header, .max_version = 1 },
    .{ .type_id = trust_mark, .max_version = 1 },
    .{ .type_id = desk_notice, .max_version = 1 },
    .{ .type_id = scene_session, .max_version = 1 },
    .{ .type_id = icon_image, .max_version = 1 },
    .{ .type_id = facts_header, .max_version = 1 },
    .{ .type_id = fact_use, .max_version = 1 },
    .{ .type_id = influence_header, .max_version = 1 },
    .{ .type_id = influence_entry, .max_version = 1 },
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
// apps.krkde, kept by txdesk: one AppsHeader, then AppEntry, ScanEntry and
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

// ----------------------------------------- app registry → compositor
//
// txdesk keeps the registry; the compositor keeps a read-only copy of what
// it shows. txdesk sends a snapshot when it connects (and when asked), and
// after every save of apps.krkde the apps that changed, then a `saved`
// marker with the save count, even when no app changed. A count that skips
// one means something was lost: the compositor asks for a snapshot.

pub const DeskAppKind = enum(u8) {
    snapshot_begin,
    /// One app, new or changed (in a snapshot or after a save).
    app,
    snapshot_end,
    /// The app left the registry (the user forgot it). Strings: the key.
    removed,
    /// End of the changes of one save.
    saved,
    _,
};

pub const desk_app_update: u8 = 1; // flag: a newer version is available

/// Trailing data (kind .app): `string_count` strings in `DeskAppString`
/// order (see format.appendString).
pub const DeskApp = extern struct {
    kind: DeskAppKind,
    status: AppStatus,
    flags: u8,
    _pad0: u8 = 0,
    string_count: u32,
    save_count: u64,
};

pub const DeskAppString = enum(u16) {
    /// The binary: the app's key.
    key,
    id,
    name,
    /// Absolute path of the icon file, or "".
    icon,
    /// List: the command, absolute; desktop field codes (%U) kept.
    exec,
    version,
    available_version,
};

pub const DeskRequestKind = enum(u8) { app_snapshot, trust_snapshot, _ };

/// Compositor → txdesk.
pub const DeskRequest = extern struct {
    kind: DeskRequestKind,
    _pad0: [7]u8 = @splat(0),
};

comptime {
    format.checkPortable(DeskApp);
    format.checkPortable(DeskRequest);
    std.debug.assert(@sizeOf(DeskApp) == 16);
    std.debug.assert(@sizeOf(DeskRequest) == 8);
}

// ------------------------------------------------------------- trust
//
// Trust is the app and the object open in its window together
// (docs/user-signals.md). The user marks apps, files and folders; txdesk
// keeps the marks in trust.krkde (one TrustHeader, then TrustMark records)
// and sends them to the compositor (DeskTrust), which decides each
// window's trust with the shared rules in txcore/src/trust.zig.

pub const Trust = enum(u8) {
    /// Nothing known (no mark, and the rule does not say).
    unknown,
    untrusted,
    trusted,
    _,
};
pub const TrustSubject = enum(u8) { app, file, folder, _ };

pub const TrustHeader = extern struct {
    /// Goes up by one with every save.
    save_count: u64,
};

/// One mark set by the user. Trailing data: the absolute path (an app's
/// binary, symlinks resolved; a file; a folder).
pub const TrustMark = extern struct {
    subject: TrustSubject,
    level: Trust,
    _pad0: u16 = 0,
    path_len: u32,
    /// Unix seconds when it was set.
    set_s: i64,
    /// An app's signature when it was marked: SHA-256 of its binary.
    /// Zeros for files and folders.
    digest: [32]u8,
};

pub const DeskTrustKind = enum(u8) {
    snapshot_begin,
    /// A mark, new or changed.
    mark,
    /// A mark the user took back.
    cleared,
    snapshot_end,
    _,
};

/// txdesk → compositor: the marks. A snapshot when it connects (or is
/// asked), then each change. Trailing data: the path.
pub const DeskTrust = extern struct {
    kind: DeskTrustKind,
    subject: TrustSubject,
    level: Trust,
    _pad0: u8 = 0,
    path_len: u32,
};

pub const TrustAction = enum(u8) { set, clear, _ };

/// Compositor → txdesk: the user set or took back a mark (the window's
/// Security menu). txdesk saves it and sends it back as a DeskTrust.
/// Trailing data: the path.
pub const TrustRequest = extern struct {
    action: TrustAction,
    subject: TrustSubject,
    level: Trust,
    _pad0: u8 = 0,
    path_len: u32,
};

/// Compositor → services: who a window belongs to, sent before its
/// `opened` SceneWindow and again when its trust changes. Trailing data:
/// the binary (/proc/<pid>/exe), "" for Kuroko's own in-process apps.
pub const SceneIdentity = extern struct {
    window_id: u64,
    /// 0 when unknown (Kuroko's own apps in the simulator).
    pid: i32,
    /// The window's trust as the compositor decided it.
    trust: Trust,
    /// The app's part of it.
    app_trust: Trust,
    _pad0: u16 = 0,
    exe_len: u32,
    _pad1: u32 = 0,
};

comptime {
    format.checkPortable(TrustHeader);
    format.checkPortable(TrustMark);
    format.checkPortable(DeskTrust);
    format.checkPortable(TrustRequest);
    format.checkPortable(SceneIdentity);
    std.debug.assert(@sizeOf(TrustHeader) == 8);
    std.debug.assert(@sizeOf(TrustMark) == 48);
    std.debug.assert(@sizeOf(DeskTrust) == 8);
    std.debug.assert(@sizeOf(TrustRequest) == 8);
    std.debug.assert(@sizeOf(SceneIdentity) == 24);
}

// ------------------------------------------------- facts and influence
//
// Top-Level Design, "Influence files". The recorder (txdesk) writes the
// facts: what was used, when, for how long (facts.krkde). A predictor reads
// them and writes what the desktop should offer (focus.krkde): the Focus and
// Recent lists of the launcher. The compositor only reads the influence
// file, when txdesk says it changed (DeskNotice), and freezes it while the
// launcher is visible.

pub const FactsHeader = extern struct {
    save_count: u64,
};

/// One use of an app: a window's life (an episode). Trailing data: the app
/// (its binary, or its app id for Kuroko's own apps), then the object
/// open in it ("" when unknown).
pub const FactUse = extern struct {
    /// Unix seconds.
    opened_s: i64,
    /// Unix seconds; for a window still open when saved, the save time.
    closed_s: i64,
    /// Seconds with keyboard focus.
    focused_s: u32,
    app_len: u16,
    object_len: u16,
};

pub const InfluenceSource = enum(u8) { predictor, ai, _ };

pub const InfluenceHeader = extern struct {
    /// Unix seconds.
    written_s: i64,
    source: InfluenceSource,
    _pad0: [7]u8 = @splat(0),
};

pub const InfluenceList = enum(u8) { focus, recent, _ };

/// Why an entry is offered; the reader turns it into a short text.
pub const InfluenceReason = enum(u8) {
    /// Real use: `value` is minutes with keyboard focus in the last 7 days.
    used,
    /// A cycle that is due: `value` is on how many days it was seen.
    cycle,
    /// Opened recently: `value` is when (Unix seconds).
    opened,
    _,
};

/// One entry, in list order. A reference, never free content: the app as
/// in FactUse, and an object from the facts. The reader drops what it
/// cannot resolve. Trailing data: the app, then the object.
pub const InfluenceEntry = extern struct {
    list: InfluenceList,
    reason: InfluenceReason,
    app_len: u16,
    object_len: u16,
    _pad0: u16 = 0,
    value: i64,
};

/// Compositor → services: the session's switches, in every snapshot and
/// when they change.
pub const SceneSession = extern struct {
    /// "Pause learning" (top bar) is off: the recorder may record. When 0,
    /// nothing is recorded, and uses in progress end.
    learning: u8,
    _pad0: [7]u8 = @splat(0),
};

pub const DeskNoticeKind = enum(u8) {
    /// focus.krkde was written again: read it when next needed.
    influence_changed,
    /// icons.krkde was written again.
    icons_changed,
    _,
};

/// txdesk → compositor: something changed that the compositor reads itself.
/// An app's icon, drawn to pixels by txdesk (icons.krkde), so the
/// compositor never decodes an image file. Square, the icon centered.
/// Trailing data: the app's key (its binary), then w * h pixels, 0xAARRGGBB
/// little-endian, straight alpha.
pub const IconImage = extern struct {
    w: u16,
    h: u16,
    key_len: u16,
    _pad0: u16 = 0,
    /// The icon file's time when drawn, to notice a new icon.
    source_mtime_ns: i64,
};

pub const DeskNotice = extern struct {
    kind: DeskNoticeKind,
    _pad0: [7]u8 = @splat(0),
};

comptime {
    format.checkPortable(FactsHeader);
    format.checkPortable(FactUse);
    format.checkPortable(InfluenceHeader);
    format.checkPortable(InfluenceEntry);
    format.checkPortable(DeskNotice);
    format.checkPortable(SceneSession);
    format.checkPortable(IconImage);
    std.debug.assert(@sizeOf(IconImage) == 16);
    std.debug.assert(@sizeOf(SceneSession) == 8);
    std.debug.assert(@sizeOf(FactsHeader) == 8);
    std.debug.assert(@sizeOf(FactUse) == 24);
    std.debug.assert(@sizeOf(InfluenceHeader) == 16);
    std.debug.assert(@sizeOf(InfluenceEntry) == 16);
    std.debug.assert(@sizeOf(DeskNotice) == 8);
}
