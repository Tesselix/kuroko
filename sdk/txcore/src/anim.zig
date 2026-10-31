//! Clock-timed animation. Durations 150–250 ms, ease-out, interruptible:
//! a new target starts from the current value, never from the old start.

const std = @import("std");

pub const ns_per_ms: i64 = std.time.ns_per_ms;

pub fn easeOutCubic(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    const inv = 1 - x;
    return 1 - inv * inv * inv;
}

/// A value that animates toward a target.
pub const Tween = struct {
    from: f32,
    to: f32,
    start_ns: i64 = 0,
    dur_ns: i64 = 200 * ns_per_ms,

    pub fn init(v: f32) Tween {
        return .{ .from = v, .to = v };
    }

    pub fn value(self: Tween, now: i64) f32 {
        if (self.dur_ns <= 0 or now >= self.start_ns + self.dur_ns) return self.to;
        const t: f32 = @as(f32, @floatFromInt(now - self.start_ns)) / @as(f32, @floatFromInt(self.dur_ns));
        return self.from + (self.to - self.from) * easeOutCubic(t);
    }

    pub fn done(self: Tween, now: i64) bool {
        return now >= self.start_ns + self.dur_ns;
    }

    /// Retargets from the current value. Does nothing if already heading there.
    pub fn set(self: *Tween, target: f32, now: i64, dur_ms: i64) void {
        if (self.to == target) return;
        self.from = self.value(now);
        self.to = target;
        self.start_ns = now;
        self.dur_ns = dur_ms * ns_per_ms;
    }

    pub fn snap(self: *Tween, v: f32) void {
        self.from = v;
        self.to = v;
        self.dur_ns = 0;
    }
};

test "tween eases and retargets from the current value" {
    var t = Tween.init(0);
    t.set(100, 0, 200);
    const mid = t.value(100 * ns_per_ms);
    try std.testing.expect(mid > 50 and mid < 100); // ease-out: past halfway
    t.set(0, 100 * ns_per_ms, 200);
    try std.testing.expectApproxEqAbs(mid, t.value(100 * ns_per_ms), 0.001);
    try std.testing.expectEqual(@as(f32, 0), t.value(400 * ns_per_ms));
}
