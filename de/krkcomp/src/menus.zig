//! The menus the top-bar icons open (Top-Level Design: "Top bar and
//! control center"): settings, the control center, the device center and
//! language. Pure: what the system reports (`System`), the layout of each
//! menu as a list of parts, hit testing, and drawing.
//!
//! The compositor changes `System` at once when the user acts, and will
//! send the matching command to the desktop service, which confirms or
//! corrects it; it never waits for the answer.

const std = @import("std");
const core = @import("krkcore");
const tw = @import("krkwidgets");
const glyphs = @import("glyphs.zig");
const shell = @import("shell.zig");

const Rect = core.Rect;
const Theme = core.Theme;
const Canvas = tw.Canvas;
const font = tw.font;

// --------------------------------------------------------------- system

/// A short name, stored in place (no allocation).
pub const Name = struct {
    buf: [40]u8 = @splat(0),
    len: u8 = 0,

    pub fn of(s: []const u8) Name {
        var n: Name = .{};
        n.len = @intCast(@min(s.len, n.buf.len));
        @memcpy(n.buf[0..n.len], s[0..n.len]);
        return n;
    }

    pub fn get(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The connections the control center turns on and off. A wired network
/// is a device (an adapter) in the device center.
pub const Radio = enum { wifi, bluetooth };

pub const RadioState = struct {
    on: bool = false,
};

/// A Wi-Fi network in range.
pub const Network = struct {
    name: Name,
    /// 0..3 arcs.
    signal: u8 = 3,
    secured: bool = true,
};

/// Sound output or input.
pub const Dir = enum { output, input };

pub const Audio = struct {
    /// 0..1.
    level: f32 = 0.7,
    muted: bool = false,
    devices: [max_audio]Name = @splat(.{}),
    len: u8 = 0,
    /// The device in use.
    current: u8 = 0,
};

pub const DeviceKind = enum { bluetooth, usb, wired, share, remote_disk };

/// Paused: still attached, but not in use (a share stops syncing, a
/// headset sleeps); resuming needs no new connection.
pub const DeviceState = enum { connected, paused, disconnected, disabled };

/// A device's property, as the system reports it: a fact to read, or a
/// switch the user can change.
pub const Prop = struct {
    label: Name,
    value: union(enum) {
        info: Name,
        toggle: bool,
    },
};

pub const Device = struct {
    kind: DeviceKind,
    name: Name,
    state: DeviceState = .disconnected,
    props: [max_props]Prop = undefined,
    props_len: u8 = 0,

    pub fn info(self: *Device, label: []const u8, value: []const u8) void {
        self.addProp(.{ .label = .of(label), .value = .{ .info = .of(value) } });
    }

    pub fn toggle(self: *Device, label: []const u8, on: bool) void {
        self.addProp(.{ .label = .of(label), .value = .{ .toggle = on } });
    }

    fn addProp(self: *Device, p: Prop) void {
        if (self.props_len == max_props) return;
        self.props[self.props_len] = p;
        self.props_len += 1;
    }
};

/// A language (its keyboard layout) the system offers. The user's own
/// list is the ones added; one of them is in use.
pub const Layout = struct {
    /// What the top bar shows: "EN".
    code: Name,
    /// What the menu shows: "English (US)".
    name: Name,
    added: bool = false,
};

pub const max_audio = 4;
pub const max_devices = 12;
pub const max_props = 6;
pub const max_networks = 8;
pub const max_layouts = 16;

/// What the system reports: connections, sound, devices and keyboard
/// layouts. The desktop service fills it in; the simulator uses samples.
pub const System = struct {
    radios: std.EnumArray(Radio, RadioState) = .initFill(.{}),
    networks: [max_networks]Network = undefined,
    networks_len: u8 = 0,
    /// The Wi-Fi network joined, kept while Wi-Fi is off (it rejoins).
    network: ?u8 = null,
    audio: std.EnumArray(Dir, Audio) = .initFill(.{}),
    devices: [max_devices]Device = undefined,
    devices_len: u8 = 0,
    /// The languages offered; at least one is added, and `layout` is an
    /// added one.
    layouts: [max_layouts]Layout = .{Layout{ .code = .of("EN"), .name = .of("English"), .added = true }} ++ [_]Layout{.{ .code = .{}, .name = .{} }} ** (max_layouts - 1),
    layouts_len: u8 = 1,
    layout: u8 = 0,

    pub fn layoutCode(self: *const System) []const u8 {
        return self.layouts[self.layout].code.get();
    }

    pub fn addDevice(self: *System, d: Device) void {
        if (self.devices_len == max_devices) return;
        self.devices[self.devices_len] = d;
        self.devices_len += 1;
    }

    pub fn addNetwork(self: *System, n: Network) void {
        if (self.networks_len == max_networks) return;
        self.networks[self.networks_len] = n;
        self.networks_len += 1;
    }

    pub fn addAudio(self: *System, dir: Dir, name: []const u8) void {
        const a = self.audio.getPtr(dir);
        if (a.len == max_audio) return;
        a.devices[a.len] = .of(name);
        a.len += 1;
    }

    /// Offers a language; `added` puts it in the user's list.
    pub fn offerLayout(self: *System, code: []const u8, name: []const u8, added: bool) void {
        if (self.layouts_len == max_layouts) return;
        self.layouts[self.layouts_len] = .{ .code = .of(code), .name = .of(name), .added = added };
        self.layouts_len += 1;
    }

    pub fn addedLayouts(self: *const System) usize {
        var n: usize = 0;
        for (self.layouts[0..self.layouts_len]) |l| n += @intFromBool(l.added);
        return n;
    }

    /// The Wi-Fi network in use: Wi-Fi on and a network joined.
    pub fn wifiNetwork(self: *const System) ?*const Network {
        if (!self.radios.get(.wifi).on) return null;
        const i = self.network orelse return null;
        return &self.networks[i];
    }

    /// Whether the device's connection is there: Bluetooth needs its
    /// radio, shares and remote disks a network (Wi-Fi joined, or a wired
    /// adapter connected).
    pub fn reachable(self: *const System, d: Device) bool {
        return switch (d.kind) {
            .bluetooth => self.radios.get(.bluetooth).on,
            .usb, .wired => true,
            .share, .remote_disk => self.wifiNetwork() != null or self.connected(.wired) > 0,
        };
    }

    /// Devices whose connection went away are disconnected.
    fn dropUnreachable(self: *System) void {
        for (self.devices[0..self.devices_len]) |*d| {
            if ((d.state == .connected or d.state == .paused) and !self.reachable(d.*)) d.state = .disconnected;
        }
    }

    /// How many devices of a kind are connected (not paused).
    pub fn connected(self: *const System, kind: DeviceKind) usize {
        var n: usize = 0;
        for (self.devices[0..self.devices_len]) |d| n += @intFromBool(d.kind == kind and d.state == .connected);
        return n;
    }

    /// Turning a connection off disconnects the devices that used it.
    pub fn toggleRadio(self: *System, r: Radio) void {
        const st = self.radios.getPtr(r);
        st.on = !st.on;
        self.dropUnreachable();
    }

    /// Join a network, or leave the one joined.
    pub fn pickNetwork(self: *System, i: u8) void {
        if (i >= self.networks_len) return;
        self.network = if (self.network == i) null else i;
        self.dropUnreachable();
    }

    pub fn setLevel(self: *System, dir: Dir, v: f32) void {
        const a = self.audio.getPtr(dir);
        a.level = std.math.clamp(v, 0, 1);
        a.muted = false;
    }

    pub fn toggleMute(self: *System, dir: Dir) void {
        const a = self.audio.getPtr(dir);
        a.muted = !a.muted;
    }

    pub fn pickAudio(self: *System, dir: Dir, i: u8) void {
        const a = self.audio.getPtr(dir);
        if (i < a.len) a.current = i;
    }

    /// Connect or disconnect; a disabled or unreachable device stays.
    pub fn toggleConnect(self: *System, i: u8) void {
        if (i >= self.devices_len) return;
        const d = &self.devices[i];
        switch (d.state) {
            .connected, .paused => d.state = .disconnected,
            .disconnected => if (self.reachable(d.*)) {
                d.state = .connected;
            },
            .disabled => {},
        }
        self.dropUnreachable();
    }

    /// Pause a connected device, or resume a paused one.
    pub fn togglePause(self: *System, i: u8) void {
        if (i >= self.devices_len) return;
        const d = &self.devices[i];
        switch (d.state) {
            .connected => d.state = .paused,
            .paused => d.state = .connected,
            .disconnected, .disabled => {},
        }
        self.dropUnreachable();
    }

    /// Disable (disconnecting it) or enable again.
    pub fn toggleEnabled(self: *System, i: u8) void {
        if (i >= self.devices_len) return;
        const d = &self.devices[i];
        d.state = if (d.state == .disabled) .disconnected else .disabled;
        self.dropUnreachable();
    }

    pub fn toggleProp(self: *System, dev: u8, i: u8) void {
        if (dev >= self.devices_len) return;
        const d = &self.devices[dev];
        if (i >= d.props_len) return;
        switch (d.props[i].value) {
            .toggle => |*on| on.* = !on.*,
            .info => {},
        }
    }

    /// Use an added language.
    pub fn pickLayout(self: *System, i: u8) void {
        if (i < self.layouts_len and self.layouts[i].added) self.layout = i;
    }

    /// The user's languages, as the language dialog hands them back (one
    /// flag per language offered). At least one stays: an empty choice
    /// changes nothing. When the one in use is no longer there, the first
    /// that is takes its place.
    pub fn setLanguages(self: *System, on: []const bool) void {
        const n = @min(on.len, self.layouts_len);
        if (std.mem.indexOfScalar(bool, on[0..n], true) == null) return;
        for (self.layouts[0..n], on[0..n]) |*l, o| l.added = o;
        if (self.layouts[self.layout].added) return;
        for (self.layouts[0..self.layouts_len], 0..) |l, k| {
            if (l.added) {
                self.layout = @intCast(k);
                return;
            }
        }
    }
};

// ---------------------------------------------------------------- menus

/// The switches in Settings.
pub const Setting = enum { dark, learning, wheel_natural, touchpad_natural };
pub const settings = [_]Setting{ .dark, .learning, .wheel_natural, .touchpad_natural };

/// The values the Settings switches show, in `settings` order.
pub const SettingValues = [settings.len]bool;

/// What a press in a menu reaches.
pub const Hit = union(enum) {
    none,
    setting: Setting,
    /// A connection's row in the control center: turns it on or off.
    radio: Radio,
    /// The chevron at the end of that row: its detail view.
    radio_more: Radio,
    /// The switch in a connection's detail view.
    radio_switch: Radio,
    /// Back from a detail view.
    back,
    network: u8,
    mute: Dir,
    slider: Dir,
    audio: struct { dir: Dir, i: u8 },
    /// A device's row in the device center: its detail view.
    device: u8,
    connect: u8,
    pause: u8,
    enable: u8,
    prop: PropRef,
    /// An added language's row: use it.
    layout: u8,
    /// "Edit languages…": the language dialog.
    layout_edit,
};

pub const PropRef = struct { dev: u8, i: u8 };

/// Which part of a menu shows: its main view, or the details of a
/// connection (control center) or a device (device center).
pub const View = union(enum) {
    main,
    radio: Radio,
    device: u8,
};

/// A piece of a menu's layout: interactive (a Hit) or drawn only.
const Part = struct {
    r: Rect,
    what: union(enum) {
        hit: Hit,
        module,
        heading: []const u8,
        note: []const u8,
        /// The top of a device's detail view: glyph, name, state.
        device_head: u8,
        /// A property that is a fact (not a switch).
        info: PropRef,
        /// A thin line between groups.
        rule,
    },
};

const max_parts = 64;

const Parts = struct {
    items: [max_parts]Part = undefined,
    len: usize = 0,

    fn add(self: *Parts, p: Part) void {
        if (self.len == max_parts) return;
        self.items[self.len] = p;
        self.len += 1;
    }

    fn slice(self: *const Parts) []const Part {
        return self.items[0..self.len];
    }
};

const pad = 12;
const head_h = 40;
const radio_h = 46;
const more_w = 36;
const slider_h = 34;
const pick_h = 28;
const device_h = 46;
const group_h = 26;
const row_h = 40;
const prop_h = 34;
const button_h = 26;

/// The menu a top-bar icon opens, under the bar at the right.
pub const TopMenu = struct {
    from: shell.TopBarHit = .none,
    view: View = .main,

    pub fn isOpen(self: TopMenu) bool {
        return self.from != .none;
    }

    pub fn title(which: shell.TopBarHit) []const u8 {
        return switch (which) {
            .gear => "Settings",
            .control_center => "Control Center",
            .devices => "Devices",
            .language => "Language",
            else => "",
        };
    }

    fn width(self: TopMenu) i32 {
        return switch (self.from) {
            .devices => 380,
            .control_center => 320,
            else => 300,
        };
    }

    /// Lays the menu out; returns its rect.
    fn layout(self: TopMenu, screen_w: i32, sys: *const System, out: *Parts) Rect {
        const w = self.width();
        const x0 = screen_w - w - 8;
        const y0 = shell.top_bar_h + 6;
        const inner = w - 2 * pad;
        var y: i32 = y0 + pad;
        switch (self.view) {
            .radio => |r| y = radioView(r, sys, x0, y, w, out),
            .device => |i| y = deviceView(i, sys, x0, y, w, out),
            .main => switch (self.from) {
                .control_center => {
                    // Connections: a row each that turns it on or off, and a
                    // chevron at its end for the details.
                    const conn = Rect{ .x = x0 + pad, .y = y, .w = inner, .h = 2 * radio_h + 8 };
                    out.add(.{ .r = conn, .what = .module });
                    var ry = conn.y + 4;
                    for ([_]Radio{ .wifi, .bluetooth }) |r| {
                        out.add(.{ .r = .{ .x = conn.x + 4, .y = ry, .w = conn.w - 8 - more_w, .h = radio_h }, .what = .{ .hit = .{ .radio = r } } });
                        out.add(.{ .r = .{ .x = conn.right() - 4 - more_w, .y = ry + 5, .w = more_w, .h = radio_h - 10 }, .what = .{ .hit = .{ .radio_more = r } } });
                        ry += radio_h;
                    }
                    y = conn.bottom() + 10;
                    // Sound: output, then input, each a slider and its devices.
                    for ([_]Dir{ .output, .input }) |dir| {
                        const a = sys.audio.getPtrConst(dir);
                        const mod = Rect{ .x = x0 + pad, .y = y, .w = inner, .h = group_h + slider_h + @as(i32, a.len) * pick_h + 8 };
                        out.add(.{ .r = mod, .what = .module });
                        out.add(.{ .r = .{ .x = mod.x + 12, .y = mod.y + 4, .w = mod.w - 24, .h = group_h }, .what = .{ .heading = if (dir == .output) "Sound output" else "Sound input" } });
                        const sy = mod.y + group_h;
                        out.add(.{ .r = .{ .x = mod.x + 6, .y = sy, .w = 30, .h = slider_h }, .what = .{ .hit = .{ .mute = dir } } });
                        out.add(.{ .r = .{ .x = mod.x + 44, .y = sy, .w = mod.w - 58, .h = slider_h }, .what = .{ .hit = .{ .slider = dir } } });
                        var py = sy + slider_h;
                        var i: u8 = 0;
                        while (i < a.len) : (i += 1) {
                            out.add(.{ .r = .{ .x = mod.x + 4, .y = py, .w = mod.w - 8, .h = pick_h }, .what = .{ .hit = .{ .audio = .{ .dir = dir, .i = i } } } });
                            py += pick_h;
                        }
                        y = mod.bottom() + 10;
                    }
                    y -= 10;
                },
                .devices => {
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = inner, .h = head_h - pad }, .what = .{ .heading = title(.devices) } });
                    y = y0 + head_h;
                    var any = false;
                    for ([_]DeviceKind{ .bluetooth, .usb, .wired, .share, .remote_disk }) |kind| {
                        var first = true;
                        for (sys.devices[0..sys.devices_len], 0..) |d, i| {
                            if (d.kind != kind) continue;
                            if (first) {
                                out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = inner, .h = group_h }, .what = .{ .note = kindName(kind) } });
                                y += group_h;
                                first = false;
                            }
                            any = true;
                            // The whole row opens the device's details.
                            out.add(.{ .r = .{ .x = x0 + 8, .y = y, .w = w - 16, .h = device_h }, .what = .{ .hit = .{ .device = @intCast(i) } } });
                            y += device_h + 4;
                        }
                    }
                    if (!any) {
                        out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = inner, .h = row_h }, .what = .{ .note = "No devices." } });
                        y += row_h;
                    }
                    y -= 4;
                },
                .language => {
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = inner, .h = head_h - pad }, .what = .{ .heading = title(.language) } });
                    y = y0 + head_h;
                    // The user's languages: a click uses one. Adding and
                    // removing them is the language dialog's.
                    var i: u8 = 0;
                    while (i < sys.layouts_len) : (i += 1) {
                        if (!sys.layouts[i].added) continue;
                        out.add(.{ .r = .{ .x = x0 + 8, .y = y, .w = w - 16, .h = row_h }, .what = .{ .hit = .{ .layout = i } } });
                        y += row_h;
                    }
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y + 4, .w = w - 36, .h = 1 }, .what = .rule });
                    y += 9;
                    out.add(.{ .r = .{ .x = x0 + 8, .y = y, .w = w - 16, .h = row_h }, .what = .{ .hit = .layout_edit } });
                    y += row_h;
                },
                else => {
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = inner, .h = head_h - pad }, .what = .{ .heading = title(.gear) } });
                    y = y0 + head_h;
                    for (settings) |s| {
                        out.add(.{ .r = .{ .x = x0 + 8, .y = y, .w = w - 16, .h = row_h }, .what = .{ .hit = .{ .setting = s } } });
                        y += row_h;
                    }
                },
            },
        }
        return .{ .x = x0, .y = y0, .w = w, .h = y + pad - y0 };
    }

    /// A connection's details: back, its name and switch; then the Wi-Fi
    /// networks to join, or the Bluetooth devices to connect.
    fn radioView(r: Radio, sys: *const System, x0: i32, y_top: i32, w: i32, out: *Parts) i32 {
        var y = y_top;
        out.add(.{ .r = .{ .x = x0 + 8, .y = y - 2, .w = 28, .h = 28 }, .what = .{ .hit = .back } });
        out.add(.{ .r = .{ .x = x0 + 40, .y = y, .w = w - 110, .h = 24 }, .what = .{ .heading = radioName(r) } });
        out.add(.{ .r = .{ .x = x0 + w - pad - 44, .y = y, .w = 44, .h = 24 }, .what = .{ .hit = .{ .radio_switch = r } } });
        y += 24 + 10;
        if (!sys.radios.get(r).on) {
            out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = w - 36, .h = row_h }, .what = .{ .note = if (r == .wifi) "Wi-Fi is off." else "Bluetooth is off." } });
            return y + row_h - pad + 4;
        }
        switch (r) {
            .wifi => {
                out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = w - 36, .h = group_h }, .what = .{ .note = "Networks" } });
                y += group_h;
                var i: u8 = 0;
                while (i < sys.networks_len) : (i += 1) {
                    out.add(.{ .r = .{ .x = x0 + 8, .y = y, .w = w - 16, .h = row_h }, .what = .{ .hit = .{ .network = i } } });
                    y += row_h;
                }
                if (sys.networks_len == 0) {
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = w - 36, .h = row_h }, .what = .{ .note = "No networks in range." } });
                    y += row_h;
                }
            },
            .bluetooth => {
                out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = w - 36, .h = group_h }, .what = .{ .note = "Devices" } });
                y += group_h;
                var any = false;
                for (sys.devices[0..sys.devices_len], 0..) |d, i| {
                    if (d.kind != .bluetooth) continue;
                    any = true;
                    const row = Rect{ .x = x0 + 8, .y = y, .w = w - 16, .h = device_h };
                    out.add(.{ .r = row, .what = .{ .device_head = @intCast(i) } });
                    out.add(.{ .r = .{ .x = row.right() - 8 - 92, .y = row.y + @divTrunc(device_h - button_h, 2), .w = 92, .h = button_h }, .what = .{ .hit = .{ .connect = @intCast(i) } } });
                    y += device_h + 4;
                }
                if (!any) {
                    out.add(.{ .r = .{ .x = x0 + 18, .y = y, .w = w - 36, .h = row_h }, .what = .{ .note = "No Bluetooth devices." } });
                    y += row_h;
                }
            },
        }
        return y - pad + 4;
    }

    /// A device's details: back and its name and state; the actions
    /// (connect, pause, disable); then its properties.
    fn deviceView(i: u8, sys: *const System, x0: i32, y_top: i32, w: i32, out: *Parts) i32 {
        var y = y_top;
        if (i >= sys.devices_len) return y;
        const d = &sys.devices[i];
        out.add(.{ .r = .{ .x = x0 + 8, .y = y + 8, .w = 28, .h = 28 }, .what = .{ .hit = .back } });
        out.add(.{ .r = .{ .x = x0 + 36, .y = y, .w = w - 44, .h = device_h }, .what = .{ .device_head = i } });
        y += device_h + 8;
        // The actions, left to right.
        var bx = x0 + pad + 4;
        for ([_]Hit{ .{ .connect = i }, .{ .pause = i }, .{ .enable = i } }, [_]i32{ 100, 84, 84 }) |h, bw| {
            out.add(.{ .r = .{ .x = bx, .y = y, .w = bw, .h = button_h }, .what = .{ .hit = h } });
            bx += bw + 8;
        }
        y += button_h + 14;
        if (d.props_len == 0) return y - pad;
        const mod = Rect{ .x = x0 + pad, .y = y, .w = w - 2 * pad, .h = @as(i32, d.props_len) * prop_h + 8 };
        out.add(.{ .r = mod, .what = .module });
        var py = mod.y + 4;
        var k: u8 = 0;
        while (k < d.props_len) : (k += 1) {
            const pr = Rect{ .x = mod.x + 4, .y = py, .w = mod.w - 8, .h = prop_h };
            const ref: PropRef = .{ .dev = i, .i = k };
            out.add(.{ .r = pr, .what = if (d.props[k].value == .toggle) .{ .hit = .{ .prop = ref } } else .{ .info = ref } });
            py += prop_h;
        }
        return mod.bottom();
    }

    pub fn rect(self: TopMenu, screen_w: i32, sys: *const System) Rect {
        var parts: Parts = .{};
        return self.layout(screen_w, sys, &parts);
    }

    pub fn hit(self: TopMenu, screen_w: i32, sys: *const System, x: f32, y: f32) Hit {
        if (!self.isOpen()) return .none;
        var parts: Parts = .{};
        _ = self.layout(screen_w, sys, &parts);
        for (parts.slice()) |p| {
            if (p.what == .hit and p.r.contains(x, y)) return p.what.hit;
        }
        return .none;
    }

    /// Where a slider sets the level for pointer x.
    pub fn sliderLevel(self: TopMenu, screen_w: i32, sys: *const System, dir: Dir, x: f32) f32 {
        var parts: Parts = .{};
        _ = self.layout(screen_w, sys, &parts);
        for (parts.slice()) |p| {
            if (p.what == .hit and p.what.hit == .slider and p.what.hit.slider == dir) {
                const t = track(p.r);
                return (x - @as(f32, @floatFromInt(t.x))) / @as(f32, @floatFromInt(t.w));
            }
        }
        return 0;
    }

    pub fn draw(self: TopMenu, cv: *Canvas, th: *const Theme, screen_w: i32, sys: *const System, values: SettingValues, px: f32, py: f32) void {
        if (!self.isOpen()) return;
        var parts: Parts = .{};
        const r = self.layout(screen_w, sys, &parts);
        cv.fillRoundRect(r.translate(0, 4), 14, th.get(.shadow));
        cv.fillRoundRect(r, 14, th.get(.surface));
        cv.strokeRoundRect(r, 14, 1, th.get(.border));
        const m = font.Metrics.of(.{}, cv.scale);
        const sm = font.Metrics.of(.{ .size = .small }, cv.scale);
        for (parts.slice()) |p| {
            switch (p.what) {
                .module => cv.fillRoundRect(p.r, 10, th.get(.surface_alt)),
                .rule => cv.fillRect(p.r, th.get(.hairline)),
                .heading => |t| _ = cv.text(@floatFromInt(p.r.x), textY(p.r, m), t, .{ .weight = .semibold }, th.get(.text)),
                .note => |t| _ = cv.text(@floatFromInt(p.r.x), textY(p.r, sm), t, .{ .size = .small }, th.get(.text_dim)),
                .device_head => |i| {
                    // In the Bluetooth list the row has a backing; at the
                    // top of a device's details it stands alone.
                    if (self.view == .radio) cv.fillRoundRect(p.r, 10, th.get(.surface_alt));
                    drawDeviceInfo(cv, th, sys, sys.devices[i], p.r, if (self.view == .radio) 92 + 16 else 0, self.view == .device);
                },
                .info => |ref| {
                    const prop = &sys.devices[ref.dev].props[ref.i];
                    _ = cv.text(@floatFromInt(p.r.x + 10), textY(p.r, m), prop.label.get(), .{}, th.get(.text));
                    const v = prop.value.info.get();
                    const vw = @min(m.width(v), @as(f32, @floatFromInt(@divTrunc(p.r.w, 2))));
                    _ = cv.textEllipsis(@as(f32, @floatFromInt(p.r.right() - 10)) - vw, textY(p.r, m), v, vw, .{}, th.get(.text_dim));
                },
                .hit => |h| drawHit(cv, th, sys, values, p.r, h, p.r.contains(px, py)),
            }
        }
    }
};

