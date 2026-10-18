//! Link-time stand-in for libSDL3, used when cross-compiling the simulator
//! (for example on a Mac for the Ubuntu ARM VM), where no libSDL3 for the
//! target is at hand. It only gives the linker the symbol names and the
//! soname libSDL3.so.0; it is never installed or loaded. At run time the
//! real libSDL3.so.0 of the target system is used.
//!
//! Keep in step with the `extern` functions in sdl.zig; a test checks it.

export fn SDL_GetPrimaryDisplay() void {}
export fn SDL_GetDisplayUsableBounds() void {}
export fn SDL_GetDisplayBounds() void {}
export fn SDL_Init() void {}
export fn SDL_Quit() void {}
export fn SDL_GetError() void {}
export fn SDL_GetCurrentVideoDriver() void {}
export fn SDL_GetRendererName() void {}
export fn SDL_CreateWindow() void {}
export fn SDL_DestroyWindow() void {}
export fn SDL_GetWindowSize() void {}
export fn SDL_GetWindowSizeInPixels() void {}
export fn SDL_StartTextInput() void {}
export fn SDL_CreateRenderer() void {}
export fn SDL_DestroyRenderer() void {}
export fn SDL_SetRenderVSync() void {}
export fn SDL_RenderClear() void {}
export fn SDL_RenderTexture() void {}
export fn SDL_RenderPresent() void {}
export fn SDL_CreateTexture() void {}
export fn SDL_DestroyTexture() void {}
export fn SDL_SetTextureScaleMode() void {}
export fn SDL_UpdateTexture() void {}
export fn SDL_WaitEventTimeout() void {}
export fn SDL_PollEvent() void {}
export fn SDL_GetModState() void {}
export fn SDL_CreateSystemCursor() void {}
export fn SDL_SetCursor() void {}
export fn SDL_DestroyCursor() void {}

test "the stub declares every SDL function sdl.zig uses" {
    const std = @import("std");
    const sdl = @embedFile("sdl.zig");
    const me = @embedFile("sdl_stub.zig");
    var it = std.mem.splitSequence(u8, sdl, "pub extern \"c\" fn ");
    _ = it.next();
    while (it.next()) |rest| {
        const end = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = rest[0..end];
        if (!std.mem.startsWith(u8, name, "SDL_")) continue;
        var buf: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "export fn {s}()", .{name});
        try std.testing.expect(std.mem.indexOf(u8, me, want) != null);
    }
}
