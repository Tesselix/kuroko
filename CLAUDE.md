# Working on Kuroko

Read this first, then the design documents in `docs/` for the part you touch.

## Sources of truth

- `docs/top-level-design.md` wins over every other document.
- `docs/widget-framework.md` and `docs/look-and-controls.md` define the widget
  library and every control's behavior.
- `docs/human-factors.md` is the reference for timing, motion, choice and
  accessibility rules. `docs/design-concept.md` is the vision.
- `docs/implementation-notes.md` records decisions made in code that the
  documents leave open. Update it when you make one.

## Versions

- Every tool and library uses the latest **solid** version: a stable line out
  for at least 3 months, at its newest patch. See `docs/dependencies.md` and
  update it with every upgrade.

## Zig

- Pinned to **Zig 0.16.0** for development; 0.17 before production. Use
  `docs/zig-notes.md` for the current std APIs; do not use older APIs from
  memory (for example `std.fs.File`, `std.time.nanoTimestamp`,
  `std.process.argsAlloc`, managed `ArrayList`, `usingnamespace`).
- Build `ReleaseSafe` (the default here). Tests use the leak-checking allocator.

## Rules (from the Widget Framework, "Rules for AI code generation")

1. Store handles (`txcore.Handle`), use guards with `defer`; never keep a raw
   pointer past the current event. `endEvent()` checks this.
2. The compositor never waits on another process. Writes are non-blocking;
   client death is detected from the socket closing.
3. Every structure that crosses a process or reaches disk is a Kuroko record
   (`txcore.format`), with fixed-width fields, little-endian, extern structs.
   Register type IDs in `txcore/src/types.zig`. Files of Kuroko records
   use the extension `.krkde` (for example `apps.krkde`).
4. Theme roles only, never hard-coded colors. No state by color alone: add a
   shape cue. Nothing flashes more than 3 times per second.
5. Acknowledge input within the frame; animations are clock-timed,
   150–250 ms, ease-out, interruptible.
6. Behavior is parameters, controller commands and events, and fixed
   policies. No app code runs inside an interaction; events never veto.
7. Keep logic in pure Zig that builds and tests on macOS; backends stay thin.
8. No app-specific logic in the library or the compositor.

## Layout and commands

See `README.md`. `zig build test` must pass before a commit. New widgets and
behaviors get a place in `apps/controls`.

## The simulator

`tools/txsim` is a thin SDL3 backend for macOS. Everything it does must be
expressible over the real protocols (Wayland plus the Kuroko protocol);
`txwidgets/src/surface.zig` is that contract.
