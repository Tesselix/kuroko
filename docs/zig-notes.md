# Zig 0.16.0: std API notes

The project is pinned to Zig 0.16.0, the latest solid version (see
`docs/dependencies.md`). Zig 0.17 becomes solid on 2027-01-04; move then, or
before production at the latest (see "Moving to 0.17" below). Update this file
whenever the pin moves.

## Program entry, allocator, I/O

- `main` takes `std.process.Init`, which carries the allocator, the I/O
  implementation and the arguments:

  ```zig
  pub fn main(init: std.process.Init) !void {
      const gpa = init.gpa; // leak-checked in Debug
      const io = init.io;
      const args = try init.minimal.args.toSlice(init.arena.allocator());
  }
  ```

- Everything that touches the OS goes through `std.Io` and takes `io`:
  files (`std.Io.Dir`, `std.Io.File`), clocks, sleeping, networking.
- Pure code (txcore format, registry, layout, widgets) does not need `io`.
  Keep it that way: pass time in as `now: i64` nanoseconds.
- Tests: `std.testing.allocator` (reports leaks).

## Output

```zig
var buf: [4096]u8 = undefined;
var w = std.Io.File.stdout().writer(io, &buf);
const out = &w.interface;
try out.print("{d}\n", .{n});
try out.flush();
```

Writing a file:

```zig
var file = try std.Io.Dir.cwd().createFile(io, path, .{});
defer file.close(io);
var fw = file.writer(io, &buf);
try fw.interface.writeAll(bytes);
try fw.interface.flush();
```

## Time

- `std.time.nanoTimestamp` and `milliTimestamp` are gone. Use
  `std.Io.Timestamp.now(io, .awake)` (monotonic) and `.durationTo`,
  `.toMilliseconds()`; the raw value is `.nanoseconds` (an `i96`).
- Sleep: `io.sleep(.fromSeconds(2), .awake)`.
- `std.time.ns_per_ms` and friends still exist.

## Sockets

- `std.posix` lost `socket/accept/read/write/close/getenv`. `std.Io.net` has
  Unix sockets (`std.Io.net.UnixAddress`), but its calls block the task.
- The compositor needs non-blocking sockets in its own loop, so
  `txcore/src/ipc.zig` calls libc directly (`std.c.socket`, `accept`,
  `write`, ... with `std.c.errno`). Modules using it link libc.
- `std.posix.sigaction` and `std.posix.sigemptyset` still exist.

## Containers (unchanged from 0.15)

- `std.ArrayList(T)` is unmanaged: `.empty`, pass the allocator to every call
  (`append(gpa, x)`, `appendSlice`, `insertSlice`, `replaceRange`,
  `toOwnedSlice`, `deinit(gpa)`). `pop()` returns an optional.
- `std.EnumArray(E, V)`: `.initFill(v)`, `.init(.{ ... })`.
- `std.heap.DebugAllocator(.{})` replaces `GeneralPurposeAllocator`.
- `std.mem.trimRight` is now `std.mem.trimEnd`.

## Language

- No `usingnamespace`. `@splat(v)` initializes arrays.
- Casts infer their result type: `@intCast`, `@floatFromInt`,
  `@intFromFloat`, `@ptrCast(@alignCast(p))`.
- A runtime `if` choosing between comptime_int values needs a type:
  `@as(i32, if (c) 10 else 0)`.
- Locals may not shadow a declaration (`const rate = self.rate()` errors).
- `@embedFile` paths must stay inside the module's root directory.
- `std.fmt.bufPrint` must not format into the buffer it reads from
  (`@memcpy arguments alias` in safe builds).

## Build system

- `b.addModule(name, .{ .root_source_file, .target, .optimize, .link_libc,
  .imports = &.{ .{ .name, .module } } })`.
- `b.addExecutable(.{ .name, .root_module })`, `b.addTest(.{ .root_module })`.
- The build runner has an `io`: `b.graph.io` (for example
  `std.Io.Dir.accessAbsolute(b.graph.io, path, .{})`).
- C libraries: `module.linkSystemLibrary("SDL3", .{})` uses pkg-config.
- Avoid `@cImport` (deprecated in 0.16, removed in 0.17; in 0.16 it fails on
  macOS ARM headers such as `arm_neon.h`). Declare the few C functions needed
  with `extern "c"` and check struct layouts with comptime asserts, as in
  `tools/txsim/src/sdl.zig`.
- `build.zig.zon` needs `.name = .enum_literal` and a `.fingerprint`.

## Moving to 0.17

Known work, from the 0.17 release (October 2026):

- `@cImport` is removed (deprecated in 0.16). Tesselix does not use it: the
  simulator declares SDL3 by hand. The wlroots backend should do the same or
  use the translate-c package.
- The build system splits configuration and execution into separate
  processes; check custom build steps.
- `@bitCast` rules were revised; array multiplication (`**`) is removed in
  favor of `@splat`.
- ZLS needs to catch up with the new build server protocol; check before
  switching while working in VS Code.
- The Linux backend: zig-wlroots targets Zig 0.15 (wlroots 0.20). Either it
  catches up, or Tesselix keeps a thin wlroots binding of its own.
