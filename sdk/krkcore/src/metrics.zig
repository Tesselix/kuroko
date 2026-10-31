//! Timing instrumentation from day one (Top-Level Design, "Performance in
//! the VM"): histograms rather than averages, so the same build can be
//! compared on the VM, the simulator and bare metal.

const std = @import("std");

/// Log2 buckets from 0.125 ms up: <0.125, <0.25, … <512 ms, and above.
pub const Histogram = struct {
    pub const bucket_count = 14;
    buckets: [bucket_count]u64 = @splat(0),
    count: u64 = 0,
    max_ns: i64 = 0,
    sum_ns: i128 = 0,

    pub fn record(self: *Histogram, ns: i64) void {
        const d = @max(ns, 0);
        var limit: i64 = 125 * std.time.ns_per_us;
        var i: usize = 0;
        while (i < bucket_count - 1 and d >= limit) : (i += 1) limit *= 2;
        self.buckets[i] += 1;
        self.count += 1;
        self.max_ns = @max(self.max_ns, d);
        self.sum_ns += d;
    }

    /// Upper bound of the bucket holding the given percentile, in ms.
    pub fn percentileMs(self: *const Histogram, p: f32) f32 {
        if (self.count == 0) return 0;
        const target: u64 = @intFromFloat(@ceil(@as(f32, @floatFromInt(self.count)) * p));
        var seen: u64 = 0;
        var limit: f32 = 0.125;
        for (self.buckets) |b| {
            seen += b;
            if (seen >= target) return limit;
            limit *= 2;
        }
        return limit;
    }

    pub fn print(self: *const Histogram, name: []const u8) void {
        if (self.count == 0) {
            std.debug.print("{s}: no samples\n", .{name});
            return;
        }
        const mean = @as(f64, @floatFromInt(self.sum_ns)) / @as(f64, @floatFromInt(self.count)) / std.time.ns_per_ms;
        std.debug.print("{s}: n={d} mean={d:.2}ms p50<={d}ms p99<={d}ms max={d:.2}ms\n", .{
            name,
            self.count,
            mean,
            self.percentileMs(0.5),
            self.percentileMs(0.99),
            @as(f64, @floatFromInt(self.max_ns)) / std.time.ns_per_ms,
        });
        var limit: f32 = 0.125;
        for (self.buckets, 0..) |b, i| {
            if (b > 0) {
                const label = if (i == bucket_count - 1) "  >=" else "   <";
                std.debug.print("{s}{d:>8.3}ms {d}\n", .{ label, if (i == bucket_count - 1) limit / 2 else limit, b });
            }
            limit *= 2;
        }
    }
};

test "histogram buckets" {
    var h: Histogram = .{};
    h.record(100 * std.time.ns_per_us);
    h.record(3 * std.time.ns_per_ms);
    h.record(3 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 3), h.count);
    try std.testing.expectEqual(@as(f32, 4), h.percentileMs(0.9));
}
