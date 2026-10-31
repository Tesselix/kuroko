//! Scroll physics and document-map geometry (Look and Controls,
//! "Scrolling"). Pure functions and plain state, tested on any OS.

const std = @import("std");
const core = @import("txcore");
const Band = core.wheel.Band;
const Tween = core.anim.Tween;

pub const Params = struct {
    /// A single notch moves this many lines.
    lines_per_notch: f32 = 3,
    /// A single notch is animated over this time (< 0.1 s feels instant).
    notch_ms: f32 = 90,
    /// Speed caps as pages per second (screen time ≈ 1 / pages_per_s).
    fast_pages_per_s: f32 = 1.5,
    very_fast_pages_per_s: f32 = 2.7,
    /// One user setting scales every band (people differ a lot).
    speed_scale: f32 = 1.0,
    /// When turning stops, at most this much travel remains, so the view
    /// stops promptly instead of coasting.
    backlog_s: f32 = 0.3,
    /// Jumps (map click, Home/End, back) animate over this time.
    jump_ms: i64 = 220,
};

pub const Scroller = struct {
    params: Params = .{},
    pos: f32 = 0,
    target: f32 = 0,
    max: f32 = 0,
    line_h: f32 = 19,
    page_h: f32 = 400,
    /// Current speed cap in px/s (infinite for single notches).
    cap: f32 = std.math.inf(f32),
    band: Band = .slow,
    jump: ?Tween = null,
    /// Smoothed measured speed, px/s.
    speed: f32 = 0,

    pub fn setExtent(self: *Scroller, content_h: f32, view_h: f32, line_h: f32) void {
        self.max = @max(0, content_h - view_h);
        self.page_h = @max(1, view_h);
        self.line_h = line_h;
        self.pos = std.math.clamp(self.pos, 0, self.max);
        self.target = std.math.clamp(self.target, 0, self.max);
    }

    pub fn capFor(self: *const Scroller, band: Band) f32 {
        const p = self.params;
        return switch (band) {
            .slow => std.math.inf(f32),
            .fast => p.fast_pages_per_s * p.speed_scale * self.page_h,
            .very_fast => p.very_fast_pages_per_s * p.speed_scale * self.page_h,
        };
    }

    /// A wheel event: `notches` signed, positive toward the end.
    pub fn wheel(self: *Scroller, notches: f32, band: Band, rate: f32) void {
        self.jump = null;
        self.band = band;
        const p = self.params;
        const notch = p.lines_per_notch * self.line_h;
        self.cap = self.capFor(band);
        switch (band) {
            .slow => self.target += notches * notch,
            .fast, .very_fast => {
                // Continuous turning at `rate` notches/s travels at the cap.
                const per = @max(notch, self.cap / @max(rate, 4));
                self.target += notches * per;
                const limit = self.cap * p.backlog_s + notch;
                self.target = std.math.clamp(self.target, self.pos - limit, self.pos + limit);
            },
        }
        self.target = std.math.clamp(self.target, 0, self.max);
    }

    /// Direct pixel movement (touchpad): follows the fingers exactly.
    pub fn pixels(self: *Scroller, dy: f32) void {
        self.jump = null;
        self.cap = std.math.inf(f32);
        self.band = .slow;
        self.pos = std.math.clamp(self.pos + dy, 0, self.max);
        self.target = self.pos;
    }

    pub fn jumpTo(self: *Scroller, y: f32, now: i64) void {
        const to = std.math.clamp(y, 0, self.max);
        var t = Tween.init(self.pos);
        t.set(to, now, self.params.jump_ms);
        self.jump = t;
        self.target = to;
        self.cap = std.math.inf(f32);
        self.band = .slow;
    }

    /// Sets the position immediately (thumb drag follows the hand).
    pub fn setPos(self: *Scroller, y: f32) void {
        self.jump = null;
        self.pos = std.math.clamp(y, 0, self.max);
        self.target = self.pos;
    }

    pub fn moving(self: *const Scroller) bool {
        return self.jump != null or @abs(self.target - self.pos) > 0.25;
    }

    /// Advances by `dt` seconds. Returns true while moving.
    pub fn update(self: *Scroller, dt: f32, now: i64) bool {
        const before = self.pos;
        if (self.jump) |j| {
            self.pos = j.value(now);
            if (j.done(now)) {
                self.pos = j.to;
                self.jump = null;
            }
        } else {
            const diff = self.target - self.pos;
            if (dt <= 0) {
                // No time has passed: nothing to advance.
            } else if (@abs(diff) <= 0.25) {
                self.pos = self.target;
                self.cap = std.math.inf(f32);
            } else {
                // Exponential approach that settles a notch within notch_ms,
                // limited by the band's speed cap.
                const tau = self.params.notch_ms / 1000.0 / 3.0;
                var step = diff * (1 - @exp(-dt / tau));
                if (std.math.isFinite(self.cap)) {
                    const lim = self.cap * dt;
                    step = std.math.clamp(step, -lim, lim);
                }
                self.pos += step;
            }
        }
        if (dt > 0) {
            const v = @abs(self.pos - before) / dt;
            self.speed = self.speed * 0.8 + v * 0.2;
        }
        if (!self.moving()) self.speed = 0;
        return self.moving();
    }

    pub fn pagesPerSecond(self: *const Scroller) f32 {
        return self.speed / self.page_h;
    }

    /// Seconds content stays visible while moving at the current speed.
    pub fn screenTime(self: *const Scroller) ?f32 {
        if (self.speed < 1) return null;
        return self.page_h / self.speed;
    }
};

