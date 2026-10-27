//! The user's trust marks as txdesk keeps them: the file `trust.tslx`
//! (one TrustHeader, then TrustMark records), the records sent to the
//! compositor (DeskTrust), and app signatures (SHA-256 of the binary).
//! The rules that turn marks into a level are shared: txcore/src/trust.zig.
//!
//! txdesk is the file's writer while it runs; `txdesk trust ...` also
//! writes it, and the running txdesk notices the change and reloads.

const std = @import("std");
const core = @import("txcore");
const types = core.types;
const format = core.format;
const Marks = core.trust.Marks;
const Mark = core.trust.Mark;

pub const Digest = [32]u8;

// ------------------------------------------------------------ the file

pub fn encode(gpa: std.mem.Allocator, marks: *const Marks, save_count: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try format.appendStruct(gpa, &out, types.trust_header, 1, types.TrustHeader{ .save_count = save_count }, "");
    for (marks.list.items) |m| {
        try format.appendStruct(gpa, &out, types.trust_mark, 1, types.TrustMark{
            .subject = m.subject,
            .level = m.level,
            .path_len = @intCast(m.path.len),
            .set_s = m.set_s,
            .digest = m.digest,
        }, m.path);
    }
    return out.toOwnedSlice(gpa);
}

/// Reads marks into `marks` (emptied first). Damaged records are skipped
/// and counted. Returns the save count.
pub fn decode(bytes: []const u8, marks: *Marks, log: *format.RepairLog) !u64 {
    marks.clearAll();
    var save_count: u64 = 0;
    var reader = format.Reader.init(bytes, &types.known);
    while (reader.next()) |rec| {
        if (rec.swapped) continue;
        switch (rec.type_id) {
            types.trust_header => save_count = format.readStruct(types.TrustHeader, rec).save_count,
            types.trust_mark => {
                const e = format.readStruct(types.TrustMark, rec);
                const path = format.trailing(types.TrustMark, rec);
                if (e.path_len != path.len or path.len == 0 or path[0] != '/') {
                    log.note(.truncated);
                    continue;
                }
                _ = try marks.set(.{ .subject = e.subject, .level = e.level, .path = path, .set_s = e.set_s, .digest = e.digest });
            },
            else => {},
        }
    }
    reader.finish();
    for (std.enums.values(format.Repair)) |rp| {
        if (rp != .none) log.counts.getPtr(rp).* += reader.log.counts.get(rp);
    }
    return save_count;
}

pub const Stat = struct {
    size: u64 = 0,
    mtime_ns: i96 = 0,
    inode: u64 = 0,

    pub fn of(io: std.Io, path: []const u8) Stat {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{};
        return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds, .inode = @intCast(st.inode) };
    }

    pub fn eql(a: Stat, b: Stat) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and a.inode == b.inode;
    }
};

