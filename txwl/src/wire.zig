//! The Wayland wire format. A message is:
//!
//!   u32  object id
//!   u32  (size << 16) | opcode      size in bytes, header included
//!   ...  arguments, each a multiple of 4 bytes, host byte order
//!
//! Arguments: int, uint, fixed (24.8), object id, new id (u32); string
//! (u32 length with the NUL, bytes, NUL, padding to 4; length 0 is null);
//! array (u32 length, bytes, padding to 4). File descriptors travel beside
//! the bytes (SCM_RIGHTS), in argument order.
//!
//! Pure: builds and reads byte slices.

const std = @import("std");

pub const header_size = 8;
/// libwayland's limit; a client sending more is broken.
pub const max_message = 4096;

pub const Header = struct {
    object: u32,
    opcode: u16,
    size: u16,
};

pub fn readHeader(bytes: []const u8) ?Header {
    if (bytes.len < header_size) return null;
    const word = std.mem.readInt(u32, bytes[4..8], .little);
    return .{
        .object = std.mem.readInt(u32, bytes[0..4], .little),
        .opcode = @truncate(word),
        .size = @truncate(word >> 16),
    };
}

/// 24.8 fixed point.
pub fn fixedFromFloat(v: f32) i32 {
    return @intFromFloat(@round(v * 256));
}

pub fn fixedToFloat(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256;
}

/// Reads the arguments of one message, in order.
pub const Args = struct {
    bytes: []const u8,
    pos: usize = 0,
    bad: bool = false,

    pub fn uint(self: *Args) u32 {
        if (self.pos + 4 > self.bytes.len) {
            self.bad = true;
            return 0;
        }
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn int(self: *Args) i32 {
        return @bitCast(self.uint());
    }

    pub fn fixed(self: *Args) f32 {
        return fixedToFloat(self.int());
    }

    /// A string without its NUL; null for a null string.
    pub fn string(self: *Args) ?[]const u8 {
        const len = self.uint();
        if (len == 0) return null;
        const padded = std.mem.alignForward(usize, len, 4);
        if (self.pos + padded > self.bytes.len or self.bytes[self.pos + len - 1] != 0) {
            self.bad = true;
            return null;
        }
        const s = self.bytes[self.pos .. self.pos + len - 1];
        self.pos += padded;
        return s;
    }

    pub fn array(self: *Args) []const u8 {
        const len = self.uint();
        const padded = std.mem.alignForward(usize, len, 4);
        if (self.pos + padded > self.bytes.len) {
            self.bad = true;
            return &.{};
        }
        const a = self.bytes[self.pos .. self.pos + len];
        self.pos += padded;
        return a;
    }
};

/// Builds one message into a byte list.
pub const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    start: usize,

    pub fn begin(gpa: std.mem.Allocator, out: *std.ArrayList(u8), object: u32, opcode: u16) !Writer {
        const start = out.items.len;
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], object, .little);
        std.mem.writeInt(u32, hdr[4..8], opcode, .little);
        try out.appendSlice(gpa, &hdr);
        return .{ .out = out, .gpa = gpa, .start = start };
    }

    pub fn uint(self: *Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.out.appendSlice(self.gpa, &b);
    }

    pub fn int(self: *Writer, v: i32) !void {
        try self.uint(@bitCast(v));
    }

    pub fn fixed(self: *Writer, v: f32) !void {
        try self.int(fixedFromFloat(v));
    }

    pub fn string(self: *Writer, s: ?[]const u8) !void {
        const str = s orelse return self.uint(0);
        try self.uint(@intCast(str.len + 1));
        try self.out.appendSlice(self.gpa, str);
        try self.out.append(self.gpa, 0);
        try self.pad(str.len + 1);
    }

    pub fn array(self: *Writer, a: []const u8) !void {
        try self.uint(@intCast(a.len));
        try self.out.appendSlice(self.gpa, a);
        try self.pad(a.len);
    }

    fn pad(self: *Writer, len: usize) !void {
        try self.out.appendNTimes(self.gpa, 0, std.mem.alignForward(usize, len, 4) - len);
    }

    /// Writes the size into the header.
    pub fn end(self: *Writer) void {
        const size: u32 = @intCast(self.out.items.len - self.start);
        const hdr = self.out.items[self.start + 4 ..][0..4];
        const opcode = std.mem.readInt(u32, hdr, .little) & 0xffff;
        std.mem.writeInt(u32, hdr, (size << 16) | opcode, .little);
    }
};

test "a message round-trips" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = try Writer.begin(gpa, &out, 7, 3);
    try w.uint(42);
    try w.int(-5);
    try w.fixed(12.5);
    try w.string("wl_compositor");
    try w.string(null);
    try w.array(&.{ 1, 2, 3, 4, 5 });
    w.end();

    const h = readHeader(out.items).?;
    try std.testing.expectEqual(@as(u32, 7), h.object);
    try std.testing.expectEqual(@as(u16, 3), h.opcode);
    try std.testing.expectEqual(out.items.len, h.size);
    try std.testing.expectEqual(@as(usize, 0), h.size % 4);

    var a: Args = .{ .bytes = out.items[header_size..h.size] };
    try std.testing.expectEqual(@as(u32, 42), a.uint());
    try std.testing.expectEqual(@as(i32, -5), a.int());
    try std.testing.expectEqual(@as(f32, 12.5), a.fixed());
    try std.testing.expectEqualStrings("wl_compositor", a.string().?);
    try std.testing.expect(a.string() == null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, a.array());
    try std.testing.expect(!a.bad);
    _ = a.uint();
    try std.testing.expect(a.bad); // past the end
}

test "a string without its NUL is refused" {
    var bytes = [_]u8{ 4, 0, 0, 0, 'a', 'b', 'c', 'd' };
    var a: Args = .{ .bytes = &bytes };
    try std.testing.expect(a.string() == null);
    try std.testing.expect(a.bad);
}
