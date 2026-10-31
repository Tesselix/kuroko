//! Drives the whole stack (compositor core, chrome, shell, widgets, the
//! controls apps) without any backend: launches, input, ticks and frames.
//! Runs on any OS, with the leak-checking test allocator.

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const txcomp = @import("txcomp");
const controls = @import("controls");
const languages = @import("languages");

const ms = std.time.ns_per_ms;

const apps = [_]txcomp.AppEntry{
    .{ .name = "Controls", .app_id = "org.kuroko.controls", .start_ms = 300, .create = controls.createControls },
    .{ .name = "Scroll Lab", .app_id = "org.kuroko.scroll-lab", .start_ms = 1200, .create = controls.createScrollLab },
    .{ .name = "Stopwatch", .app_id = "org.kuroko.stopwatch", .start_ms = 150, .create = controls.createStopwatch },
    .{ .name = "Notes", .app_id = "org.kuroko.notes", .start_ms = 400, .create = controls.createNotes },
    .{ .name = "Reader", .app_id = "org.kuroko.reader", .start_ms = 600, .create = controls.createReader },
};

test "headless session: launch, tile, input, shelve, close" {
    const gpa = std.testing.allocator;
    const w = 1280;
    const h = 800;
    const px = try gpa.alloc(u32, w * h);
    defer gpa.free(px);

    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = w, .h = h }, 1, .{});
    defer comp.deinit();

    var now: i64 = 0;
    for (0..3) |i| _ = try comp.launch(i, now);

    var cv = tw.Canvas.init(px, w, h, w, 1);
    var frame: usize = 0;
    while (frame < 200) : (frame += 1) {
        now += 16 * ms;
        _ = comp.tick(now);
        comp.render(&cv, now);
        // Some input along the way.
        switch (frame) {
            90 => comp.handleInput(.{ .pointer_motion = .{ .x = 1000, .y = 300 } }, now),
            91, 92, 93, 94 => comp.handleInput(.{ .wheel = .{ .dy = 1 } }, now),
            100 => comp.handleInput(.{ .wheel = .{ .dy = 3, .mods = .{ .shift = true } } }, now),
            110 => comp.handleInput(.{ .pointer_motion = .{ .x = 1270, .y = 400 } }, now),
            130 => comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 1240, .y = 400 } }, now),
            131 => comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 1240, .y = 400 } }, now),
            140 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now),
            141 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now),
            150 => comp.handleInput(.{ .text = core.input.Text.from("sto") }, now),
            151 => comp.handleInput(.{ .key = .{ .key = .enter, .pressed = true, .mods = .{} } }, now),
            160 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now),
            161 => comp.handleInput(.{ .key = .{ .key = .z, .pressed = true, .mods = .{ .super = true } } }, now),
            162 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now),
            170 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now),
            171 => comp.handleInput(.{ .key = .{ .key = .x, .pressed = true, .mods = .{ .super = true } } }, now),
            172 => comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now),
            else => {},
        }
    }
    // One window closed, one shelved: two remain tiled.
    try std.testing.expectEqual(@as(usize, 1), comp.shelf.items.len);
    try std.testing.expectEqual(@as(usize, 1), comp.tiles.items.len);
}

test "a recorded frame replayed on the CPU equals the frame drawn directly" {
    // Two compositors driven the same way: one draws straight into pixels,
    // the other records a draw list (as for the GPU) that is then replayed.
    // Also checks that the core is deterministic for the same inputs.
    const gpa = std.testing.allocator;
    const w = 1280;
    const h = 800;
    const direct = try gpa.alloc(u32, w * h);
    defer gpa.free(direct);
    const replayed = try gpa.alloc(u32, w * h);
    defer gpa.free(replayed);

    const a = try txcomp.Compositor.init(gpa, &apps, .{ .w = w, .h = h }, 1, .{});
    defer a.deinit();
    const b = try txcomp.Compositor.init(gpa, &apps, .{ .w = w, .h = h }, 1, .{});
    defer b.deinit();
    var list = tw.DrawList.init(gpa);
    defer list.deinit();

    var now: i64 = 0;
    for ([_]usize{ 2, 4, 3, 1, 0 }) |i| {
        _ = try a.launch(i, now);
        _ = try b.launch(i, now);
    }
    var cva = tw.Canvas.init(direct, w, h, w, 1);
    var cvr = tw.Canvas.init(replayed, w, h, w, 1);
    var checked: usize = 0;
    var frame: usize = 0;
    while (frame < 160) : (frame += 1) {
        now += 16 * ms;
        const ev: ?core.input.Event = switch (frame) {
            100 => .{ .pointer_motion = .{ .x = 640, .y = 400 } },
            // Close the focused window: its shrinking picture is a scaled,
            // fading image.
            110 => .{ .key = .{ .key = .x, .pressed = true, .mods = .{ .super = true } } },
            // The launcher over everything.
            130 => .{ .key = .{ .key = .super, .pressed = true, .mods = .{} } },
            131 => .{ .key = .{ .key = .super, .pressed = false, .mods = .{} } },
            else => null,
        };
        for ([_]*txcomp.Compositor{ a, b }) |comp| {
            if (ev) |e| comp.handleInput(e, now);
            _ = comp.tick(now);
        }
        a.render(&cva, now);
        list.reset();
        var rec = tw.Canvas.recorder(&list, w, h, 1);
        b.render(&rec, now);
        try std.testing.expectEqual(@as(u32, 0), list.dropped);
        if (frame % 10 == 0 or (frame >= 110 and frame < 128)) {
            cvr.replay(&list);
            try std.testing.expectEqualSlices(u32, direct, replayed);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 20);
}

test "dragging the shared border between two windows resizes both slots" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(0, now);
    _ = try comp.launch(1, now);
    for (0..120) |_| {
        now += 16 * ms;
        _ = comp.tick(now);
    }
    const before = comp.slots[0].slot.w;
    const bx: f32 = @floatFromInt(comp.slots[0].slot.right());
    comp.handleInput(.{ .pointer_motion = .{ .x = bx, .y = 400 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = bx, .y = 400 } }, now);
    comp.handleInput(.{ .pointer_motion = .{ .x = bx - 150, .y = 400 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = bx - 150, .y = 400 } }, now);
    try std.testing.expect(comp.slots[0].slot.w < before - 100);
}

