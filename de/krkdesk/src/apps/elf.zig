//! Reads an ELF binary and tells whether it opens windows, and on which
//! display protocol. Static evidence only, nothing is run:
//!
//! - the display libraries it links (DT_NEEDED),
//! - the functions it calls that create a window (undefined dynamic
//!   symbols such as XCreateWindow, gtk_window_new, SDL_CreateWindow),
//! - the xdg-shell interface name "xdg_wm_base" in its read-only data:
//!   every Wayland app that opens a window carries the protocol code, even
//!   when it loads libwayland-client at run time (Chrome does).
//!
//! Linking a display library alone means "talks to the display server"
//! (xrandr, wlr-randr, grim), not "opens a window", so it never decides.
//!
//! Pure: reads through a `Source` (a slice in tests, a file in the scanner).
//! 64-bit little-endian ELF only (x86_64, aarch64); anything else is `.none`.

const std = @import("std");

pub const Display = enum {
    /// No window evidence.
    none,
    /// Opens windows through X11 only (runs under Xwayland).
    x11,
    /// Opens windows on Wayland (natively, or through a toolkit that can).
    wayland,
    /// A display server or compositor (Xwayland, cage): never an app.
    server,
};

pub const Lib = enum { wayland_client, wayland_server, x11, xcb, xt, gtk, qt_gui, sdl, glfw, egl };

const lib_prefixes = [_]struct { prefix: []const u8, lib: Lib }{
    .{ .prefix = "libwayland-client.so", .lib = .wayland_client },
    .{ .prefix = "libwayland-server.so", .lib = .wayland_server },
    .{ .prefix = "libX11.so", .lib = .x11 },
    .{ .prefix = "libxcb.so", .lib = .xcb },
    .{ .prefix = "libXt.so", .lib = .xt },
    .{ .prefix = "libgtk-3.so", .lib = .gtk },
    .{ .prefix = "libgtk-4.so", .lib = .gtk },
    .{ .prefix = "libQt5Gui.so", .lib = .qt_gui },
    .{ .prefix = "libQt6Gui.so", .lib = .qt_gui },
    .{ .prefix = "libSDL2-2.0.so", .lib = .sdl },
    .{ .prefix = "libSDL3.so", .lib = .sdl },
    .{ .prefix = "libglfw.so", .lib = .glfw },
    .{ .prefix = "libEGL.so", .lib = .egl },
};

/// Window-creating calls. `wayland` marks toolkits that also run on Wayland.
const window_calls = [_]struct { name: []const u8, wayland: bool }{
    .{ .name = "XCreateWindow", .wayland = false },
    .{ .name = "XCreateSimpleWindow", .wayland = false },
    .{ .name = "xcb_create_window", .wayland = false },
    .{ .name = "XtAppInitialize", .wayland = false },
    .{ .name = "XtVaAppInitialize", .wayland = false },
    .{ .name = "XtOpenApplication", .wayland = false },
    .{ .name = "XtAppCreateShell", .wayland = false },
    .{ .name = "gtk_window_new", .wayland = true },
    .{ .name = "gtk_application_window_new", .wayland = true },
    .{ .name = "gtk_window_present", .wayland = true },
    .{ .name = "gtk_widget_show_all", .wayland = true },
    .{ .name = "_ZN12QApplication4execEv", .wayland = true },
    .{ .name = "_ZN15QGuiApplication4execEv", .wayland = true },
    .{ .name = "_ZN7QWidget4showEv", .wayland = true },
    .{ .name = "_ZN7QWindow4showEv", .wayland = true },
    .{ .name = "SDL_CreateWindow", .wayland = true },
    .{ .name = "glfwCreateWindow", .wayland = true },
    .{ .name = "libdecor_decorate", .wayland = true },
};

const xdg_marker = "xdg_wm_base";

pub const Info = struct {
    elf: bool = false,
    libs: std.EnumSet(Lib) = .initEmpty(),
    /// Index into `window_calls` of each call found.
    calls: std.StaticBitSet(window_calls.len) = .initEmpty(),
    xdg_wm_base: bool = false,

    pub fn display(self: Info) Display {
        if (self.libs.contains(.wayland_server)) return .server;
        if (self.xdg_wm_base) return .wayland;
        var x11 = false;
        var it = self.calls.iterator(.{});
        while (it.next()) |i| {
            if (window_calls[i].wayland) return .wayland;
            x11 = true;
        }
        return if (x11) .x11 else .none;
    }

    /// The evidence as short words, for the metadata file: "xdg_wm_base",
    /// then the window calls found.
    pub fn evidence(self: Info, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
        if (self.xdg_wm_base) try out.append(gpa, xdg_marker);
        var it = self.calls.iterator(.{});
        while (it.next()) |i| try out.append(gpa, window_calls[i].name);
    }
};

