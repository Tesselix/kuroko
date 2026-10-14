# Implementation notes

Decisions made in code where the design documents leave a question open, and
known limits of the current code. Each item points to the open question it
touches. Change the code and this file together.

## Open questions answered provisionally

| Question (document) | What the code does now | Where |
| --- | --- | --- |
| Type ID registry: one space or split (Top-Level) | High byte names the component: `0x01` assets, `0x02` compositor → services, `0x03` services → compositor, `0x04` widget protocol, `0x7F` tests | `txcore/src/types.zig` |
| Which row a new window goes to (Top-Level) | By order: windows 1–2 in row 0, 3–4 in row 1 | `txcomp/src/tiling.zig` |
| Window fill of its tile | 95%; `tiling.Params.fill` | `txcomp/src/tiling.zig` |
| Growable windows | A window with a document view; the rest have fixed content | `txwidgets/src/window.zig` |
| Optimal size of a framework window | Measured from the widget tree unless the app gives a size | `txwidgets/src/window.zig` |
| Opening a 5th window (Top-Level, suggestion) | The least recently focused window goes to the shelf | `txcomp/src/compositor.zig` |
| Notch rates between bands (Look and Controls) | Fast from 7 notches/s, very fast from 16 notches/s, bursts up to 1.2 s; parameters in `txcore.wheel.Params` | `txcore/src/wheel.zig` |
| Map: pages and where sliding starts (Look and Controls) | 5 pages, sliding from the middle | `txwidgets/src/scroll.zig` |
| Magnifier size (Look and Controls) | 6 lines, up to 520 px or two thirds of the content width | `txwidgets/src/doc_view.zig` |
| Key for "back after a jump" (Look and Controls) | Alt+← (Option+← on a Mac); 16 positions kept | `txwidgets/src/doc_view.zig` |
| Center marker visibility (Look and Controls) | While scrolling and while the map is open; fades over 0.4 s after 1 s at rest | `txwidgets/src/doc_view.zig` |
| Exact theme colors (Look and Controls) | First values in `txcore/src/theme.zig`, light and dark | |
| Text stack and 2D rendering (Widget Framework) | Stopgap: own CPU rasterizer and pre-rendered Inter atlases; no shaping, no bidi, no Hebrew yet | `txwidgets/src/canvas.zig`, `font.zig` |
| Quick drag out of the panel (Top-Level) | Released within 0.3 s of the press; `quick_drag_ms` | `txcomp/src/compositor.zig` |
| Where a restored window goes after maximize (Top-Level) | The old tile order; the maximized window keeps its place, or goes last if it came from the panel | `txcomp/src/compositor.zig` |
| Footprints (Look and Controls) | A section counts as read after 3 s at the middle of the view while not scrolling; in memory only | `txwidgets/src/doc_view.zig` |

## Zig version

- Zig 0.16.0, the latest solid version (rule in `docs/dependencies.md`).
  Notes on the APIs and the 0.17 move: `docs/zig-notes.md`.
- The simulator uses SDL3, declared by hand in `tools/txsim/src/sdl.zig`
  (no `@cImport`).
- Sockets use libc directly (`txcore/src/ipc.zig`) because `std.Io`'s
  networking blocks the calling task and the compositor must never wait.

## Binary format details

- Records are padded with zeros to a multiple of 8 bytes, so 64-bit payload
  fields stay aligned and the resync rung can scan in aligned steps. The
  length field holds the unpadded payload length.
- A truncated record at the end of a stream is not a repair: the reader stops
  and keeps the bytes for the next read. A file reader calls `finish()` to log
  the cut.

## Simulator (macOS)

- Apps run in-process and implement `txwidgets.Surface`, the subset of what
  Wayland plus the Tesselix protocol will carry.
- Wheel versus touchpad is guessed from fractional deltas; macOS reports no
  device type. Final tuning of the bands happens on Linux with libinput.
- Cmd is Super. Shortcuts avoid Cmd+W, Cmd+Q and Cmd+M, which the SDL window
  menu takes on macOS.
- Launch times are simulated per app (`start_ms`), so the launch placeholder
  and its progress can be seen.

## Animation over slow frames

- A frame more than 40 ms after the previous one is a stall (for example apps
  redrawing at a new size on a HiDPI screen). Running compositor animations
  (window moves, flights to and from the panel, the travel outline, flashes,
  closing, full-screen zoom, space slides) are held for the stall, so they
  play from where they were instead of jumping to the end.
  `Compositor.holdOverStall`.

## Known limits

- The gear and the control center open the same small panel of switches for now.
- The simulator window is shrunk to fit the screen's usable area unless `--size` is given; scripted runs keep 1440 x 900.

- Rows of widgets do not wrap, so a fixed-content window dragged narrower than its content is cut on the right.
- A launch placeholder counts as growable until the app attaches; the layout may adjust once when the app reports its real size.
- No clipboard, no text area, no fill helper, no search field, no date picker
  yet.
- The launcher uses a solid tint; the blurred snapshot needs the GPU renderer.
- The panel (minimized windows) has no hover preview and no scrolling; entries that do not fit above the apps button are not shown.
- Full-screen spaces exist only for full-screen windows; there are no general workspaces yet.
- A window that goes to the panel before it was ever tiled is drawn at its optimal size for the thumbnail.
- Menus in the title bar are labels only; dropdowns are not built.
- Scaled-down unfocused windows (multi-level scaling) are not done; windows
  that do not fit are resized.
- No peer-credential check on sockets yet (`SO_PEERCRED`, Tessel Store).