test "maximize sends the others to the panel; again brings them back" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(0, now);
    _ = try comp.launch(1, now);
    const third = try comp.launch(2, now);
    for (0..120) |_| {
        now += 16 * ms;
        _ = comp.tick(now);
    }
    comp.toggleMaximize(third, now);
    try std.testing.expectEqual(@as(usize, 1), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 2), comp.shelf.items.len);
    // The lone window fills everything right of the panel.
    try std.testing.expectEqual(@as(i32, 1440 - 76), comp.slots[0].frame.w);
    comp.toggleMaximize(third, now);
    try std.testing.expectEqual(@as(usize, 3), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
    // Back to three tiles; the empty panel is a narrow rail.
    try std.testing.expectEqual(@as(i32, 1440 - 76), comp.slots[0].slot.w + comp.slots[1].slot.w);
}

fn settle(comp: *txcomp.Compositor, now: *i64) void {
    for (0..120) |_| {
        now.* += 16 * ms;
        _ = comp.tick(now.*);
    }
}

test "maximized mode: a panel click swaps the maximized window" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const a = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    const c = try comp.launch(3, now);
    settle(comp, &now);
    comp.toggleMaximize(b, now);
    try std.testing.expect(comp.isMaximized(b));
    comp.panelClick(a, now);
    try std.testing.expect(comp.isMaximized(a));
    try std.testing.expectEqual(@as(usize, 1), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 2), comp.shelf.items.len);
    // Restore brings back the three, in their order before maximize.
    comp.toggleMaximize(a, now);
    try std.testing.expectEqual(@as(usize, 3), comp.tiles.items.len);
    try std.testing.expect(comp.tiles.items[0].eql(a) and comp.tiles.items[1].eql(b) and comp.tiles.items[2].eql(c));
}

test "a panel window dropped in the window area is tiled" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const a = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    settle(comp, &now);
    comp.toggleMaximize(b, now);
    // Quick drag (index 0): next to the panel, maximized mode ends.
    comp.panelDrop(a, 0, now);
    try std.testing.expect(!comp.isMaximized(b));
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
    try std.testing.expect(comp.tiles.items[0].eql(a));
}

test "full screen takes its own space and comes back to its tile" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    _ = try comp.launch(3, now);
    settle(comp, &now);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    comp.toggleFullscreen(b, now);
    try std.testing.expect(comp.isFullscreen(b));
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 1), comp.space);
    comp.render(&cv, now + 100 * ms);
    // Super+Left goes to the desktop, Super+Right back.
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now);
    comp.handleInput(.{ .key = .{ .key = .left, .pressed = true, .mods = .{ .super = true } } }, now);
    try std.testing.expectEqual(@as(usize, 0), comp.space);
    comp.render(&cv, now + 100 * ms);
    comp.handleInput(.{ .key = .{ .key = .right, .pressed = true, .mods = .{ .super = true } } }, now);
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now);
    try std.testing.expectEqual(@as(usize, 1), comp.space);
    comp.toggleFullscreen(b, now);
    try std.testing.expect(!comp.isFullscreen(b));
    try std.testing.expectEqual(@as(usize, 3), comp.tiles.items.len);
    try std.testing.expect(comp.tiles.items[1].eql(b));
    settle(comp, &now);
    comp.render(&cv, now);
}

test "the Apps button in the top bar opens the launcher" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 16, .y = 14 } }, 0);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 16, .y = 14 } }, 0);
    try std.testing.expect(comp.launcher.open);
}

test "the apps button at the bottom of the panel opens the launcher" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    const now: i64 = 0;
    // The panel is 76 px wide, the button 60 px at the bottom.
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 28, .y = 900 - 30 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 28, .y = 900 - 30 } }, now);
    try std.testing.expect(comp.launcher.open);
}

test "the gear opens switches that work" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    const now: i64 = 0;
    const click = struct {
        fn at(cp: *txcomp.Compositor, x: f32, y: f32) void {
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, 0);
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, 0);
        }
    }.at;
    _ = now;
    click(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .gear).x + 16), 14);
    try std.testing.expect(comp.top_menu.from == .gear);
    // First row: dark mode.
    const r = comp.top_menu.rect(1440, &comp.system);
    click(comp, @floatFromInt(r.x + 40), @floatFromInt(r.y + 44 + 20));
    try std.testing.expect(comp.theme.dark);
    // A click elsewhere closes it.
    click(comp, 700, 500);
    try std.testing.expect(!comp.top_menu.isOpen());
}

test "the four top-bar icons, right to left, each open their own menu" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    const click = struct {
        fn at(cp: *txcomp.Compositor, x: f32, y: f32) void {
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, 0);
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, 0);
        }
    }.at;
    const order = [_]txcomp.shell.TopBarHit{ .gear, .control_center, .devices, .language };
    var prev_x: i32 = 1440;
    for (order) |which| {
        const r = txcomp.shell.topBarRect(1440, which);
        try std.testing.expect(r.right() <= prev_x);
        prev_x = r.x;
        const cx: f32 = @floatFromInt(r.x + @divTrunc(r.w, 2));
        click(comp, cx, 14);
        try std.testing.expectEqual(which, comp.top_menu.from);
        // A second click on the same icon closes its menu.
        click(comp, cx, 14);
        try std.testing.expect(!comp.top_menu.isOpen());
    }
    // One menu open, another icon clicked: that icon's menu replaces it.
    click(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .control_center).x + 16), 14);
    click(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .language).x + 16), 14);
    try std.testing.expectEqual(.language, comp.top_menu.from);
}