pub fn kindName(kind: DeviceKind) []const u8 {
    return switch (kind) {
        .bluetooth => "Bluetooth",
        .usb => "USB",
        .wired => "Wired network",
        .share => "Shared folders",
        .remote_disk => "Remote disks",
    };
}

fn radioName(r: Radio) []const u8 {
    return switch (r) {
        .wifi => "Wi-Fi",
        .bluetooth => "Bluetooth",
    };
}

/// The slider's track inside its hit rect.
fn track(r: Rect) Rect {
    return .{ .x = r.x + 10, .y = r.y + @divTrunc(r.h - 6, 2), .w = r.w - 20, .h = 6 };
}

fn midY(r: Rect) f32 {
    return @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
}

fn textY(r: Rect, m: font.Metrics) f32 {
    return @floatFromInt(r.y + @divTrunc(r.h - m.lineHeight(), 2));
}

/// A small pill button with a label; `enabled` false draws it disabled.
fn pill(cv: *Canvas, th: *const Theme, r: Rect, label: []const u8, primary: bool, enabled: bool, hovered: bool) void {
    const m = font.Metrics.of(.{ .size = .small }, cv.scale);
    const fill = if (!enabled) th.get(.surface_sunken) else if (primary) th.get(if (hovered) .accent_hover else .accent) else th.get(.surface);
    cv.fillRoundRect(r, 13, fill);
    if (!primary or !enabled) cv.strokeRoundRect(r, 13, 1, th.get(if (hovered and enabled) .accent else .border));
    const tc = if (!enabled) th.get(.text_disabled) else if (primary) th.get(.accent_text) else th.get(.text);
    const w = m.width(label);
    _ = cv.text(@as(f32, @floatFromInt(r.x)) + (@as(f32, @floatFromInt(r.w)) - w) / 2, textY(r, m), label, .{ .size = .small, .weight = .semibold }, tc);
}

