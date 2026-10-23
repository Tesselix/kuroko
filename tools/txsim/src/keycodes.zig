//! SDL scancodes (USB HID usage codes) to Linux evdev key codes, the codes
//! Wayland apps get. The standard US keyboard; 0 for anything else.

const std = @import("std");

pub fn evdev(scancode: u32) u16 {
    return switch (scancode) {
        // Letters a..z (HID 4..29).
        4...29 => letters[scancode - 4],
        // 1..9, 0 (HID 30..39).
        30...38 => @intCast(scancode - 30 + 2),
        39 => 11,
        40 => 28, // enter
        41 => 1, // escape
        42 => 14, // backspace
        43 => 15, // tab
        44 => 57, // space
        45 => 12, // minus
        46 => 13, // equal
        47 => 26, // [
        48 => 27, // ]
        49, 50 => 43, // backslash, non-US #
        51 => 39, // ;
        52 => 40, // '
        53 => 41, // `
        54 => 51, // ,
        55 => 52, // .
        56 => 53, // /
        57 => 58, // caps lock
        58...67 => @intCast(scancode - 58 + 59), // F1..F10
        68 => 87, // F11
        69 => 88, // F12
        70 => 99, // print screen
        71 => 70, // scroll lock
        72 => 119, // pause
        73 => 110, // insert
        74 => 102, // home
        75 => 104, // page up
        76 => 111, // delete
        77 => 107, // end
        78 => 109, // page down
        79 => 106, // right
        80 => 105, // left
        81 => 108, // down
        82 => 103, // up
        83 => 69, // num lock
        84 => 98, // keypad /
        85 => 55, // keypad *
        86 => 74, // keypad -
        87 => 78, // keypad +
        88 => 96, // keypad enter
        89 => 79, // keypad 1
        90 => 80,
        91 => 81,
        92 => 75,
        93 => 76,
        94 => 77,
        95 => 71,
        96 => 72,
        97 => 73, // keypad 9
        98 => 82, // keypad 0
        99 => 83, // keypad .
        100 => 86, // non-US backslash
        101 => 127, // menu (compose)
        224 => 29, // left ctrl
        225 => 42, // left shift
        226 => 56, // left alt
        227 => 125, // left super
        228 => 97, // right ctrl
        229 => 54, // right shift
        230 => 100, // right alt
        231 => 126, // right super
        else => 0,
    };
}

const letters = [26]u16{
    30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, // a..m
    49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, // n..z
};

test "common keys" {
    try std.testing.expectEqual(@as(u16, 30), evdev(4)); // a
    try std.testing.expectEqual(@as(u16, 44), evdev(29)); // z
    try std.testing.expectEqual(@as(u16, 2), evdev(30)); // 1
    try std.testing.expectEqual(@as(u16, 11), evdev(39)); // 0
    try std.testing.expectEqual(@as(u16, 59), evdev(58)); // F1
    try std.testing.expectEqual(@as(u16, 88), evdev(69)); // F12
    try std.testing.expectEqual(@as(u16, 105), evdev(80)); // left
    try std.testing.expectEqual(@as(u16, 42), evdev(225)); // left shift
    try std.testing.expectEqual(@as(u16, 0), evdev(500));
}