test "control center turns Wi-Fi on; the device center connects a device" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    const click = struct {
        fn at(cp: *txcomp.Compositor, x: f32, y: f32) void {
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, 0);
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, 0);
        }
    }.at;
    comp.system.addDevice(.{ .kind = .usb, .name = .of("Drive") });
    click(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .control_center).x + 16), 14);
    var r = comp.top_menu.rect(1440, &comp.system);
    // The first row of the connections module: Wi-Fi.
    click(comp, @floatFromInt(r.x + 60), @floatFromInt(r.y + 12 + 4 + 23));
    try std.testing.expect(comp.system.radios.get(.wifi).on);
    try std.testing.expectEqual(.control_center, comp.top_menu.from);

    click(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .devices).x + 16), 14);
    r = comp.top_menu.rect(1440, &comp.system);
    // The device's row opens its details, which hold the buttons.
    click(comp, @floatFromInt(r.x + 60), @floatFromInt(r.y + 40 + 26 + 20));
    try std.testing.expectEqual(txcomp.menus.View{ .device = 0 }, comp.top_menu.view);
    r = comp.top_menu.rect(1440, &comp.system);
    // Search the device row for its connect button.
    const hit: [2]i32 = found: {
        var y: i32 = r.y;
        while (y < r.bottom()) : (y += 2) {
            var x: i32 = r.x;
            while (x < r.right()) : (x += 4) {
                if (comp.top_menu.hit(1440, &comp.system, @floatFromInt(x), @floatFromInt(y)) == .connect) break :found .{ x, y };
            }
        }
        return error.NoConnectButton;
    };
    click(comp, @floatFromInt(hit[0]), @floatFromInt(hit[1]));
    try std.testing.expectEqual(txcomp.menus.DeviceState.connected, comp.system.devices[0].state);
}

test "launcher: a running app is brought up; two windows open the chooser" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const icon = core.Rect{ .x = 600, .y = 300, .w = 48, .h = 48 };
    const first = try comp.launch(3, now);
    _ = try comp.launch(0, now);
    settle(comp, &now);
    comp.shelve(first, now);
    // One window: it comes back from the panel and flashes.
    comp.launcherAction(.{ .launch = .{ .app = 3, .from = icon } }, now);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
    try std.testing.expect(comp.cue != null);
    // Shift: a second window of the same app.
    comp.launcherAction(.{ .launch = .{ .app = 3, .from = icon, .new = true } }, now);
    try std.testing.expectEqual(@as(usize, 3), comp.tiles.items.len);
    settle(comp, &now);
    // Now the launcher offers a choice between the two.
    comp.launcherAction(.{ .launch = .{ .app = 3, .from = icon } }, now);
    try std.testing.expect(comp.chooser != null);
    try std.testing.expectEqual(@as(usize, 2), comp.chooser.?.n);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    comp.render(&cv, now);
}

test "panel preview: hover enlarges, its buttons act" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const a = try comp.launch(3, now);
    const b = try comp.launch(1, now);
    _ = try comp.launch(0, now);
    settle(comp, &now);
    comp.shelve(a, now);
    comp.shelve(b, now);
    settle(comp, &now);
    // Hover the first thumbnail: the preview opens, wider than the panel.
    comp.handleInput(.{ .pointer_motion = .{ .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.preview != null and comp.preview.?.items[0].eql(a));
    settle(comp, &now);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    comp.render(&cv, now);
    // Its first button closes the window.
    const c = comp.previewButtonPos(a, .close).?;
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = c[0], .y = c[1] } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = c[0], .y = c[1] } }, now);
    try std.testing.expectEqual(@as(usize, 1), comp.shelf.items.len);
}

test "double click on a title bar maximizes, again restores" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    settle(comp, &now);
    // A point in b's title bar, right of the middle (no menu there).
    var x: f32 = 0;
    var y: f32 = 0;
    for (comp.tiles.items, 0..) |h, i| {
        if (h.eql(b)) {
            const f = comp.slots[i].frame;
            x = @floatFromInt(f.x + f.w - 40);
            y = @floatFromInt(f.y + 10);
        }
    }
    const dbl = struct {
        fn click(cp: *txcomp.Compositor, px: f32, py: f32, t: i64) void {
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = px, .y = py } }, t);
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = px, .y = py } }, t);
        }
    }.click;
    dbl(comp, x, y, now);
    dbl(comp, x, y, now + 150 * ms);
    try std.testing.expect(comp.isMaximized(b));
    settle(comp, &now);
    const f = comp.slots[0].frame;
    const x2: f32 = @floatFromInt(f.x + f.w - 40);
    const y2: f32 = @floatFromInt(f.y + 10);
    dbl(comp, x2, y2, now);
    dbl(comp, x2, y2, now + 150 * ms);
    try std.testing.expect(!comp.isMaximized(b));
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
}

