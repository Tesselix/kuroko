//! Reads freedesktop Desktop Entry files (`*.desktop`): what Linux apps
//! install to describe themselves (name, icon, command line, categories).
//! Only the main `[Desktop Entry]` group and unlocalized keys are read.
//!
//! Pure: parses bytes; the returned slices point into them.

const std = @import("std");

pub const Entry = struct {
    type: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
    try_exec: []const u8 = "",
    icon: []const u8 = "",
    /// Semicolon-separated, as in the file.
    categories: []const u8 = "",
    no_display: bool = false,
    hidden: bool = false,
    terminal: bool = false,

    /// An app the user starts from a launcher: an application, not hidden,
    /// with a command. Terminal apps are excluded (they need a terminal).
    pub fn isLaunchable(self: Entry) bool {
        return std.mem.eql(u8, self.type, "Application") and !self.no_display and !self.hidden and
            !self.terminal and self.exec.len > 0;
    }
};

pub fn parse(text: []const u8) Entry {
    var e: Entry = .{};
    var in_main = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_main = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_main) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const k = std.meta.stringToEnum(Key, key) orelse continue;
        const yes = std.mem.eql(u8, value, "true");
        switch (k) {
            .Type => e.type = value,
            .Name => e.name = value,
            .Exec => e.exec = value,
            .TryExec => e.try_exec = value,
            .Icon => e.icon = value,
            .Categories => e.categories = value,
            .NoDisplay => e.no_display = yes,
            .Hidden => e.hidden = yes,
            .Terminal => e.terminal = yes,
        }
    }
    return e;
}

const Key = enum { Type, Name, Exec, TryExec, Icon, Categories, NoDisplay, Hidden, Terminal };

/// Splits an Exec value into arguments: spaces separate, double quotes
/// group, backslash escapes inside quotes, "%%" is a literal "%". Field
/// codes (%U, %f, ...) are kept for the launcher to fill in.
pub fn splitExec(gpa: std.mem.Allocator, exec: []const u8, out: *std.ArrayList([]const u8)) !void {
    var arg: std.ArrayList(u8) = .empty;
    defer arg.deinit(gpa);
    var have = false;
    var quoted = false;
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        const ch = exec[i];
        if (quoted) {
            if (ch == '"') {
                quoted = false;
            } else if (ch == '\\' and i + 1 < exec.len) {
                i += 1;
                try arg.append(gpa, exec[i]);
            } else try arg.append(gpa, ch);
        } else if (ch == '"') {
            quoted = true;
            have = true;
        } else if (ch == ' ' or ch == '\t') {
            if (have) try out.append(gpa, try arg.toOwnedSlice(gpa));
            have = false;
        } else if (ch == '%' and i + 1 < exec.len and exec[i + 1] == '%') {
            i += 1;
            try arg.append(gpa, '%');
            have = true;
        } else {
            try arg.append(gpa, ch);
            have = true;
        }
    }
    if (have) try out.append(gpa, try arg.toOwnedSlice(gpa));
}

const chrome =
    \\[Desktop Entry]
    \\Version=1.0
    \\Name=Google Chrome
    \\# Only KDE 4 seems to use GenericName, so we reuse the KDE strings.
    \\GenericName=Web Browser
    \\GenericName[de]=Web-Browser
    \\Name[he]=גוגל כרום
    \\Exec=/usr/bin/google-chrome-stable %U
    \\Terminal=false
    \\Icon=google-chrome
    \\Type=Application
    \\Categories=Network;WebBrowser;
    \\
    \\[Desktop Action new-window]
    \\Name=New Window
    \\Exec=/usr/bin/google-chrome-stable
;

test "the main group only, unlocalized keys" {
    const e = parse(chrome);
    try std.testing.expectEqualStrings("Google Chrome", e.name);
    try std.testing.expectEqualStrings("/usr/bin/google-chrome-stable %U", e.exec);
    try std.testing.expectEqualStrings("google-chrome", e.icon);
    try std.testing.expectEqualStrings("Network;WebBrowser;", e.categories);
    try std.testing.expect(e.isLaunchable());
}

test "hidden, terminal and non-application entries are not launchable" {
    try std.testing.expect(!parse("[Desktop Entry]\nType=Application\nExec=/usr/bin/Xwayland -decorate\nNoDisplay=true\n").isLaunchable());
    try std.testing.expect(!parse("[Desktop Entry]\nType=Application\nExec=htop\nTerminal=true\n").isLaunchable());
    try std.testing.expect(!parse("[Desktop Entry]\nType=Link\nURL=https://example.org\n").isLaunchable());
    try std.testing.expect(!parse("[Desktop Entry]\nType=Application\nName=No command\n").isLaunchable());
}

test "Exec splitting: quotes, escapes, field codes" {
    const gpa = std.testing.allocator;
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }
    try splitExec(gpa, "\"/opt/My App/run\" --title \"say \\\"hi\\\"\" 100%% %U", &args);
    try std.testing.expectEqual(@as(usize, 5), args.items.len);
    try std.testing.expectEqualStrings("/opt/My App/run", args.items[0]);
    try std.testing.expectEqualStrings("--title", args.items[1]);
    try std.testing.expectEqualStrings("say \"hi\"", args.items[2]);
    try std.testing.expectEqualStrings("100%", args.items[3]);
    try std.testing.expectEqualStrings("%U", args.items[4]);
}
