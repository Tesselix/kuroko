//! Tesselix binary format: structure headers, records and the
//! validation and repair ladder (Top-Level Design, "Tesselix binary format").
//!
//! Layout on disk and on the wire is little-endian. A record is:
//!
//!   offset size field
//!   0      4    magic   = 0xFFFFFFFB
//!   4      2    type    structure type ID (see types.zig)
//!   6      2    version schema version of that type
//!   8      4    length  bytes of payload after this 16-byte header
//!   12     4    crc32c  checksum of the payload
//!   16     ...  payload, then zero padding up to a multiple of 8 bytes
//!
//! The padding keeps every record 8-byte aligned, so the resync rung of the
//! ladder can scan for the next magic in aligned steps and 64-bit fields in
//! payloads stay aligned.

const std = @import("std");

pub const magic: u32 = 0xFFFFFFFB;
pub const magic_swapped: u32 = @byteSwap(magic);

/// Every Tesselix structure starts with this header. Nested structures carry
/// only this header; top-level records use `RecordHeader`.
pub const Header = extern struct {
    magic: u32 = magic,
    type_id: u16,
    version: u16,
};

pub const RecordHeader = extern struct {
    header: Header,
    length: u32,
    crc32c: u32,
};

pub const record_align = 8;

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
    std.debug.assert(@sizeOf(RecordHeader) == 16);
}

pub fn crc32c(bytes: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(bytes);
}

/// Appends one record (header, payload, padding) to `out`.
pub fn appendRecord(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    type_id: u16,
    version: u16,
    payload: []const u8,
) !void {
    var hdr: [16]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], magic, .little);
    std.mem.writeInt(u16, hdr[4..6], type_id, .little);
    std.mem.writeInt(u16, hdr[6..8], version, .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(payload.len), .little);
    std.mem.writeInt(u32, hdr[12..16], crc32c(payload), .little);
    try out.appendSlice(gpa, &hdr);
    try out.appendSlice(gpa, payload);
    const pad = std.mem.alignForward(usize, payload.len, record_align) - payload.len;
    try out.appendNTimes(gpa, 0, pad);
}

/// Appends a record whose payload is `value` (an extern struct) followed by
/// optional trailing bytes (strings and other variable-length data).
pub fn appendStruct(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    type_id: u16,
    version: u16,
    value: anytype,
    extra: []const u8,
) !void {
    const T = @TypeOf(value);
    comptime checkPortable(T);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var copy = value;
    if (@import("builtin").cpu.arch.endian() == .big) byteSwapAll(T, &copy);
    try buf.appendSlice(gpa, std.mem.asBytes(&copy));
    try buf.appendSlice(gpa, extra);
    try appendRecord(gpa, out, type_id, version, buf.items);
}

/// The rungs of the ladder. `none` means the record was read normally.
pub const Repair = enum {
    none,
    byte_swapped,
    newer_version,
    unknown_type,
    bad_checksum,
    resynced,
    truncated,
};

pub const Record = struct {
    type_id: u16,
    version: u16,
    payload: []const u8,
    /// The record was written in the opposite byte order. `readStruct`
    /// swaps the fields; trailing data must be swapped by the caller.
    swapped: bool,
    /// Offset of the record in the source, for repair logs.
    offset: usize,
};

/// A type the reader understands, with the newest version it supports.
pub const Known = struct { type_id: u16, max_version: u16 };

/// Counts repairs per rung. A source whose counts keep rising is a bug.
pub const RepairLog = struct {
    counts: std.EnumArray(Repair, u32) = .initFill(0),
    bytes_skipped: usize = 0,

    pub fn note(self: *RepairLog, r: Repair) void {
        self.counts.getPtr(r).* += 1;
    }

    pub fn total(self: *const RepairLog) u32 {
        var n: u32 = 0;
        for (std.enums.values(Repair)) |r| {
            if (r != .none) n += self.counts.get(r);
        }
        return n;
    }
};