test "reorder: dragging a title bar previews the swap; the drop keeps it, Escape undoes it" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    var now: i64 = 0;
    const a = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    settle(comp, &now);
    try std.testing.expect(comp.tiles.items[0].eql(a));

    const fa = comp.slots[0].frame;
    const sb = comp.slots[1].slot;
    const ax: f32 = @floatFromInt(fa.x + fa.w - 40);
    const ay: f32 = @floatFromInt(fa.y + 10);
    const bx: f32 = @floatFromInt(sb.x + @divTrunc(sb.w, 2));
    const by: f32 = @floatFromInt(sb.y + @divTrunc(sb.h, 2));
    const step = struct {
        fn run(cp: *txcomp.Compositor, c: *tw.Canvas, t: *i64, frames: usize) void {
            for (0..frames) |_| {
                t.* += 16 * ms;
                _ = cp.tick(t.*);
                cp.render(c, t.*);
            }
        }
    }.run;

    // Press on a's title bar and drag onto b's tile.
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = ax, .y = ay } }, now);
    comp.handleInput(.{ .pointer_motion = .{ .x = ax + 20, .y = ay } }, now);
    comp.handleInput(.{ .pointer_motion = .{ .x = bx, .y = by } }, now);
    // Not yet: the pointer has not rested on the tile.
    try std.testing.expect(comp.tiles.items[0].eql(a));
    step(comp, &cv, &now, 10);
    // While still dragging, b has moved into a's tile, animated.
    try std.testing.expect(comp.tiles.items[0].eql(b));
    // Back over its own tile: the preview is undone.
    comp.handleInput(.{ .pointer_motion = .{ .x = ax, .y = ay + 100 } }, now);
    step(comp, &cv, &now, 10);
    try std.testing.expect(comp.tiles.items[0].eql(a));
    // Escape cancels the drag; nothing moves.
    comp.handleInput(.{ .pointer_motion = .{ .x = bx, .y = by } }, now);
    step(comp, &cv, &now, 10);
    try std.testing.expect(comp.tiles.items[0].eql(b));
    comp.handleInput(.{ .key = .{ .key = .escape, .pressed = true, .mods = .{} } }, now);
    try std.testing.expect(comp.tiles.items[0].eql(a));
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = bx, .y = by } }, now);
    try std.testing.expect(comp.tiles.items[0].eql(a));
    settle(comp, &now);

    // A fast drop, before the preview: the windows still swap.
    const fa2 = comp.slots[0].frame;
    const ax2: f32 = @floatFromInt(fa2.x + fa2.w - 40);
    const ay2: f32 = @floatFromInt(fa2.y + 10);
    now += 500 * ms; // not a double click
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = ax2, .y = ay2 } }, now);
    comp.handleInput(.{ .pointer_motion = .{ .x = bx, .y = by } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = bx, .y = by } }, now);
    try std.testing.expect(comp.tiles.items[0].eql(b) and comp.tiles.items[1].eql(a));
    step(comp, &cv, &now, 20);
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
}

test "closing leaves a shrinking picture that goes away" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const a = try comp.launch(0, now);
    _ = try comp.launch(1, now);
    settle(comp, &now);
    comp.close(a, now);
    try std.testing.expectEqual(@as(usize, 1), comp.ghosts.items.len);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    var t = now;
    while (t < now + 400 * ms) : (t += 16 * ms) comp.render(&cv, t);
    try std.testing.expectEqual(@as(usize, 0), comp.ghosts.items.len);
}

test "panel: minimize all, and close all after a second click" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(0, now);
    _ = try comp.launch(1, now);
    _ = try comp.launch(3, now);
    settle(comp, &now);
    const click = struct {
        fn at(cp: *txcomp.Compositor, x: f32, y: f32, t: i64) void {
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, t);
            cp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, t);
        }
    }.at;
    // Minimize all: left button at the top of the panel.
    click(comp, 20, 50, now);
    try std.testing.expectEqual(@as(usize, 0), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 3), comp.shelf.items.len);
    // Close all: right button, twice.
    click(comp, 56, 50, now);
    try std.testing.expectEqual(@as(usize, 3), comp.shelf.items.len);
    click(comp, 56, 50, now + 500 * ms);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
}

test "panel groups windows of one app; hover shows all; right click shows or closes all" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const n1 = try comp.launch(3, now);
    const n2 = try comp.launch(3, now);
    const n3 = try comp.launch(3, now);
    _ = try comp.launch(0, now);
    settle(comp, &now);
    comp.shelve(n1, now);
    comp.shelve(n2, now);
    comp.shelve(n3, now);
    settle(comp, &now);
    // One thumbnail for the three Notes windows.
    comp.handleInput(.{ .pointer_motion = .{ .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.preview != null);
    try std.testing.expectEqual(@as(usize, 3), comp.preview.?.n);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    settle(comp, &now);
    comp.render(&cv, now);
    // Esc closes the view.
    comp.handleInput(.{ .key = .{ .key = .escape, .pressed = true, .mods = .{} } }, now);
    try std.testing.expect(comp.preview == null);
    // Right click: "Show all (3)" is first (fewer than 4 windows).
    comp.handleInput(.{ .pointer_button = .{ .button = .right, .pressed = true, .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .right, .pressed = false, .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.panel_menu != null);
    const r = comp.panel_menu.?.rect;
    const ix: f32 = @floatFromInt(r.x + 20);
    const iy: f32 = @floatFromInt(r.y + 6 + 10);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = ix, .y = iy } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = ix, .y = iy } }, now);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
    try std.testing.expectEqual(@as(usize, 4), comp.tiles.items.len);
    comp.render(&cv, now);
}

test "every open app is in the panel; clicking one on screen brings it forward" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const a = try comp.launch(0, now);
    const b = try comp.launch(1, now);
    settle(comp, &now);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
    // a is the first app in the panel; b has focus.
    try std.testing.expect(comp.focused.?.eql(b));
    comp.handleInput(.{ .pointer_motion = .{ .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.focused.?.eql(a));
    try std.testing.expect(comp.cue != null);
    // Still two windows on screen, none minimized.
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
}

test "panel: clicking an app with several windows restores the last minimized" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const n1 = try comp.launch(3, now);
    const n2 = try comp.launch(3, now);
    const n3 = try comp.launch(3, now);
    settle(comp, &now);
    comp.shelve(n2, now);
    settle(comp, &now);
    comp.shelve(n1, now);
    settle(comp, &now);
    // n1 went to the panel last: the click brings it back, n2 stays.
    comp.handleInput(.{ .pointer_motion = .{ .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.focused.?.eql(n1));
    try std.testing.expectEqual(@as(usize, 1), comp.shelf.items.len);
    try std.testing.expect(comp.shelf.items[0].eql(n2));
    settle(comp, &now);
    // Again: now n2.
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.focused.?.eql(n2));
    try std.testing.expectEqual(@as(usize, 0), comp.shelf.items.len);
    settle(comp, &now);
    // None minimized: the click brings up the most recently used one.
    comp.focus(n3, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 38, .y = 100 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 38, .y = 100 } }, now);
    try std.testing.expect(comp.focused.?.eql(n3));
    try std.testing.expectEqual(@as(usize, 3), comp.tiles.items.len);
}

