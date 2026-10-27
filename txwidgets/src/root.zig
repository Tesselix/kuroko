//! txwidgets: the Tesselix widget library (Mode A, in-process).
//! Pure Zig; renders on the CPU into a pixel buffer, or records a draw list
//! for a GPU renderer.

pub const font = @import("font.zig");
pub const bidi = @import("bidi.zig");
pub const canvas = @import("canvas.zig");
pub const draw_list = @import("draw_list.zig");
pub const scroll = @import("scroll.zig");
pub const surface = @import("surface.zig");
pub const text_field = @import("text_field.zig");
pub const doc_view = @import("doc_view.zig");
pub const window = @import("window.zig");

pub const Canvas = canvas.Canvas;
pub const DrawList = draw_list.DrawList;
pub const Image = draw_list.Image;
pub const Surface = surface.Surface;
pub const Window = window.Window;
pub const NodeId = window.NodeId;
pub const Callback = window.Callback;
pub const callback = window.callback;
pub const Block = doc_view.Block;

test {
    @import("std").testing.refAllDecls(@This());
}