/// A switch: a pill with a knob; on = accent and knob on the right
/// (position, not only color). `r` is 38 x 20.
fn drawSwitch(cv: *Canvas, th: *const Theme, sw: Rect, on: bool) void {
    cv.fillRoundRect(sw, 10, th.get(if (on) .accent else .surface_sunken));
    cv.strokeRoundRect(sw, 10, 1, th.get(if (on) .accent else .border));
    const kx: f32 = @floatFromInt(if (on) sw.right() - 10 else sw.x + 10);
    cv.fillCircle(kx, @as(f32, @floatFromInt(sw.y)) + 10, 7, .rgb(0xFFFFFF));
}

/// A switch at the right end of a row.
fn rowSwitch(r: Rect) Rect {
    return .{ .x = r.right() - 48, .y = r.y + @divTrunc(r.h - 20, 2), .w = 38, .h = 20 };
}

fn drawHit(cv: *Canvas, th: *const Theme, sys: *const System, values: SettingValues, r: Rect, h: Hit, hovered: bool) void {
    const body: font.Style = .{};
    const m = font.Metrics.of(body, cv.scale);
    const sm = font.Metrics.of(.{ .size = .small }, cv.scale);
    const cy = midY(r);
    const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
    switch (h) {
        .none => {},
        .setting => |s| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            const labels = [_][]const u8{ "Dark mode", "Learning", "Natural scrolling: mouse wheel", "Natural scrolling: touchpad" };
            _ = cv.text(@floatFromInt(r.x + 10), textY(r, m), labels[@intFromEnum(s)], body, th.get(.text));
            drawSwitch(cv, th, rowSwitch(r), values[@intFromEnum(s)]);
        },
        .radio => |which| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.08));
            const on = sys.radios.get(which).on;
            // A round button: filled when on, outlined when off.
            const bx: f32 = @floatFromInt(r.x + 22);
            if (on) {
                cv.fillCircle(bx, cy, 16, th.get(.accent));
            } else {
                cv.fillCircle(bx, cy, 16, th.get(.border));
                cv.fillCircle(bx, cy, 15, th.get(.surface_sunken));
            }
            const gc = th.get(if (on) .accent_text else .text_dim);
            switch (which) {
                .wifi => glyphs.wifi(cv, bx, cy - 1, 3, gc),
                .bluetooth => glyphs.bluetooth(cv, bx, cy, gc),
            }
            const tx: f32 = @floatFromInt(r.x + 48);
            const top: f32 = cy - @as(f32, @floatFromInt(m.lineHeight() + sm.lineHeight())) / 2;
            _ = cv.text(tx, top, radioName(which), .{ .weight = .semibold }, th.get(.text));
            // Wi-Fi names the network joined; Bluetooth says how many of
            // its devices are connected.
            var buf: [24]u8 = undefined;
            const n = sys.connected(.bluetooth);
            const state: []const u8 = if (!on) "Off" else switch (which) {
                .wifi => if (sys.wifiNetwork()) |net| net.name.get() else "Not connected",
                .bluetooth => if (n > 0) std.fmt.bufPrint(&buf, "{d} connected", .{n}) catch "On" else "On",
            };
            _ = cv.textEllipsis(tx, top + @as(f32, @floatFromInt(m.lineHeight())), state, @floatFromInt(r.w - 56), .{ .size = .small }, th.get(.text_dim));
        },
        .radio_more => {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.12));
            glyphs.chevronRight(cv, cx, cy, th.get(if (hovered) .accent else .text_dim));
        },
        .radio_switch => |which| drawSwitch(cv, th, .{ .x = r.x + 3, .y = r.y + 2, .w = 38, .h = 20 }, sys.radios.get(which).on),
        .back => {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.12));
            glyphs.chevronLeft(cv, cx, cy, th.get(if (hovered) .accent else .text));
        },
        .network => |i| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            const net = &sys.networks[i];
            const joined = sys.network == i;
            glyphs.wifi(cv, @floatFromInt(r.x + 22), cy - 1, net.signal, th.get(.text));
            const tx: f32 = @floatFromInt(r.x + 44);
            const style: font.Style = if (joined) .{ .weight = .semibold } else body;
            const nw = cv.textEllipsis(tx, textY(r, m), net.name.get(), @floatFromInt(r.w - 44 - 110), style, th.get(.text));
            if (net.secured) glyphs.lock(cv, tx + nw + 10, cy, th.get(.text_dim));
            // The network joined: a check and a button to leave it.
            if (joined) {
                glyphs.check(cv, @floatFromInt(r.right() - 108), cy, th.get(.accent));
                pill(cv, th, .{ .x = r.right() - 92, .y = r.y + @divTrunc(r.h - button_h, 2), .w = 86, .h = button_h }, "Disconnect", false, true, hovered);
            }
        },
        .mute => |dir| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            const a = sys.audio.getPtrConst(dir);
            if (dir == .output) glyphs.speaker(cv, cx, cy, a.level, a.muted, th.get(.text)) else glyphs.mic(cv, cx, cy, a.muted, th.get(.text));
        },
        .slider => |dir| {
            const a = sys.audio.getPtrConst(dir);
            const t = track(r);
            cv.fillRoundRect(t, 3, th.get(.surface_sunken));
            const v = if (a.muted) 0 else a.level;
            const kx = @as(f32, @floatFromInt(t.x)) + v * @as(f32, @floatFromInt(t.w));
            const filled = @as(i32, @intFromFloat(kx)) - t.x;
            if (filled > 0) cv.fillRoundRect(.{ .x = t.x, .y = t.y, .w = filled, .h = t.h }, 3, th.get(if (a.muted) .text_disabled else .accent));
            cv.fillCircle(kx, cy, 9, th.get(if (hovered) .accent else .border));
            cv.fillCircle(kx, cy, 8, .rgb(0xFFFFFF));
        },
        .audio => |p| {
            if (hovered) cv.fillRoundRect(r, 6, th.get(.accent).fade(0.10));
            const a = sys.audio.getPtrConst(p.dir);
            const chosen = p.i == a.current;
            if (chosen) glyphs.check(cv, @floatFromInt(r.x + 22), cy, th.get(.accent));
            _ = cv.textEllipsis(@floatFromInt(r.x + 40), textY(r, m), a.devices[p.i].get(), @floatFromInt(r.w - 48), if (chosen) .{ .weight = .semibold } else body, th.get(.text));
        },
        .device => |i| {
            cv.fillRoundRect(r, 10, th.get(if (hovered) .surface_sunken else .surface_alt));
            drawDeviceInfo(cv, th, sys, sys.devices[i], r, 32, false);
            glyphs.chevronRight(cv, @floatFromInt(r.right() - 20), cy, th.get(if (hovered) .accent else .text_dim));
        },
        .connect => |i| {
            const d = sys.devices[i];
            const on = d.state == .connected or d.state == .paused;
            const ok = d.state != .disabled and (on or sys.reachable(d));
            pill(cv, th, r, if (on) "Disconnect" else "Connect", !on, ok, hovered);
        },
        .pause => |i| {
            const d = sys.devices[i];
            const ok = d.state == .connected or d.state == .paused;
            pill(cv, th, r, if (d.state == .paused) "Resume" else "Pause", false, ok, hovered);
        },
        .enable => |i| {
            const d = sys.devices[i];
            pill(cv, th, r, if (d.state == .disabled) "Enable" else "Disable", false, true, hovered);
        },
        .prop => |ref| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            const prop = &sys.devices[ref.dev].props[ref.i];
            _ = cv.text(@floatFromInt(r.x + 10), textY(r, m), prop.label.get(), body, th.get(.text));
            drawSwitch(cv, th, rowSwitch(r), prop.value.toggle);
        },
        .layout => |i| {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            const l = &sys.layouts[i];
            glyphs.layoutKey(cv, @floatFromInt(r.x + 28), cy, l.code.get(), th.get(.text));
            const chosen = i == sys.layout;
            _ = cv.text(@floatFromInt(r.x + 56), textY(r, m), l.name.get(), if (chosen) .{ .weight = .semibold } else body, th.get(.text));
            if (chosen) glyphs.check(cv, @floatFromInt(r.right() - 16), cy, th.get(.accent));
        },
        .layout_edit => {
            if (hovered) cv.fillRoundRect(r, 8, th.get(.accent).fade(0.10));
            _ = cv.text(@floatFromInt(r.x + 16), textY(r, m), "Edit languages\u{2026}", body, th.get(.text));
            glyphs.chevronRight(cv, @floatFromInt(r.right() - 20), cy, th.get(if (hovered) .accent else .text_dim));
        },
    }
}