test "login start: apps launch into the panel, the desktop stays clean" {
    const gpa = std.testing.allocator;
    const w = 1920;
    const h = 1200;
    const px = try gpa.alloc(u32, w * h);
    defer gpa.free(px);

    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = w, .h = h }, 1, .{});
    defer comp.deinit();

    var now: i64 = 0;
    var hs: [3]core.Handle = undefined;
    for ([_]usize{ 0, 1, 3 }, 0..) |a, i| hs[i] = try comp.launchMinimized(a, now);
    try std.testing.expectEqual(@as(usize, 0), comp.counts().tiled);
    try std.testing.expectEqual(@as(usize, 3), comp.counts().shelved);

    // The apps start in the background (Scroll Lab takes 1.2 s) while the
    // panel shows them; nothing comes onto the desktop by itself.
    var cv = tw.Canvas.init(px, w, h, w, 1);
    for (0..120) |_| {
        now += 16 * ms;
        _ = comp.tick(now);
        comp.render(&cv, now);
    }
    try std.testing.expectEqual(@as(usize, 0), comp.counts().tiled);
    try std.testing.expectEqual(@as(usize, 3), comp.counts().shelved);

    // Restoring one from the panel tiles it.
    comp.restore(hs[1], now);
    for (0..30) |_| {
        now += 16 * ms;
        _ = comp.tick(now);
        comp.render(&cv, now);
    }
    try std.testing.expectEqual(@as(usize, 1), comp.counts().tiled);
    try std.testing.expectEqual(@as(usize, 2), comp.counts().shelved);
}

fn deskApp(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: core.types.DeskAppKind, status: core.types.AppStatus, flags: u8, strings: []const []const u8, exec: []const []const u8) !void {
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    if (kind == .app) {
        // key, id, name, icon, exec, version, available_version
        for (strings[0..4]) |s| try core.format.appendString(gpa, &extra, s);
        try core.format.appendStringList(gpa, &extra, exec);
        for (strings[4..6]) |s| try core.format.appendString(gpa, &extra, s);
    }
    try core.format.appendStruct(gpa, out, core.types.desk_app, 1, core.types.DeskApp{
        .kind = kind,
        .status = status,
        .flags = flags,
        .string_count = if (kind == .app) 7 else 0,
        .save_count = 3,
    }, extra.items);
}

test "installed apps from txdesk appear in the launcher and start" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();

    // txdesk's side of the socket.
    var path_buf: [512]u8 = undefined;
    const path = try core.ipc.socketPath(&path_buf, core.ipc.compositor_socket);
    const fd = core.ipc.connect(path) catch return error.SkipZigTest; // no socket here
    defer core.ipc.close(fd);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deskApp(gpa, &out, .snapshot_begin, .installed, 0, &.{}, &.{});
    try deskApp(gpa, &out, .app, .installed, core.types.desk_app_update, &.{ "/bin/sh", "sh", "Shell", "", "1.0", "2.0" }, &.{ "/bin/sh", "-c", "exit 0", "%U" });
    try deskApp(gpa, &out, .app, .missing, 0, &.{ "/usr/bin/gone", "gone", "Gone", "", "1.0", "" }, &.{"/usr/bin/gone"});
    try deskApp(gpa, &out, .snapshot_end, .installed, 0, &.{}, &.{});
    _ = try core.ipc.write(fd, out.items);

    var now: i64 = 0;
    var tries: usize = 0;
    while (comp.app_infos.items.len < apps.len + 2 and tries < 200) : (tries += 1) {
        _ = comp.tick(now);
        now += 16 * ms;
    }
    try std.testing.expectEqual(apps.len + 2, comp.app_infos.items.len);
    const shell_app = comp.app_infos.items[apps.len];
    try std.testing.expectEqualStrings("Shell", shell_app.name);
    try std.testing.expect(shell_app.update and !shell_app.missing and !shell_app.hidden);
    try std.testing.expect(comp.app_infos.items[apps.len + 1].missing);

    // Starting it runs the command (field codes dropped) and remembers it.
    comp.launcherAction(.{ .launch = .{ .app = apps.len, .from = .{} } }, now);
    try std.testing.expectEqual(apps.len, comp.recent.items[0]);
    // A ghost does not start.
    comp.launcherAction(.{ .launch = .{ .app = apps.len + 1, .from = .{} } }, now);
    try std.testing.expectEqual(apps.len, comp.recent.items[0]);

    // The launcher shows both, and draws.
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = 16, .y = 14 } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = 16, .y = 14 } }, now);
    try std.testing.expect(comp.launcher.open);
    // The app just started is in Recent (this session's launches: no
    // txdesk here), so All apps leaves it out: every app is shown once.
    try std.testing.expectEqual(@as(usize, 1), comp.launcher.recent_len);
    try std.testing.expectEqual(apps.len, comp.launcher.recent[0].app);
    try std.testing.expectEqual(apps.len + 1, comp.launcher.order_len);
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    comp.render(&cv, now + 300 * ms);
}

