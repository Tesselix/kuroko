//! txdesk: the first desktop service, a stub of the context hub.
//!
//! It connects to the compositor's socket, reads scene-graph deltas
//! (Tesselix records, with the validation and repair ladder), keeps its own
//! copy of the scene, and prints it as terse text: the form the agent will
//! reason over (Design Concept, "Text, not pixels").
//!
//! It runs as a separate process. If it crashes or hangs, the compositor
//! carries on; if the compositor restarts, txdesk reconnects.

const std = @import("std");
const core = @import("txcore");
const types = core.types;

const Win = struct {
    id: u64,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    app_id: [96]u8 = undefined,
    app_id_len: usize = 0,
    rect: core.Rect = .{},
    focused: bool = false,
    shelved: bool = false,
    status: types.Status = .normal,
    progress: f32 = 0,
};

const Scene = struct {
    gpa: std.mem.Allocator,
    windows: std.ArrayList(Win) = .empty,
    snapshot: bool = false,

    fn find(self: *Scene, id: u64) ?*Win {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn apply(self: *Scene, rec: core.format.Record) !bool {
        if (rec.type_id != types.scene_window) return false;
        const m = core.format.readStruct(types.SceneWindow, rec);
        const extra = core.format.trailing(types.SceneWindow, rec);
        switch (m.kind) {
            .snapshot_begin => {
                self.windows.clearRetainingCapacity();
                self.snapshot = true;
                return false;
            },
            .snapshot_end => {
                self.snapshot = false;
                return true;
            },
            .closed => {
                for (self.windows.items, 0..) |w, i| {
                    if (w.id == m.window_id) {
                        _ = self.windows.orderedRemove(i);
                        break;
                    }
                }
            },
            .opened, .changed => {
                const w = self.find(m.window_id) orelse blk: {
                    try self.windows.append(self.gpa, .{ .id = m.window_id });
                    break :blk &self.windows.items[self.windows.items.len - 1];
                };
                // Strings are length-prefixed by the struct; never trust
                // them past the payload.
                const tl = @min(m.title_len, extra.len, w.title.len);
                @memcpy(w.title[0..tl], extra[0..tl]);
                w.title_len = tl;
                const rest = extra[@min(m.title_len, extra.len)..];
                const al = @min(m.app_id_len, rest.len, w.app_id.len);
                @memcpy(w.app_id[0..al], rest[0..al]);
                w.app_id_len = al;
                w.rect = .{ .x = m.x, .y = m.y, .w = m.w, .h = m.h };
                w.focused = m.focused != 0;
                w.shelved = m.shelved != 0;
                w.status = m.status;
                w.progress = m.progress;
            },
        }
        return !self.snapshot;
    }

    fn print(self: *const Scene, out: anytype, t: f64) !void {
        try out.print("scene t={d:.1}s windows={d}\n", .{ t, self.windows.items.len });
        for (self.windows.items) |w| {
            const h = core.Handle.fromId(w.id);
            try out.print("  win#{d}.{d} {s} \"{s}\" [{d},{d} {d}x{d}]", .{ h.index, h.generation, w.app_id[0..w.app_id_len], w.title[0..w.title_len], w.rect.x, w.rect.y, w.rect.w, w.rect.h });
            if (w.focused) try out.print(" focused", .{});
            if (w.shelved) try out.print(" shelved", .{});
            switch (w.status) {
                .normal => {},
                .progress => try out.print(" progress={d:.0}%", .{w.progress * 100}),
                .working => try out.print(" working", .{}),
                .failed => try out.print(" error", .{}),
            }
            try out.print("\n", .{});
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var path_buf: [512]u8 = undefined;
    const path = try core.ipc.socketPath(&path_buf, core.ipc.compositor_socket);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    var scene: Scene = .{ .gpa = gpa };
    defer scene.windows.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    while (true) {
        const fd = core.ipc.connect(path) catch {
            try out.print("txdesk: waiting for the compositor at {s}\n", .{path});
            try out.flush();
            io.sleep(.fromSeconds(2), .awake) catch {};
            continue;
        };
        try out.print("txdesk: connected\n", .{});
        try out.flush();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var log: core.format.RepairLog = .{};
        while (true) {
            var chunk: [8192]u8 = undefined;
            const n = core.ipc.read(fd, &chunk) catch 0;
            if (n == 0) break; // compositor gone
            try buf.appendSlice(gpa, chunk[0..n]);

            var reader = core.format.Reader.init(buf.items, &types.known);
            var changed = false;
            while (reader.next()) |rec| {
                if (try scene.apply(rec)) changed = true;
            }
            for (std.enums.values(core.format.Repair)) |r| {
                if (r != .none) log.counts.getPtr(r).* += reader.log.counts.get(r);
            }
            // Keep a partial record for the next read.
            const rest = reader.remaining().len;
            std.mem.copyForwards(u8, buf.items[0..rest], buf.items[buf.items.len - rest ..]);
            buf.shrinkRetainingCapacity(rest);

            if (changed) {
                const t = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).toMilliseconds() - start)) / 1000;
                try scene.print(out, t);
                if (log.total() > 0) try out.print("  (repairs so far: {d})\n", .{log.total()});
                try out.flush();
            }
        }
        core.ipc.close(fd);
        try out.print("txdesk: compositor closed the connection; reconnecting\n", .{});
        try out.flush();
        scene.windows.clearRetainingCapacity();
    }
}