/// A device's glyph, name and state in words, in `row`, leaving
/// `right` px free at its right. `large` sets the name larger (the top of
/// its details).
fn drawDeviceInfo(cv: *Canvas, th: *const Theme, sys: *const System, d: Device, row: Rect, right: i32, large: bool) void {
    const name_style: font.Style = if (large) .{ .size = .large, .weight = .semibold } else .{};
    const m = font.Metrics.of(name_style, cv.scale);
    const sm = font.Metrics.of(.{ .size = .small }, cv.scale);
    const cy = midY(row);
    const gx: f32 = @floatFromInt(row.x + 22);
    const gc = th.get(if (d.state == .disabled) .text_disabled else .text);
    switch (d.kind) {
        .bluetooth => glyphs.bluetooth(cv, gx, cy, gc),
        .usb => glyphs.usb(cv, gx, cy, gc),
        .wired => glyphs.wired(cv, gx, cy, gc),
        .share => glyphs.folder(cv, gx, cy, gc),
        .remote_disk => glyphs.disk(cv, gx, cy, gc),
    }
    const tx: f32 = @floatFromInt(row.x + 44);
    const top: f32 = cy - @as(f32, @floatFromInt(m.lineHeight() + sm.lineHeight())) / 2;
    const max_w: f32 = @floatFromInt(row.right() - right - 8 - (row.x + 44));
    _ = cv.textEllipsis(tx, top, d.name.get(), max_w, name_style, gc);
    const state: []const u8 = switch (d.state) {
        .connected => "Connected",
        .paused => "Paused",
        .disabled => "Disabled",
        .disconnected => if (sys.reachable(d)) "Not connected" else switch (d.kind) {
            .bluetooth => "Bluetooth is off",
            else => "No network",
        },
    };
    // Before the word, by shape, not only color: a filled dot when
    // connected, two bars when paused, a ring otherwise.
    const sy = top + @as(f32, @floatFromInt(m.lineHeight()));
    const dy = sy + @as(f32, @floatFromInt(sm.lineHeight())) / 2;
    switch (d.state) {
        .connected => cv.fillCircle(tx + 3, dy, 3, th.get(.success)),
        .paused => glyphs.pause(cv, tx + 3, dy, th.get(.text_dim)),
        else => {
            cv.fillCircle(tx + 3, dy, 3, th.get(.text_dim));
            cv.fillCircle(tx + 3, dy, 1.8, th.get(if (large) .surface else .surface_alt));
        },
    }
    _ = cv.text(tx + 10, sy, state, .{ .size = .small }, th.get(.text_dim));
}