test "an app's window takes its launch placeholder; an unknown app gets a tile" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();

    // The registry knows one installed app.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deskApp(gpa, &out, .snapshot_begin, .installed, 0, &.{}, &.{});
    try deskApp(gpa, &out, .app, .installed, 0, &.{ "/bin/sh", "sh", "Shell", "", "1.0", "" }, &.{ "/bin/sh", "-c", "exit 0" });
    try deskApp(gpa, &out, .snapshot_end, .installed, 0, &.{}, &.{});
    var reader = core.format.Reader.init(out.items, &core.types.known);
    while (reader.next()) |rec| _ = try comp.installed.apply(rec);
    comp.syncInstalledForTest();

    var now: i64 = 0;
    comp.launcherAction(.{ .launch = .{ .app = apps.len, .from = .{} } }, now);
    try std.testing.expectEqual(@as(usize, 1), comp.tiles.items.len);
    for (0..10) |_| {
        _ = comp.tick(now);
        now += 16 * ms;
    }

    // Its window arrives: same tile, no second window.
    const s1 = try controls.createStopwatch(gpa);
    comp.adoptWindow(s1, .{ .pid = 4242, .exe = "/bin/sh" }, now);
    try std.testing.expectEqual(@as(usize, 1), comp.tiles.items.len);
    _ = comp.tick(now);

    // A window of an app the registry does not know: a tile of its own.
    const s2 = try controls.createStopwatch(gpa);
    comp.adoptWindow(s2, .{ .pid = 4243, .exe = "/usr/local/bin/unknown-app" }, now);
    try std.testing.expectEqual(@as(usize, 2), comp.tiles.items.len);
    try std.testing.expect(comp.app_infos.items[comp.app_infos.items.len - 1].hidden);
    _ = comp.tick(now + 300 * ms);
}

fn feed(comp: *txcomp.Compositor, bytes: []const u8) void {
    var reader = core.format.Reader.init(bytes, &core.types.known);
    while (reader.next()) |rec| comp.deskRecordForTest(rec);
}

fn deskTrust(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: core.types.DeskTrustKind, subject: core.types.TrustSubject, level: core.types.Trust, path: []const u8) !void {
    try core.format.appendStruct(gpa, out, core.types.desk_trust, 1, core.types.DeskTrust{
        .kind = kind,
        .subject = subject,
        .level = level,
        .path_len = @intCast(path.len),
    }, path);
}

test "window trust: own apps and installed apps are trusted, others by the user's marks" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();

    // The registry: /bin/sh is installed, under the Stopwatch's app id, so
    // an impostor can claim that id.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deskApp(gpa, &out, .snapshot_begin, .installed, 0, &.{}, &.{});
    try deskApp(gpa, &out, .app, .installed, 0, &.{ "/bin/sh", "org.kuroko.stopwatch", "Shell", "", "1.0", "" }, &.{"/bin/sh"});
    try deskApp(gpa, &out, .snapshot_end, .installed, 0, &.{}, &.{});
    feed(comp, out.items);

    var now: i64 = 0;
    const own = try comp.launch(0, now);
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(own).?.window);

    // The installed app's own binary: trusted.
    comp.adoptWindow(try controls.createStopwatch(gpa), .{ .pid = 100, .exe = "/bin/sh" }, now);
    const sh = comp.tiles.items[comp.tiles.items.len - 1];
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(sh).?.app);
    try std.testing.expectEqual(@as(i32, 100), comp.trustOf(sh).?.pid);

    // Another binary claiming the same app id: not trusted.
    comp.adoptWindow(try controls.createStopwatch(gpa), .{ .pid = 101, .exe = "/tmp/impostor" }, now);
    const fake = comp.tiles.items[comp.tiles.items.len - 1];
    try std.testing.expect(!fake.eql(sh));
    try std.testing.expectEqual(core.types.Trust.untrusted, comp.trustOf(fake).?.app);

    // An app nobody installed: untrusted until the user marks it.
    comp.adoptWindow(try controls.createStopwatch(gpa), .{ .pid = 102, .exe = "/home/u/bin/tool" }, now);
    const tool = comp.tiles.items[comp.tiles.items.len - 1];
    try std.testing.expectEqual(core.types.Trust.untrusted, comp.trustOf(tool).?.window);
    out.clearRetainingCapacity();
    try deskTrust(gpa, &out, .snapshot_begin, .app, .unknown, "");
    try deskTrust(gpa, &out, .mark, .app, .trusted, "/home/u/bin/tool");
    try deskTrust(gpa, &out, .mark, .folder, .untrusted, "/home/u/Downloads");
    try deskTrust(gpa, &out, .snapshot_end, .app, .unknown, "");
    feed(comp, out.items);
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(tool).?.window);

    // A file from an untrusted folder in a trusted app: the window is not.
    comp.setWindowObject(sh, "/home/u/Downloads/invoice.pdf");
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(sh).?.app);
    try std.testing.expectEqual(core.types.Trust.untrusted, comp.trustOf(sh).?.window);
    // The user trusts that file: it applies at once.
    comp.markWindowObject(sh, .trusted);
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(sh).?.window);

    // txdesk takes the app mark back: the tool is untrusted again.
    out.clearRetainingCapacity();
    try deskTrust(gpa, &out, .cleared, .app, .unknown, "/home/u/bin/tool");
    feed(comp, out.items);
    try std.testing.expectEqual(core.types.Trust.untrusted, comp.trustOf(tool).?.window);

    // Kuroko's own apps cannot be marked.
    comp.markWindowApp(own, .untrusted);
    try std.testing.expectEqual(core.types.Trust.trusted, comp.trustOf(own).?.window);
    now += 16 * ms;
    _ = comp.tick(now);
}

const FakeInfluence = struct {
    bytes: []const u8,
    reads: usize = 0,

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *FakeInfluence = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, "focus.krkde")) return null;
        self.reads += 1;
        return gpa.dupe(u8, self.bytes) catch null;
    }
};