/// Document map geometry. The map shows at most `max_pages` pages in its
/// height; past `slide_start` of its height, it slides so the bottom of
/// the track reaches the end of the document. The result depends only on
/// the pointer position `f` (0..1), never on history.
pub const MapParams = struct {
    max_pages: f32 = 5,
    slide_start: f32 = 0.5,
};

pub const MapView = struct {
    /// Document y at the top of the map.
    top: f32,
    /// Map pixels per document pixel.
    scale: f32,
    /// Document y under the pointer.
    doc_y: f32,
};

pub fn mapView(doc_h: f32, page_h: f32, map_h: f32, f: f32, p: MapParams) MapView {
    const visible = @max(1, @min(doc_h, p.max_pages * page_h));
    const ff = std.math.clamp(f, 0, 1);
    var top: f32 = 0;
    if (doc_h > visible and ff > p.slide_start) {
        top = (ff - p.slide_start) / (1 - p.slide_start) * (doc_h - visible);
    }
    return .{ .top = top, .scale = map_h / visible, .doc_y = top + ff * visible };
}

// ---------------------------------------------------------------- tests

const ms = std.time.ns_per_ms;

fn run(s: *Scroller, seconds: f32, now: *i64) void {
    const dt: f32 = 1.0 / 120.0;
    var t: f32 = 0;
    while (t < seconds) : (t += dt) {
        now.* += @intFromFloat(dt * std.time.ns_per_s);
        _ = s.update(dt, now.*);
    }
}

test "a single notch moves 3 lines quickly" {
    var s: Scroller = .{};
    s.setExtent(10000, 400, 20);
    var now: i64 = 0;
    s.wheel(1, .slow, 0);
    run(&s, 0.1, &now);
    try std.testing.expectApproxEqAbs(@as(f32, 60), s.pos, 3);
}

test "fast band respects the speed cap" {
    var s: Scroller = .{};
    s.setExtent(100000, 400, 20);
    var now: i64 = 0;
    // 12 notches per second for 2 seconds.
    for (0..24) |_| {
        s.wheel(1, .fast, 12);
        run(&s, 1.0 / 12.0, &now);
    }
    const cap = s.capFor(.fast);
    try std.testing.expect(s.pos <= cap * 2.0 + 1);
    try std.testing.expect(s.pos > cap * 1.2); // and actually travels
    // Stopping: the backlog is short.
    const at_stop = s.pos;
    run(&s, 0.6, &now);
    try std.testing.expect(s.pos - at_stop <= cap * s.params.backlog_s + 61);
}

test "map: short document fits and does not slide" {
    const v = mapView(1000, 400, 300, 0.9, .{});
    try std.testing.expectEqual(@as(f32, 0), v.top);
    try std.testing.expectApproxEqAbs(@as(f32, 900), v.doc_y, 0.01);
}

test "map: long document slides past the middle and reaches the end" {
    const p: MapParams = .{};
    const a = mapView(40000, 400, 300, 0.3, p);
    try std.testing.expectEqual(@as(f32, 0), a.top); // still map above middle
    const end = mapView(40000, 400, 300, 1.0, p);
    try std.testing.expectApproxEqAbs(@as(f32, 40000), end.doc_y, 0.01);
    // Monotonic: moving down never shows an earlier line.
    var prev: f32 = -1;
    var f: f32 = 0;
    while (f <= 1.0) : (f += 0.01) {
        const v = mapView(40000, 400, 300, f, p);
        try std.testing.expect(v.doc_y >= prev);
        prev = v.doc_y;
    }
}