/// Walks the records in a byte slice, applying the validation and repair
/// ladder. Damaged or unknown records are skipped and logged; `next` only
/// returns records the caller can use.
pub const Reader = struct {
    bytes: []const u8,
    known: []const Known,
    pos: usize = 0,
    log: RepairLog = .{},

    pub fn init(bytes: []const u8, known: []const Known) Reader {
        return .{ .bytes = bytes, .known = known };
    }

    /// Bytes from `pos` on that have not formed a complete record yet. A
    /// stream reader keeps them and appends the next chunk.
    pub fn remaining(self: *const Reader) []const u8 {
        return self.bytes[self.pos..];
    }

    pub fn next(self: *Reader) ?Record {
        while (self.pos + @sizeOf(RecordHeader) <= self.bytes.len) {
            const start = self.pos;
            const h = self.bytes[start..][0..16];
            const m = std.mem.readInt(u32, h[0..4], .little);
            const swapped = switch (m) {
                magic => false,
                magic_swapped => true,
                else => {
                    // Rung 6: magic not found. Scan forward in aligned steps.
                    self.resync();
                    continue;
                },
            };
            const endian: std.builtin.Endian = if (swapped) .big else .little;
            const type_id = std.mem.readInt(u16, h[4..6], endian);
            const version = std.mem.readInt(u16, h[6..8], endian);
            const length = std.mem.readInt(u32, h[8..12], endian);
            const crc = std.mem.readInt(u32, h[12..16], endian);

            const payload_start = start + 16;
            const padded = std.mem.alignForward(usize, length, record_align);
            if (payload_start + length > self.bytes.len) {
                // The rest of the record has not arrived (stream) or the
                // file was cut. Stop here; a stream reader keeps
                // `remaining()` for the next chunk, a file reader calls
                // `finish()` to log the cut.
                return null;
            }
            const payload = self.bytes[payload_start..][0..length];
            self.pos = @min(self.bytes.len, payload_start + padded);

            // Rung 5: checksum. Dropped records are logged, never used.
            if (crc32c(payload) != crc) {
                self.log.note(.bad_checksum);
                continue;
            }
            // Rung 4: unknown type, skipped by its length.
            const max_version = self.maxVersion(type_id) orelse {
                self.log.note(.unknown_type);
                continue;
            };
            // Rung 2: byte-swapped. Rung 3: newer version, prefix is read.
            if (swapped) self.log.note(.byte_swapped);
            if (version > max_version) self.log.note(.newer_version);
            if (!swapped and version <= max_version) self.log.note(.none);
            return .{
                .type_id = type_id,
                .version = version,
                .payload = payload,
                .swapped = swapped,
                .offset = start,
            };
        }
        return null;
    }

    /// For files: anything left over is a cut record.
    pub fn finish(self: *Reader) void {
        if (self.pos < self.bytes.len) {
            self.log.note(.truncated);
            self.log.bytes_skipped += self.bytes.len - self.pos;
            self.pos = self.bytes.len;
        }
    }

    fn maxVersion(self: *const Reader, type_id: u16) ?u16 {
        for (self.known) |k| {
            if (k.type_id == type_id) return k.max_version;
        }
        return null;
    }

    fn resync(self: *Reader) void {
        const from = self.pos;
        var p = std.mem.alignForward(usize, self.pos + 1, record_align);
        while (p + 4 <= self.bytes.len) : (p += record_align) {
            const m = std.mem.readInt(u32, self.bytes[p..][0..4], .little);
            if (m == magic or m == magic_swapped) break;
        }
        self.pos = @min(p, self.bytes.len);
        self.log.bytes_skipped += self.pos - from;
        self.log.note(.resynced);
    }
};