test "launcher: Focus, then Recent, then the other apps, each app once" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();

    // txdesk's lists: Notes in Focus (a cycle), Reader by use; Recent lists
    // Notes again (dropped: Focus holds it), Stopwatch, and an app that
    // does not exist (dropped: references only).
    const picks = [_]core.influence.Pick{
        .{ .list = .focus, .reason = .cycle, .value = 5, .app = "org.kuroko.notes" },
        .{ .list = .focus, .reason = .used, .value = 42, .app = "org.kuroko.reader" },
        .{ .list = .recent, .reason = .opened, .value = 1_760_000_000, .app = "org.kuroko.notes" },
        .{ .list = .recent, .reason = .opened, .value = 1_760_000_000, .app = "/usr/bin/gone" },
        .{ .list = .recent, .reason = .opened, .value = 1_759_999_000, .app = "org.kuroko.stopwatch" },
    };
    const bytes = try core.influence.encode(gpa, &picks, 1_760_000_100, .predictor);
    defer gpa.free(bytes);
    var fake: FakeInfluence = .{ .bytes = bytes };
    comp.state_reader = .{ .ctx = &fake, .read = FakeInfluence.read };
    comp.setWallTime(1_760_000_300);

    const now: i64 = 0;
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now);
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now);
    const l = &comp.launcher;
    try std.testing.expect(l.open);
    try std.testing.expectEqual(@as(usize, 2), l.focus_len);
    try std.testing.expectEqual(@as(usize, 3), l.focus[0].app); // Notes
    try std.testing.expectEqual(@as(usize, 4), l.focus[1].app); // Reader
    try std.testing.expectEqual(@as(usize, 1), l.recent_len);
    try std.testing.expectEqual(@as(usize, 2), l.recent[0].app); // Stopwatch
    // The other two apps, and nothing twice.
    try std.testing.expectEqual(apps.len - 3, l.order_len);
    for (l.order[0..l.order_len]) |a| try std.testing.expect(a == 0 or a == 1);

    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    comp.render(&cv, now + 300 * ms);

    // Read once; again only after txdesk says the file changed.
    comp.handleInput(.{ .key = .{ .key = .escape, .pressed = true, .mods = .{} } }, now);
    for (0..2) |_| {
        comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now);
        comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now);
        comp.handleInput(.{ .key = .{ .key = .escape, .pressed = true, .mods = .{} } }, now);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
    var notice: std.ArrayList(u8) = .empty;
    defer notice.deinit(gpa);
    try core.format.appendStruct(gpa, &notice, core.types.desk_notice, 1, core.types.DeskNotice{ .kind = .influence_changed }, "");
    feed(comp, notice.items);
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, now);
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, now);
    try std.testing.expectEqual(@as(usize, 2), fake.reads);
}

const FakeState = struct {
    icons: []const u8,

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *FakeState = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, "icons.krkde")) return null;
        return gpa.dupe(u8, self.icons) catch null;
    }
};

test "an installed app shows its icon from txdesk's icons file" {
    const gpa = std.testing.allocator;
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deskApp(gpa, &out, .snapshot_begin, .installed, 0, &.{}, &.{});
    try deskApp(gpa, &out, .app, .installed, 0, &.{ "/bin/sh", "sh", "Shell", "", "1.0", "" }, &.{"/bin/sh"});
    try deskApp(gpa, &out, .snapshot_end, .installed, 0, &.{}, &.{});
    feed(comp, out.items);

    // A pure red 64 px icon with a transparent corner.
    var px: [64 * 64]u32 = @splat(0xFFFF0000);
    px[0] = 0;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try core.icons.append(gpa, &file, .{ .key = "/bin/sh", .w = 64, .h = 64, .pixels = &px });
    var fake: FakeState = .{ .icons = file.items };
    comp.state_reader = .{ .ctx = &fake, .read = FakeState.read };
    _ = comp.tick(0);
    const info = comp.app_infos.items[apps.len];
    try std.testing.expect(info.icon.small != null);
    try std.testing.expect(comp.app_infos.items[0].icon.small == null); // own apps: letter tiles

    // The launcher draws it: the icon's middle is red on screen.
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = true, .mods = .{} } }, 0);
    comp.handleInput(.{ .key = .{ .key = .super, .pressed = false, .mods = .{} } }, 0);
    const screen = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(screen);
    var cv = tw.Canvas.init(screen, 1440, 900, 1440, 1);
    comp.render(&cv, 400 * ms);
    var red: usize = 0;
    for (screen) |p| {
        if (p == 0xFFFF0000) red += 1;
    }
    try std.testing.expect(red > 60 * 60);
}

test {
    _ = @import("keycodes.zig");
}

/// A small dialog built with the widget library: a line of text and a
/// button that closes it.
fn testDialog(gpa: std.mem.Allocator) !tw.Surface {
    const win = try tw.Window.create(gpa, .{ .title = "Dialog", .app_id = "test.dialog", .optimal = .{ .w = 0, .h = 0 } });
    errdefer win.destroy();
    const col = try win.column(null, .{ .padding = 16 });
    _ = try win.label(col, "Are you sure?", .{});
    const Close = struct {
        fn f(_: *tw.Window, w: *tw.Window, _: tw.NodeId) void {
            w.requestClose();
        }
    };
    _ = try win.button(col, "OK", .{ .primary = true, .on_click = tw.callback(win, Close.f) });
    return win.surface();
}

fn runFrames(comp: *txcomp.Compositor, cv: *tw.Canvas, now: *i64, n: usize) void {
    for (0..n) |_| {
        now.* += 16 * ms;
        _ = comp.tick(now.*);
        comp.render(cv, now.*);
    }
}

fn clickAt(comp: *txcomp.Compositor, x: f32, y: f32, now: i64) void {
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = true, .x = x, .y = y } }, now);
    comp.handleInput(.{ .pointer_button = .{ .button = .left, .pressed = false, .x = x, .y = y } }, now);
}