/// The file on disk: the marks, its save count, and its stat when read, to
/// notice another writer (the `txdesk trust` command).
pub const File = struct {
    path: []const u8,
    marks: Marks,
    save_count: u64 = 0,
    stat: Stat = .{},

    pub fn init(gpa: std.mem.Allocator, path: []const u8) File {
        return .{ .path = path, .marks = .init(gpa) };
    }

    pub fn deinit(self: *File) void {
        self.marks.deinit();
    }

    /// A missing file is no marks. A damaged one is moved aside.
    pub fn load(self: *File, gpa: std.mem.Allocator, io: std.Io, log: *format.RepairLog) !void {
        self.stat = Stat.of(io, self.path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                self.marks.clearAll();
                self.save_count = 0;
                return;
            },
            else => return err,
        };
        defer gpa.free(bytes);
        self.save_count = decode(bytes, &self.marks, log) catch |err| {
            const aside = try std.fmt.allocPrint(gpa, "{s}.broken", .{self.path});
            defer gpa.free(aside);
            std.Io.Dir.renameAbsolute(self.path, aside, io) catch {};
            return err;
        };
    }

    /// The file changed on disk since it was read.
    pub fn changedOnDisk(self: *const File, io: std.Io) bool {
        return !Stat.of(io, self.path).eql(self.stat);
    }

    /// A temporary file renamed over the old one.
    pub fn save(self: *File, gpa: std.mem.Allocator, io: std.Io) !void {
        self.save_count += 1;
        const bytes = try encode(gpa, &self.marks, self.save_count);
        defer gpa.free(bytes);
        if (std.fs.path.dirname(self.path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{self.path});
        defer gpa.free(tmp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        try std.Io.Dir.renameAbsolute(tmp, self.path, io);
        self.stat = Stat.of(io, self.path);
    }
};

// ------------------------------------------------- to the compositor

/// Every mark, between snapshot markers.
pub fn snapshot(gpa: std.mem.Allocator, out: *std.ArrayList(u8), marks: *const Marks) !void {
    try record(gpa, out, .snapshot_begin, .app, .unknown, "");
    for (marks.list.items) |m| try record(gpa, out, .mark, m.subject, m.level, m.path);
    try record(gpa, out, .snapshot_end, .app, .unknown, "");
}

pub fn record(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: types.DeskTrustKind, subject: types.TrustSubject, level: types.Trust, path: []const u8) !void {
    try format.appendStruct(gpa, out, types.desk_trust, 1, types.DeskTrust{
        .kind = kind,
        .subject = subject,
        .level = level,
        .path_len = @intCast(path.len),
    }, path);
}

// --------------------------------------------------------- signatures

/// SHA-256 of a file, read in pieces (an app binary can be hundreds of MB).
pub fn digestFile(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [256 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, off);
        h.update(buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    return h.finalResult();
}

/// Signatures of binaries, computed once per version of the file (its
/// size, time and inode).
pub const Signatures = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { stat: Stat, digest: Digest };

    pub fn init(gpa: std.mem.Allocator) Signatures {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Signatures) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
    }

    pub fn of(self: *Signatures, io: std.Io, path: []const u8) ?Digest {
        const st = Stat.of(io, path);
        if (st.size == 0) return null;
        if (self.map.get(path)) |e| if (e.stat.eql(st)) return e.digest;
        const d = digestFile(io, path) catch return null;
        const gop = self.map.getOrPut(self.gpa, path) catch return d;
        if (!gop.found_existing) gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
            _ = self.map.remove(path);
            return d;
        };
        gop.value_ptr.* = .{ .stat = st, .digest = d };
        return d;
    }
};

/// The first bytes of a signature as hex, for people.
pub fn short(d: Digest) [16]u8 {
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{d[0..8]}) catch unreachable;
    return out;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "marks survive a round trip through trust.tslx" {
    const gpa = testing.allocator;
    var a = Marks.init(gpa);
    defer a.deinit();
    var d: Digest = @splat(0);
    d[0] = 0xab;
    _ = try a.set(.{ .subject = .app, .level = .trusted, .path = "/opt/tool/tool", .set_s = 1_760_000_000, .digest = d });
    _ = try a.set(.{ .subject = .folder, .level = .untrusted, .path = "/home/u/Downloads" });
    const bytes = try encode(gpa, &a, 7);
    defer gpa.free(bytes);

    var b = Marks.init(gpa);
    defer b.deinit();
    var log: format.RepairLog = .{};
    try testing.expectEqual(@as(u64, 7), try decode(bytes, &b, &log));
    try testing.expectEqual(@as(u32, 0), log.total());
    const m = b.find(.app, "/opt/tool/tool").?;
    try testing.expectEqual(types.Trust.trusted, m.level);
    try testing.expectEqual(@as(u8, 0xab), m.digest[0]);
    try testing.expectEqual(types.Trust.untrusted, b.objectLevel("/home/u/Downloads/x.zip"));
}

test "a damaged mark is skipped, the others stay" {
    const gpa = testing.allocator;
    var a = Marks.init(gpa);
    defer a.deinit();
    _ = try a.set(.{ .subject = .file, .level = .trusted, .path = "/home/u/a.txt" });
    _ = try a.set(.{ .subject = .file, .level = .trusted, .path = "/home/u/b.txt" });
    const bytes = try encode(gpa, &a, 1);
    defer gpa.free(bytes);
    bytes[std.mem.indexOf(u8, bytes, "a.txt").?] ^= 0xff;
    var b = Marks.init(gpa);
    defer b.deinit();
    var log: format.RepairLog = .{};
    _ = try decode(bytes, &b, &log);
    try testing.expect(log.total() > 0);
    try testing.expectEqual(@as(usize, 1), b.list.items.len);
    try testing.expect(b.find(.file, "/home/u/b.txt") != null);
}

test "a file's signature is its SHA-256" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin", .data = "abc" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/bin", .{buf[0..n]});
    var sigs = Signatures.init(testing.allocator);
    defer sigs.deinit();
    const d = sigs.of(testing.io, path).?;
    // SHA-256("abc")
    try testing.expectEqualStrings("ba7816bf8f01cfea", &short(d));
    try testing.expectEqual(d, sigs.of(testing.io, path).?);
}