/// Reads an extern struct from the start of a record's payload. A newer
/// version may be longer (the known prefix is read); an older, shorter
/// payload is zero-filled. Fields are byte-swapped when needed.
pub fn readStruct(comptime T: type, rec: Record) T {
    comptime checkPortable(T);
    var value: T = std.mem.zeroes(T);
    const n = @min(@sizeOf(T), rec.payload.len);
    @memcpy(std.mem.asBytes(&value)[0..n], rec.payload[0..n]);
    const native_little = @import("builtin").cpu.arch.endian() == .little;
    // Payload is little-endian unless the record was swapped.
    const data_little = !rec.swapped;
    if (native_little != data_little) byteSwapAll(T, &value);
    return value;
}

/// Trailing bytes after the struct in a payload (strings and arrays).
pub fn trailing(comptime T: type, rec: Record) []const u8 {
    if (rec.payload.len <= @sizeOf(T)) return &.{};
    return rec.payload[@sizeOf(T)..];
}

/// Swaps every field of a portable struct in place, generated at compile
/// time from the single definition of the type.
pub fn byteSwapAll(comptime T: type, value: *T) void {
    switch (@typeInfo(T)) {
        .int => value.* = @byteSwap(value.*),
        .float => |f| {
            const I = std.meta.Int(.unsigned, f.bits);
            value.* = @bitCast(@byteSwap(@as(I, @bitCast(value.*))));
        },
        .@"enum" => |e| {
            value.* = @enumFromInt(@byteSwap(@as(e.tag_type, @intFromEnum(value.*))));
        },
        .array => |a| {
            for (value) |*item| byteSwapAll(a.child, item);
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                byteSwapAll(field.type, &@field(value.*, field.name));
            }
        },
        else => @compileError("not a portable field type: " ++ @typeName(T)),
    }
}

/// Fixed-width fields only: no usize, no pointers, no bool, extern layout.
pub fn checkPortable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |i| {
            if (i.bits != 8 and i.bits != 16 and i.bits != 32 and i.bits != 64)
                @compileError("fields must be 8, 16, 32 or 64 bits: " ++ @typeName(T));
            if (T == usize or T == isize) @compileError("usize/isize are not portable");
        },
        .float => |f| if (f.bits != 32 and f.bits != 64) @compileError("f32 or f64 only"),
        .@"enum" => |e| checkPortable(e.tag_type),
        .array => |a| checkPortable(a.child),
        .@"struct" => |s| {
            if (s.layout != .@"extern") @compileError(@typeName(T) ++ " must be an extern struct");
            inline for (s.fields) |field| checkPortable(field.type);
        },
        else => @compileError("not a portable field type: " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const TestMsg = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: u64,
};
const test_known = [_]Known{.{ .type_id = 0x7001, .max_version = 1 }};

fn buildRecord(type_id: u16, version: u16, payload: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    try appendRecord(testing.allocator, &out, type_id, version, payload);
    return out;
}

test "rung 1: normal record round-trips" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendStruct(testing.allocator, &out, 0x7001, 1, TestMsg{ .a = 1, .b = 2, .c = 3, .d = 4 }, "hi");
    try testing.expect(out.items.len % record_align == 0);
    try testing.expectEqualSlices(u8, &.{ 0xFB, 0xFF, 0xFF, 0xFF }, out.items[0..4]);

    var r = Reader.init(out.items, &test_known);
    const rec = r.next().?;
    const msg = readStruct(TestMsg, rec);
    try testing.expectEqual(@as(u64, 4), msg.d);
    try testing.expectEqualStrings("hi", trailing(TestMsg, rec));
    try testing.expect(r.next() == null);
    try testing.expectEqual(@as(u32, 0), r.log.total());
}