test "turning Bluetooth off disconnects its devices and blocks connecting" {
    var sys: System = .{};
    sys.radios.getPtr(.bluetooth).on = true;
    sys.addDevice(.{ .kind = .bluetooth, .name = .of("Headphones"), .state = .connected });
    sys.addDevice(.{ .kind = .usb, .name = .of("Keyboard"), .state = .connected });
    sys.toggleRadio(.bluetooth);
    try std.testing.expectEqual(DeviceState.disconnected, sys.devices[0].state);
    try std.testing.expectEqual(DeviceState.connected, sys.devices[1].state);
    sys.toggleConnect(0);
    try std.testing.expectEqual(DeviceState.disconnected, sys.devices[0].state);
    sys.toggleRadio(.bluetooth);
    sys.toggleConnect(0);
    try std.testing.expectEqual(DeviceState.connected, sys.devices[0].state);
}

test "a disabled device cannot connect until enabled" {
    var sys: System = .{};
    sys.addDevice(.{ .kind = .usb, .name = .of("Drive"), .state = .connected });
    sys.toggleEnabled(0);
    try std.testing.expectEqual(DeviceState.disabled, sys.devices[0].state);
    sys.toggleConnect(0);
    try std.testing.expectEqual(DeviceState.disabled, sys.devices[0].state);
    sys.toggleEnabled(0);
    sys.toggleConnect(0);
    try std.testing.expectEqual(DeviceState.connected, sys.devices[0].state);
}