/// Random access to the binary's bytes.
pub const Source = struct {
    ctx: *anyopaque,
    size: u64,
    readAtFn: *const fn (ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize,

    fn readAt(self: Source, buf: []u8, offset: u64) !void {
        if (offset > self.size or buf.len > self.size - offset) return error.Truncated;
        const n = try self.readAtFn(self.ctx, buf, offset);
        if (n != buf.len) return error.Truncated;
    }

    fn alloc(self: Source, gpa: std.mem.Allocator, offset: u64, len: u64) ![]u8 {
        if (len > max_table) return error.TooLarge;
        const buf = try gpa.alloc(u8, @intCast(len));
        errdefer gpa.free(buf);
        try self.readAt(buf, offset);
        return buf;
    }

    /// A source over bytes in memory (tests).
    pub fn fromSlice(bytes: *const []const u8) Source {
        return .{ .ctx = @ptrCast(@constCast(bytes)), .size = bytes.len, .readAtFn = sliceReadAt };
    }

    fn sliceReadAt(ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
        const bytes: *const []const u8 = @ptrCast(@alignCast(ctx));
        const o: usize = @intCast(offset);
        const n = @min(buf.len, bytes.len - o);
        @memcpy(buf[0..n], bytes.*[o..][0..n]);
        return n;
    }
};

/// Section tables (dynamic, dynstr, dynsym) larger than this are refused.
const max_table = 64 * 1024 * 1024;
const sht_dynamic = 6;
const sht_dynsym = 11;
const dt_needed = 1;

const Section = struct { name: u32, kind: u32, offset: u64, size: u64, link: u32 };

fn section(table: []const u8, i: usize) Section {
    const s = table[i * 64 ..][0..64];
    return .{
        .name = std.mem.readInt(u32, s[0..4], .little),
        .kind = std.mem.readInt(u32, s[4..8], .little),
        .offset = std.mem.readInt(u64, s[24..32], .little),
        .size = std.mem.readInt(u64, s[32..40], .little),
        .link = std.mem.readInt(u32, s[40..44], .little),
    };
}

fn cString(strtab: []const u8, at: u64) []const u8 {
    if (at >= strtab.len) return "";
    const s = strtab[@intCast(at)..];
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

pub const Options = struct {
    /// Search read-only data for the Wayland marker only when the binary
    /// links a display library (fast for the thousand tools in /usr/bin).
    /// `true` for binaries a desktop entry names: they may load everything
    /// at run time.
    always_search_data: bool = false,
};

pub fn inspect(gpa: std.mem.Allocator, src: Source, opts: Options) !Info {
    var info: Info = .{};
    if (src.size < 64) return info;
    var hdr: [64]u8 = undefined;
    try src.readAt(&hdr, 0);
    // \x7fELF, 64-bit, little-endian.
    if (!std.mem.eql(u8, hdr[0..4], "\x7fELF") or hdr[4] != 2 or hdr[5] != 1) return info;
    info.elf = true;
    const shoff = std.mem.readInt(u64, hdr[0x28..0x30], .little);
    const shentsize = std.mem.readInt(u16, hdr[0x3a..0x3c], .little);
    const shnum = std.mem.readInt(u16, hdr[0x3c..0x3e], .little);
    const shstrndx = std.mem.readInt(u16, hdr[0x3e..0x40], .little);
    if (shentsize != 64 or shnum == 0) return info;

    const table = try src.alloc(gpa, shoff, @as(u64, shnum) * 64);
    defer gpa.free(table);

    for (0..shnum) |i| {
        const s = section(table, i);
        if (s.kind != sht_dynamic and s.kind != sht_dynsym) continue;
        if (s.link >= shnum) continue;
        const strs = section(table, s.link);
        const strtab = try src.alloc(gpa, strs.offset, strs.size);
        defer gpa.free(strtab);
        const data = try src.alloc(gpa, s.offset, s.size);
        defer gpa.free(data);
        if (s.kind == sht_dynamic) {
            var off: usize = 0;
            while (off + 16 <= data.len) : (off += 16) {
                const tag = std.mem.readInt(i64, data[off..][0..8], .little);
                if (tag == 0) break;
                if (tag != dt_needed) continue;
                const name = cString(strtab, std.mem.readInt(u64, data[off + 8 ..][0..8], .little));
                for (lib_prefixes) |l| {
                    if (std.mem.startsWith(u8, name, l.prefix)) info.libs.insert(l.lib);
                }
            }
        } else {
            var off: usize = 0;
            while (off + 24 <= data.len) : (off += 24) {
                // Undefined symbols only: the calls this binary makes.
                if (std.mem.readInt(u16, data[off + 6 ..][0..2], .little) != 0) continue;
                const name = cString(strtab, std.mem.readInt(u32, data[off..][0..4], .little));
                if (name.len == 0) continue;
                for (window_calls, 0..) |w, wi| {
                    if (std.mem.eql(u8, name, w.name)) info.calls.set(wi);
                }
            }
        }
    }

    // The xdg-shell marker lives in read-only data.
    const search = opts.always_search_data or info.libs.count() > 0;
    if (search and shstrndx < shnum) {
        const names_sec = section(table, shstrndx);
        const names = try src.alloc(gpa, names_sec.offset, names_sec.size);
        defer gpa.free(names);
        for (0..shnum) |i| {
            const s = section(table, i);
            const name = cString(names, s.name);
            // .rodata, .rodata.str1.1 (merged strings), .data.rel.ro.
            if (!std.mem.startsWith(u8, name, ".rodata") and !std.mem.eql(u8, name, ".data.rel.ro")) continue;
            if (try contains(src, s.offset, s.size, xdg_marker)) {
                info.xdg_wm_base = true;
                break;
            }
        }
    }
    return info;
}

/// Searches a byte range in chunks; chunks overlap by the pattern's length.
fn contains(src: Source, offset: u64, size: u64, pattern: []const u8) !bool {
    var buf: [256 * 1024]u8 = undefined;
    var pos: u64 = 0;
    while (pos < size) {
        const n: usize = @intCast(@min(buf.len, size - pos));
        try src.readAt(buf[0..n], offset + pos);
        if (std.mem.indexOf(u8, buf[0..n], pattern) != null) return true;
        if (offset + pos + n >= offset + size) break;
        pos += n - @min(n, pattern.len - 1);
    }
    return false;
}

// Fixtures: tiny aarch64 binaries built by testdata/gen.sh.
fn fixture(comptime name: []const u8) !Info {
    const bytes: []const u8 = @embedFile("testdata/" ++ name);
    return inspect(std.testing.allocator, Source.fromSlice(&bytes), .{});
}

test "a Wayland app is found by its xdg_wm_base marker" {
    const info = try fixture("wayland-app");
    try std.testing.expect(info.elf);
    try std.testing.expect(info.libs.contains(.wayland_client));
    try std.testing.expect(info.xdg_wm_base);
    try std.testing.expectEqual(Display.wayland, info.display());
}

test "an X11-only app is found by its window call" {
    const info = try fixture("x11-app");
    try std.testing.expect(info.libs.contains(.x11));
    try std.testing.expect(!info.xdg_wm_base);
    try std.testing.expectEqual(Display.x11, info.display());
    var ev: std.ArrayList([]const u8) = .empty;
    defer ev.deinit(std.testing.allocator);
    try info.evidence(&ev, std.testing.allocator);
    try std.testing.expectEqualStrings("XCreateWindow", ev.items[0]);
}

test "linking X11 without a window call is not an app (xset, xrandr)" {
    const info = try fixture("x11-tool");
    try std.testing.expect(info.libs.contains(.x11));
    try std.testing.expectEqual(Display.none, info.display());
}

test "a compositor is a server, not an app" {
    const info = try fixture("server");
    try std.testing.expectEqual(Display.server, info.display());
}

test "a GTK app counts as Wayland" {
    const info = try fixture("gtk-app");
    try std.testing.expectEqual(Display.wayland, info.display());
}

test "not an ELF file, or a truncated one" {
    const text: []const u8 = "#!/bin/sh\n# a shell script, long enough for an ELF header\nexec /usr/bin/true\n";
    const a = try inspect(std.testing.allocator, Source.fromSlice(&text), .{});
    try std.testing.expect(!a.elf);
    const full: []const u8 = @embedFile("testdata/x11-app");
    const cut: []const u8 = full[0..200];
    try std.testing.expectError(error.Truncated, inspect(std.testing.allocator, Source.fromSlice(&cut), .{}));
}