test "a modal dialog floats over its parent, blocks it, and closes with it" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    const h = try comp.launch(2, now);
    runFrames(comp, &cv, &now, 30);
    const tiled = comp.counts().tiled;

    _ = try comp.openDialog(try testDialog(gpa), .{ .parent = h, .modal = true }, now);
    runFrames(comp, &cv, &now, 20);
    // Not tiled: the window count is unchanged.
    try std.testing.expectEqual(tiled, comp.counts().tiled);
    const r = comp.dialogs.items[0].rect;
    try std.testing.expect(r.w > 0);
    // The lone window fills the work area: the dialog is centered on it.
    const area_mid = 76 + @divTrunc(1440 - 76, 2);
    try std.testing.expect(@abs(r.x + @divTrunc(r.w, 2) - area_mid) <= 1);

    // A click on the parent, outside the dialog, is blocked: a nudge.
    clickAt(comp, 200, 600, now);
    try std.testing.expect(comp.dialogs.items[0].nudge_start == now);
    try std.testing.expectEqual(@as(usize, 1), comp.dialogs.items.len);

    // Esc closes it (after its closing motion).
    comp.handleInput(.{ .key = .{ .key = .escape, .pressed = true, .mods = .{} } }, now);
    runFrames(comp, &cv, &now, 20);
    try std.testing.expectEqual(@as(usize, 0), comp.dialogs.items.len);

    // Opened again, then the parent closes: the dialog goes with it.
    _ = try comp.openDialog(try testDialog(gpa), .{ .parent = h, .modal = false }, now);
    runFrames(comp, &cv, &now, 5);
    comp.close(h, now);
    runFrames(comp, &cv, &now, 2);
    try std.testing.expectEqual(@as(usize, 0), comp.dialogs.items.len);
}

test "a dialog's button closes it; a modal desktop dialog blocks every window" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    var now: i64 = 0;
    _ = try comp.launch(2, now);
    runFrames(comp, &cv, &now, 30);

    _ = try comp.openDialog(try testDialog(gpa), .{ .modal = true, .layer = .desktop }, now);
    runFrames(comp, &cv, &now, 20);
    // The top bar is blocked too: the gear does not open its menu.
    const gear = txcomp.shell.topBarRect(1440, .gear);
    clickAt(comp, @floatFromInt(gear.x + 16), 14, now);
    try std.testing.expect(!comp.top_menu.isOpen());
    try std.testing.expect(comp.dialogs.items[0].nudge_start == now);

    // The OK button: find it by scanning the dialog for a press that
    // closes it.
    const r = comp.dialogs.items[0].rect;
    var y = r.bottom() - 4;
    while (y > r.y and comp.dialogs.items.len > 0 and !comp.dialogs.items[0].closing()) : (y -= 3) {
        clickAt(comp, @floatFromInt(r.x + 30), @floatFromInt(y), now);
        runFrames(comp, &cv, &now, 1);
    }
    runFrames(comp, &cv, &now, 20);
    try std.testing.expectEqual(@as(usize, 0), comp.dialogs.items.len);
    // Unblocked again.
    clickAt(comp, @floatFromInt(gear.x + 16), 14, now);
    try std.testing.expect(comp.top_menu.isOpen());
}

fn openLanguages(ctx: *anyopaque, name: []const u8) ?tw.Surface {
    const comp: *txcomp.Compositor = @ptrCast(@alignCast(ctx));
    if (!std.mem.eql(u8, name, "languages")) return null;
    var list: [languages.max]languages.Language = undefined;
    const sys = &comp.system;
    const n = @min(sys.layouts_len, list.len);
    for (sys.layouts[0..n], list[0..n]) |*l, *out| out.* = .{ .code = l.code.get(), .name = l.name.get(), .on = l.added };
    return languages.create(comp.gpa, list[0..n], .{ .ctx = comp, .func = struct {
        fn f(c: *anyopaque, on: []const bool) void {
            const cp: *txcomp.Compositor = @ptrCast(@alignCast(c));
            cp.system.setLanguages(on);
        }
    }.f }) catch null;
}

test "Edit languages opens the language dialog over everything; Done applies it" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 1440 * 900);
    defer gpa.free(px);
    var cv = tw.Canvas.init(px, 1440, 900, 1440, 1);
    const comp = try txcomp.Compositor.init(gpa, &apps, .{ .w = 1440, .h = 900 }, 1, .{});
    defer comp.deinit();
    comp.desktop_dialogs = .{ .ctx = comp, .open = openLanguages };
    comp.system.offerLayout("HE", "Hebrew", false);
    var now: i64 = 0;
    _ = try comp.launch(2, now);
    runFrames(comp, &cv, &now, 30);

    // The language menu, then its last row: Edit languages.
    clickAt(comp, @floatFromInt(txcomp.shell.topBarRect(1440, .language).x + 16), 14, now);
    const m = comp.top_menu.rect(1440, &comp.system);
    clickAt(comp, @floatFromInt(m.x + 60), @floatFromInt(m.bottom() - 12 - 20), now);
    runFrames(comp, &cv, &now, 20);
    try std.testing.expectEqual(@as(usize, 1), comp.dialogs.items.len);
    const d = &comp.dialogs.items[0];
    try std.testing.expectEqual(txcomp.dialogs.Layer.desktop, d.opts.layer);
    try std.testing.expect(d.opts.modal);
    // The menu closed when the dialog opened.
    try std.testing.expect(!comp.top_menu.isOpen());
    // Asking again does not open a second one.
    comp.openDesktopDialog("languages", now);
    try std.testing.expectEqual(@as(usize, 1), comp.dialogs.items.len);

    // Check Hebrew, then Done: clicks at their places in the dialog.
    const win: *tw.Window = @ptrCast(@alignCast(d.surface.ptr));
    const at = struct {
        fn f(w: *tw.Window, kind: tw.Kind, text: []const u8) core.Rect {
            for (w.nodes.items) |n| {
                if (n.kind == kind and std.mem.eql(u8, n.text, text)) return n.rect;
            }
            return .{};
        }
    }.f;
    const dr = d.rect;
    const he = at(win, .list_row, "Hebrew");
    clickAt(comp, @floatFromInt(dr.x + he.x + 40), @floatFromInt(dr.y + he.y + 10), now);
    runFrames(comp, &cv, &now, 2);
    try std.testing.expect(!comp.system.layouts[1].added); // not before Done
    const done = at(win, .button, "Done");
    clickAt(comp, @floatFromInt(comp.dialogs.items[0].rect.x + done.x + 10), @floatFromInt(comp.dialogs.items[0].rect.y + done.y + 10), now);
    runFrames(comp, &cv, &now, 20);
    try std.testing.expectEqual(@as(usize, 0), comp.dialogs.items.len);
    try std.testing.expect(comp.system.layouts[1].added);
}
