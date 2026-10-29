//! Kuroko build. One repo, one pinned Zig version (see build.zig.zon).
//!
//!   zig build test        all unit tests (any OS)
//!   zig build run         the simulator: compositor + desktop + apps (needs SDL3)
//!   zig build run-desk    the desktop-service stub (context hub)
//!   zig build run-desk -- apps scan   scan for installed apps (apps.krkde)
//!   zig build             everything
//!
//! For the Ubuntu ARM VM (from the Mac): `sh tools/ubuntu/build.sh`, which runs
//!   zig build -Dtarget=aarch64-linux-gnu --prefix ubuntu-share/kuroko

const std = @import("std");
const builtin = @import("builtin");

// Kuroko is pinned to Zig 0.16.x for development (0.17 before production).
// Other versions change the std APIs this code uses, so stop early with a
// clear message instead of a page of API errors.
comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
        @compileError("Kuroko needs Zig 0.16.0, but this is Zig " ++ builtin.zig_version_string ++
            ". Install 0.16.0 (brew install zig, or https://ziglang.org/download/) and put it first on your PATH.");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: it is how Kuroko ships (bounds and overflow
    // checks stay on), and Debug is too slow to judge scrolling by feel.
    // Use -Doptimize=Debug for debugging.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseSafe)") orelse .ReleaseSafe;

    // ---------------------------------------------------------- modules

    const core = b.addModule("txcore", .{
        .root_source_file = b.path("txcore/src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Sockets go through libc (see txcore/src/ipc.zig).
        .link_libc = true,
    });
    const widgets = b.addModule("txwidgets", .{
        .root_source_file = b.path("txwidgets/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "txcore", .module = core }},
    });
    const comp = b.addModule("txcomp", .{
        .root_source_file = b.path("txcomp/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "txcore", .module = core },
            .{ .name = "txwidgets", .module = widgets },
        },
    });
    const wl = b.addModule("txwl", .{
        .root_source_file = b.path("txwl/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "txcore", .module = core },
            .{ .name = "txwidgets", .module = widgets },
        },
    });
    const gpu = b.addModule("txgl", .{
        .root_source_file = b.path("txgl/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "txcore", .module = core },
            .{ .name = "txwidgets", .module = widgets },
        },
    });
    const controls = b.addModule("controls", .{
        .root_source_file = b.path("apps/controls/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "txcore", .module = core },
            .{ .name = "txwidgets", .module = widgets },
        },
    });

    // ------------------------------------------------------------ tests

    const test_step = b.step("test", "Run all unit tests");
    const headless = b.createModule(.{
        .root_source_file = b.path("tools/txsim/src/headless_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "txcore", .module = core },
            .{ .name = "txwidgets", .module = widgets },
            .{ .name = "txcomp", .module = comp },
            .{ .name = "controls", .module = controls },
        },
    });
    const apps_test = b.createModule(.{
        .root_source_file = b.path("txdesk/src/apps/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "txcore", .module = core }},
    });
    const trust_test = b.createModule(.{
        .root_source_file = b.path("txdesk/src/trust.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "txcore", .module = core }},
    });
    const focus_test = b.createModule(.{
        .root_source_file = b.path("txdesk/src/focus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "txcore", .module = core }},
    });
    const icons_test = b.createModule(.{
        .root_source_file = b.path("txdesk/src/icons.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "txcore", .module = core }},
    });
    const stub_test = b.createModule(.{
        .root_source_file = b.path("tools/txsim/src/sdl_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]*std.Build.Module{ core, widgets, comp, wl, gpu, controls, headless, stub_test, apps_test, trust_test, focus_test, icons_test }) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // --------------------------------------------------- desktop service

    const desk = b.addExecutable(.{
        .name = "txdesk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("txdesk/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "txcore", .module = core }},
        }),
    });
    b.installArtifact(desk);
    const run_desk = b.addRunArtifact(desk);
    if (b.args) |args| run_desk.addArgs(args);
    b.step("run-desk", "Run the desktop-service stub").dependOn(&run_desk.step);

    // ------------------------------------------------------- simulator

    const no_sim = b.option(bool, "no-sim", "Skip the SDL3 simulator") orelse false;
    if (!no_sim) {
        const sim_mod = b.createModule(.{
            .root_source_file = b.path("tools/txsim/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "txcore", .module = core },
                .{ .name = "txwidgets", .module = widgets },
                .{ .name = "txcomp", .module = comp },
                .{ .name = "controls", .module = controls },
                .{ .name = "txwl", .module = wl },
                .{ .name = "txgl", .module = gpu },
            },
        });
        // SDL3 is declared by hand in tools/txsim/src/sdl.zig (no C headers
        // needed); only the library is linked. Homebrew on Apple Silicon in
        // case pkg-config is missing.
        if (target.result.os.tag == .macos) {
            for ([_][]const u8{ "/opt/homebrew", "/usr/local" }) |prefix| {
                const lib = b.fmt("{s}/lib", .{prefix});
                std.Io.Dir.accessAbsolute(b.graph.io, b.fmt("{s}/libSDL3.dylib", .{lib}), .{}) catch continue;
                sim_mod.addLibraryPath(.{ .cwd_relative = lib });
                break;
            }
        }
        // Cross-compiling (the Mac building for the Ubuntu ARM VM): there
        // is no libSDL3 for the target here, so link against a stub that
        // only carries the names and the soname libSDL3.so.0. The target's
        // real libSDL3 is used at run time.
        const cross = target.result.os.tag != builtin.os.tag or target.result.cpu.arch != builtin.cpu.arch;
        const use_stub = b.option(bool, "sdl-stub", "Link SDL3 through a stub (default when cross-compiling)") orelse cross;
        if (use_stub) {
            const stub = b.addLibrary(.{
                .linkage = .dynamic,
                .name = "SDL3",
                .version = .{ .major = 0, .minor = 0, .patch = 0 },
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/txsim/src/sdl_stub.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            // By path, not linkLibrary: no build-cache RUNPATH in the binary.
            sim_mod.addLibraryPath(stub.getEmittedBinDirectory());
            sim_mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
        } else {
            sim_mod.linkSystemLibrary("SDL3", .{});
        }
        const sim = b.addExecutable(.{ .name = "txsim", .root_module = sim_mod });
        b.installArtifact(sim);
        const run_sim = b.addRunArtifact(sim);
        if (b.args) |args| run_sim.addArgs(args);
        b.step("run", "Run the simulator (compositor + desktop + apps)").dependOn(&run_sim.step);
    }
}
