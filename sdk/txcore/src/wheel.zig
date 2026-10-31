//! Wheel speed bands (Look and Controls, "The wheel").
//!
//! The compositor's input path classifies wheel motion into a band from the
//! notch rate; the widget library turns the band into distance, because
//! only it knows the line height and page height of the view.
//!
//!   slow       single notches, about 3 lines each, animated < 0.1 s
//!   fast       continuous turning or Shift: capped at about 1.5 pages/s
//!              (about 0.9 s screen time)
//!   very_fast  fast flicks, short bursts only: capped at about 2.7 pages/s
//!              (about 0.45 s screen time), then eases back to fast
//!
//! The notch rates that switch bands are not from research; they are
//! parameters to tune by feel (open question in Look and Controls).

const std = @import("std");

pub const Band = enum(u8) { slow, fast, very_fast };

pub const Params = struct {
    /// Notches per second at which continuous turning becomes "fast".
    fast_rate: f32 = 7,
    /// Notches per second for "very fast".
    very_fast_rate: f32 = 16,
    /// How long very fast may last before easing back to fast.
    burst_ms: i64 = 1200,
    /// Notches older than this do not count toward the rate.
    window_ms: i64 = 300,
};

pub const Tracker = struct {
    params: Params = .{},
    times: [12]i64 = @splat(0),
    count: usize = 0,
    head: usize = 0,
    very_fast_since: ?i64 = null,
    last_dir: f32 = 0,

    /// Records `notches` (signed) at `now` and returns the band and the
    /// current rate in notches per second.
    pub fn feed(self: *Tracker, now: i64, notches: f32, shift: bool) struct { band: Band, rate: f32 } {
        const dir = std.math.sign(notches);
        if (dir != 0 and dir != self.last_dir) {
            // A change of direction starts over: the user is correcting.
            self.count = 0;
            self.very_fast_since = null;
        }
        self.last_dir = dir;

        const n: usize = @intFromFloat(@max(1, @min(4, @round(@abs(notches)))));
        for (0..n) |_| {
            self.times[self.head] = now;
            self.head = (self.head + 1) % self.times.len;
            if (self.count < self.times.len) self.count += 1;
        }
        const r = self.rate(now);

        var band: Band = .slow;
        if (r >= self.params.very_fast_rate) {
            const since = self.very_fast_since orelse now;
            self.very_fast_since = since;
            band = if (now - since <= self.params.burst_ms * std.time.ns_per_ms) .very_fast else .fast;
        } else {
            self.very_fast_since = null;
            if (r >= self.params.fast_rate) band = .fast;
        }
        if (shift and band == .slow) band = .fast;
        return .{ .band = band, .rate = r };
    }

    /// Notches per second over the recent window.
    pub fn rate(self: *const Tracker, now: i64) f32 {
        const window = self.params.window_ms * std.time.ns_per_ms;
        var n: usize = 0;
        var oldest: i64 = now;
        for (0..self.count) |i| {
            const idx = (self.head + self.times.len - 1 - i) % self.times.len;
            const t = self.times[idx];
            if (now - t > window) break;
            n += 1;
            oldest = t;
        }
        if (n < 2) return 0;
        const span: f32 = @floatFromInt(@max(now - oldest, 30 * std.time.ns_per_ms));
        return @as(f32, @floatFromInt(n - 1)) / (span / std.time.ns_per_s);
    }
};

const ms = std.time.ns_per_ms;

test "single notches stay slow" {
    var t: Tracker = .{};
    try std.testing.expectEqual(Band.slow, t.feed(0, 1, false).band);
    try std.testing.expectEqual(Band.slow, t.feed(400 * ms, 1, false).band);
}

test "continuous turning becomes fast, flicks very fast, bursts end" {
    var t: Tracker = .{};
    var now: i64 = 0;
    var band: Band = .slow;
    for (0..6) |_| {
        band = t.feed(now, 1, false).band;
        now += 100 * ms; // 10 notches/s
    }
    try std.testing.expectEqual(Band.fast, band);

    for (0..8) |_| {
        band = t.feed(now, 1, false).band;
        now += 40 * ms; // 25 notches/s
    }
    try std.testing.expectEqual(Band.very_fast, band);

    for (0..40) |_| {
        band = t.feed(now, 1, false).band;
        now += 40 * ms;
    }
    try std.testing.expectEqual(Band.fast, band); // burst over
}

test "shift goes straight to fast" {
    var t: Tracker = .{};
    try std.testing.expectEqual(Band.fast, t.feed(0, 1, true).band);
}