test "pause and resume; only a connected device pauses" {
    var sys: System = .{};
    sys.addDevice(.{ .kind = .usb, .name = .of("Drive") });
    sys.togglePause(0);
    try std.testing.expectEqual(DeviceState.disconnected, sys.devices[0].state);
    sys.toggleConnect(0);
    sys.togglePause(0);
    try std.testing.expectEqual(DeviceState.paused, sys.devices[0].state);
    sys.togglePause(0);
    try std.testing.expectEqual(DeviceState.connected, sys.devices[0].state);
}

test "leaving the Wi-Fi network disconnects shares when nothing else links" {
    var sys: System = .{};
    sys.radios.getPtr(.wifi).on = true;
    sys.addNetwork(.{ .name = .of("Home") });
    sys.pickNetwork(0);
    sys.addDevice(.{ .kind = .share, .name = .of("smb://nas/x"), .state = .connected });
    sys.pickNetwork(0);
    try std.testing.expectEqual(@as(?u8, null), sys.network);
    try std.testing.expectEqual(DeviceState.disconnected, sys.devices[0].state);
}

test "control center: the row toggles, the chevron opens its details" {
    var sys: System = .{};
    sys.addAudio(.output, "Speakers");
    sys.addAudio(.output, "Headphones");
    var menu: TopMenu = .{ .from = .control_center };
    const r = menu.rect(1440, &sys);
    const row_y: f32 = @floatFromInt(r.y + pad + 4 + 20);
    try std.testing.expectEqual(Hit{ .radio = .wifi }, menu.hit(1440, &sys, @floatFromInt(r.x + 40), row_y));
    try std.testing.expectEqual(Hit{ .radio_more = .wifi }, menu.hit(1440, &sys, @floatFromInt(r.right() - pad - 20), row_y));
    const lvl = menu.sliderLevel(1440, &sys, .output, @floatFromInt(r.right()));
    try std.testing.expect(lvl > 1);
    menu.view = .{ .radio = .wifi };
    const d = menu.rect(1440, &sys);
    try std.testing.expectEqual(Hit.back, menu.hit(1440, &sys, @floatFromInt(d.x + 20), @floatFromInt(d.y + pad + 10)));
}