test "rung 2: byte-swapped record is swapped and logged" {
    // Build the record a big-endian machine would write.
    var payload = TestMsg{ .a = 0x01020304, .b = 0x0506, .c = 7, .d = 0x1122334455667788 };
    byteSwapAll(TestMsg, &payload);
    const pb = std.mem.asBytes(&payload);
    var bytes: [16 + @sizeOf(TestMsg)]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], magic, .big);
    std.mem.writeInt(u16, bytes[4..6], 0x7001, .big);
    std.mem.writeInt(u16, bytes[6..8], 1, .big);
    std.mem.writeInt(u32, bytes[8..12], @sizeOf(TestMsg), .big);
    std.mem.writeInt(u32, bytes[12..16], crc32c(pb), .big);
    @memcpy(bytes[16..], pb);

    var r = Reader.init(&bytes, &test_known);
    const rec = r.next().?;
    try testing.expect(rec.swapped);
    const msg = readStruct(TestMsg, rec);
    try testing.expectEqual(@as(u32, 0x01020304), msg.a);
    try testing.expectEqual(@as(u64, 0x1122334455667788), msg.d);
    try testing.expectEqual(@as(u32, 1), r.log.counts.get(.byte_swapped));
}

test "rung 3: newer version reads the known prefix" {
    var big: [@sizeOf(TestMsg) + 8]u8 = @splat(0);
    std.mem.writeInt(u32, big[0..4], 42, .little);
    var out = try buildRecord(0x7001, 2, &big);
    defer out.deinit(testing.allocator);
    var r = Reader.init(out.items, &test_known);
    const rec = r.next().?;
    try testing.expectEqual(@as(u32, 42), readStruct(TestMsg, rec).a);
    try testing.expectEqual(@as(u32, 1), r.log.counts.get(.newer_version));
}

test "rung 4: unknown type is skipped by its length" {
    var out = try buildRecord(0x7FFF, 1, "unknown payload");
    defer out.deinit(testing.allocator);
    try appendStruct(testing.allocator, &out, 0x7001, 1, TestMsg{ .a = 9, .b = 0, .c = 0, .d = 0 }, "");
    var r = Reader.init(out.items, &test_known);
    try testing.expectEqual(@as(u32, 9), readStruct(TestMsg, r.next().?).a);
    try testing.expectEqual(@as(u32, 1), r.log.counts.get(.unknown_type));
}

test "rung 5: bad checksum drops the record and continues" {
    var out = try buildRecord(0x7001, 1, "damaged!");
    defer out.deinit(testing.allocator);
    out.items[16] ^= 0xFF; // damage the payload
    try appendStruct(testing.allocator, &out, 0x7001, 1, TestMsg{ .a = 5, .b = 0, .c = 0, .d = 0 }, "");
    var r = Reader.init(out.items, &test_known);
    try testing.expectEqual(@as(u32, 5), readStruct(TestMsg, r.next().?).a);
    try testing.expectEqual(@as(u32, 1), r.log.counts.get(.bad_checksum));
}

test "rung 6: garbage before a record is skipped by resync" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendNTimes(testing.allocator, 0xAB, 24);
    try appendStruct(testing.allocator, &out, 0x7001, 1, TestMsg{ .a = 77, .b = 0, .c = 0, .d = 0 }, "");
    var r = Reader.init(out.items, &test_known);
    try testing.expectEqual(@as(u32, 77), readStruct(TestMsg, r.next().?).a);
    try testing.expectEqual(@as(u32, 1), r.log.counts.get(.resynced));
    try testing.expectEqual(@as(usize, 24), r.log.bytes_skipped);
}

test "memory filled with 0xFF is rejected" {
    const ff: [64]u8 = @splat(0xFF);
    var r = Reader.init(&ff, &test_known);
    try testing.expect(r.next() == null);
}

test "truncated record waits for more bytes" {
    var out = try buildRecord(0x7001, 1, "0123456789abcdef");
    defer out.deinit(testing.allocator);
    var r = Reader.init(out.items[0..20], &test_known);
    try testing.expect(r.next() == null);
    try testing.expectEqual(@as(usize, 20), r.remaining().len);
}
