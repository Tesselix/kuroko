//! The app registry: scanning for installed graphical apps and keeping
//! `apps.tslx` (see scan.zig).

pub const elf = @import("elf.zig");
pub const desktop_entry = @import("desktop_entry.zig");
pub const packages = @import("packages.zig");
pub const store = @import("store.zig");
pub const scan = @import("scan.zig");
pub const link = @import("link.zig");
pub const updates = @import("updates.zig");

test {
    _ = elf;
    _ = desktop_entry;
    _ = packages;
    _ = store;
    _ = scan;
    _ = link;
    _ = updates;
}
