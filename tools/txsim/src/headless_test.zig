//! Drives the whole stack (compositor core, chrome, shell, widgets, the
//! controls apps) without any backend: launches, input, ticks and frames.
//! Runs on any OS, with the leak-checking test allocator.

const std = @import("std");
const core = @import("txcore");
const tw = @import("txwidgets");
const txcomp = @import("txcomp");
const controls = @import("controls");

const ms = std.time.ns_per_ms;

const apps = [_]txcomp.AppEntry{
    .{ .name = "Controls", .app_id = "org.tesselix.controls", .start_ms = 300, .create = controls.createControls },
    .{ .name = "Scroll Lab", .app_id = "org.tesselix.scroll-lab", .start_ms = 1200, .create = controls.createScrollLab },
    .{ .name = "Stopwatch", .app_id = "org.tesselix.stopwatch", .start_ms = 150, .create = controls.createStopwatch },
    .{ .name = "Notes", .app_id = "org.tesselix.notes", .start_ms = 400, .create = controls.createNotes },
    .{ .name = "Reader", .app_id = "org.tesselix.reader", .start_ms = 600, .create = controls.createReader },
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

test "the control-center icon opens switches that work" {
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
    click(comp, 1440 - 50, 14);
    try std.testing.expect(comp.cc.isOpen());
    // First row: dark mode.
    const r = comp.cc.rect(1440);
    click(comp, @floatFromInt(r.x + 40), @floatFromInt(r.y + 44 + 20));
    try std.testing.expect(comp.theme.dark);
    // A click elsewhere closes it.
    click(comp, 700, 500);
    try std.testing.expect(!comp.cc.isOpen());
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
