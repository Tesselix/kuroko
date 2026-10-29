//! A recorded frame: the canvas's drawing reduced to physical-pixel
//! primitives, each with the clip it was drawn under.
//!
//! The same list is drawn by the CPU (`Canvas.replay`) or by a GPU
//! renderer, which turns each primitive into a quad: shapes are signed
//! distances in a shader, glyphs come from an atlas texture, and images
//! are textures cached by `Image.id` and uploaded again only when
//! `Image.version` changes. Every clip is an axis-aligned rect (a scissor).
//!
//! The list holds pointers (image pixels, glyphs) that are valid for the
//! frame only: record, draw, then `reset`.

const std = @import("std");
const core = @import("txcore");
const font = @import("font.zig");

const Rect = core.Rect;
const Color = core.Color;

/// Pixels the canvas can copy: 0xAARRGGBB, `w * h`, rows packed. Window
/// pictures are opaque; icons use their alpha (straight, not premultiplied).
pub const Image = struct {
    pixels: []const u32,
    w: i32,
    h: i32,
    /// Identifies the picture across frames (a GPU renderer keeps it as a
    /// texture); 0 for one that is not kept.
    id: u64 = 0,
    /// Changes whenever the pixels change; a kept texture is uploaded again.
    version: u64 = 0,
};

/// One primitive, in physical pixels.
pub const Op = union(enum) {
    fill: Rect,
    /// Rounded rect; `stroke` 0 fills it, otherwise an outline that wide.
    round: struct { r: Rect, rad: f32, stroke: f32 },
    circle: struct { cx: f32, cy: f32, r: f32 },
    /// Segment with round caps, half width `hw`.
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32, hw: f32 },
    /// A glyph's top-left at (x, y); its atlas is found by pointer.
    glyph: struct { x: i32, y: i32, glyph: *const font.Glyph },
    /// `exact`: copied 1:1 at `dst`'s corner. Otherwise scaled (nearest)
    /// into `dst` and faded by `alpha`. `blend`: the image's own alpha is
    /// used (icons); otherwise it is opaque (window pictures).
    image: struct { img: Image, dst: Rect, alpha: u8, exact: bool, blend: bool = false },
};

pub const Cmd = struct {
    /// Physical clip.
    clip: Rect,
    color: Color,
    op: Op,
};

pub const DrawList = struct {
    gpa: std.mem.Allocator,
    cmds: std.ArrayList(Cmd) = .empty,
    /// Commands lost to a failed allocation (the frame draws incomplete).
    dropped: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DrawList) void {
        self.cmds.deinit(self.gpa);
    }

    pub fn reset(self: *DrawList) void {
        self.cmds.clearRetainingCapacity();
        self.dropped = 0;
    }

    pub fn add(self: *DrawList, cmd: Cmd) void {
        self.cmds.append(self.gpa, cmd) catch {
            self.dropped += 1;
        };
    }
};

test "recording and replaying draws the same pixels" {
    const Canvas = @import("canvas.zig").Canvas;
    const gpa = std.testing.allocator;
    const w = 96;
    const h = 64;

    var img_px: [12 * 10]u32 = undefined;
    for (&img_px, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i * 2654435761 % 0xFFFFFF));
    const img: Image = .{ .pixels = &img_px, .w = 12, .h = 10, .id = 1 };

    const Draw = struct {
        fn all(cv: *Canvas, im: Image) void {
            cv.clear(Color.rgb(0xF0F0F0));
            cv.fillRect(.{ .x = 2, .y = 2, .w = 20, .h = 10 }, Color.rgba(0x3366CC, 160));
            const old = cv.pushClip(.{ .x = 10, .y = 4, .w = 30, .h = 30 });
            cv.fillRoundRect(.{ .x = 5, .y = 5, .w = 30, .h = 20 }, 6, Color.rgb(0x22AA44));
            cv.strokeRoundRect(.{ .x = 8, .y = 8, .w = 24, .h = 14 }, 4, 1.5, Color.rgb(0x000000));
            cv.popClip(old);
            cv.fillCircle(60, 20, 7.5, Color.rgba(0xCC2222, 200));
            cv.line(40, 40, 90, 55, 2, Color.rgb(0x333333));
            cv.dashedRect(.{ .x = 50, .y = 30, .w = 40, .h = 20 }, 1, 4, 3, Color.rgb(0x8800AA));
            _ = cv.text(4, 40, "Kuroko", .{}, Color.rgb(0x111111));
            cv.blit(im, 70, 2);
            cv.blitScaled(im, .{ .x = 20, .y = 30, .w = 25, .h = 17 }, 180);
            cv.triangleRight(90, 10, 5, Color.rgb(0x444444));
            const icon_px = [4]u32{ 0xFFFF0000, 0x8000FF00, 0x00000000, 0x400000FF };
            cv.drawImage(.{ .pixels = &icon_px, .w = 2, .h = 2, .id = 2 }, .{ .x = 30, .y = 50, .w = 9, .h = 9 }, 200);
        }
    };

    var direct: [w * h]u32 = @splat(0);
    var cv1 = Canvas.init(&direct, w, h, w, 1);
    Draw.all(&cv1, img);

    var list = DrawList.init(gpa);
    defer list.deinit();
    var rec = Canvas.recorder(&list, w, h, 1);
    Draw.all(&rec, img);
    try std.testing.expect(list.cmds.items.len > 10);

    var replayed: [w * h]u32 = @splat(0);
    var cv2 = Canvas.init(&replayed, w, h, w, 1);
    cv2.replay(&list);
    try std.testing.expectEqualSlices(u32, &direct, &replayed);
}