test "device center: a row opens the details, which hold the actions and switches" {
    var sys: System = .{};
    var dev: Device = .{ .kind = .usb, .name = .of("Drive"), .state = .connected };
    dev.info("Capacity", "1 TB");
    dev.toggle("Read only", false);
    sys.addDevice(dev);
    var menu: TopMenu = .{ .from = .devices };
    const r = menu.rect(1440, &sys);
    try std.testing.expectEqual(Hit{ .device = 0 }, menu.hit(1440, &sys, @floatFromInt(r.x + 60), @floatFromInt(r.y + head_h + group_h + 20)));
    menu.view = .{ .device = 0 };
    var parts: Parts = .{};
    _ = menu.layout(1440, &sys, &parts);
    var seen: [4]bool = @splat(false);
    for (parts.slice()) |p| {
        if (p.what != .hit) continue;
        switch (p.what.hit) {
            .connect => seen[0] = true,
            .pause => seen[1] = true,
            .enable => seen[2] = true,
            .prop => |ref| seen[3] = ref.i == 1,
            else => {},
        }
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2] and seen[3]);
    sys.toggleProp(0, 1);
    try std.testing.expect(sys.devices[0].props[1].value.toggle);
}

test "languages: switch among the user's; the dialog's choice keeps at least one" {
    var sys: System = .{};
    sys.offerLayout("HE", "Hebrew", false);
    // A language not added cannot be used.
    sys.pickLayout(1);
    try std.testing.expectEqual(@as(u8, 0), sys.layout);
    // An empty choice changes nothing.
    sys.setLanguages(&.{ false, false });
    try std.testing.expect(sys.layouts[0].added);
    // Hebrew only: the one in use moves to it.
    sys.setLanguages(&.{ false, true });
    try std.testing.expectEqualStrings("HE", sys.layoutCode());
    // The menu lists the user's languages and the way to the dialog.
    const menu: TopMenu = .{ .from = .language };
    var parts: Parts = .{};
    _ = menu.layout(1440, &sys, &parts);
    var rows: usize = 0;
    var edit = false;
    for (parts.slice()) |p| {
        if (p.what != .hit) continue;
        switch (p.what.hit) {
            .layout => rows += 1,
            .layout_edit => edit = true,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), rows);
    try std.testing.expect(edit);
}
