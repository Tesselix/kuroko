# Implementation notes

Decisions made in code where the design documents leave a question open, and
known limits of the current code. Each item points to the open question it
touches. Change the code and this file together.

## Open questions answered provisionally

| Question (document) | What the code does now | Where |
| --- | --- | --- |
| Type ID registry: one space or split (Top-Level) | High byte names the component: `0x01` assets, `0x02` compositor → services, `0x03` services → compositor, `0x04` widget protocol, `0x7F` tests | `txcore/src/types.zig` |
| Which row a new window goes to (Top-Level) | By order: windows 1–2 in row 0, 3–4 in row 1 | `txcomp/src/tiling.zig` |
| Window fill of its tile | 99% (the user, 2026-10-28; was 95%); `tiling.Params.fill` | `txcomp/src/tiling.zig` |
| Growable windows | A window with a document view; the rest have fixed content | `txwidgets/src/window.zig` |
| Optimal size of a framework window | Measured from the widget tree unless the app gives a size | `txwidgets/src/window.zig` |
| Opening a 5th window (Top-Level, suggestion) | The least recently focused window goes to the shelf | `txcomp/src/compositor.zig` |
| Notch rates between bands (Look and Controls) | Fast from 7 notches/s, very fast from 16 notches/s, bursts up to 1.2 s; parameters in `txcore.wheel.Params` | `txcore/src/wheel.zig` |
| Map: pages and where sliding starts (Look and Controls) | 5 pages, sliding from the middle | `txwidgets/src/scroll.zig` |
| Magnifier size (Look and Controls) | 6 lines, up to 520 px or two thirds of the content width | `txwidgets/src/doc_view.zig` |
| Key for "back after a jump" (Look and Controls) | Alt+← (Option+← on a Mac); 16 positions kept | `txwidgets/src/doc_view.zig` |
| Center marker visibility (Look and Controls) | While scrolling and while the map is open; fades over 0.4 s after 1 s at rest | `txwidgets/src/doc_view.zig` |
| Exact theme colors (Look and Controls) | First values in `txcore/src/theme.zig`, light and dark | |
| Text stack and 2D rendering (Widget Framework) | Stopgap: own CPU rasterizer and pre-rendered Inter atlases; no shaping, no bidi, no Hebrew yet. The compositor's frame goes to the GPU as a draw list (see "GPU rendering") | `txwidgets/src/canvas.zig`, `font.zig`, `draw_list.zig` |
| Top-bar menu icons (Top-Level) | 32 px buttons side by side with no gap, 2 px from the right edge, so the row is one target; the date and time sit right-aligned in a fixed 124 px slot in the corner, so the icons do not move as it changes; the learning indicator sits 8 px left of the language icon. The simulator formats the date as "Fri Oct 30  13:35" (24-hour, English) until locale formatting exists | `txcomp/src/shell.zig` |
| Top-bar menus (Top-Level) | Under the bar at the right, 8 px from the edge; control center 320 px wide, device center 380, the others 300. Details (a connection's, a device's) replace the menu's content in the same panel, as on macOS, not a separate dialog. Wi-Fi joins a network with one click; the password prompt comes with the backend. A user action changes `menus.System` at once; the desktop service will confirm or correct it, and the compositor never waits for it | `txcomp/src/menus.zig` |
| Dialogs (Top-Level, "Dialogs") | Kept outside the window registry, in their own list (`dialogs.zig`); the content gets a 6 px frame with 14 px corners, so its square corners stay inside. Dimming for a modal one is the theme's shadow color at alpha 90, over the parent's frame or the whole screen. A window asks for a dialog through `Surface.take_dialog` (Wayland: a new toplevel with a parent), picked up once per frame. A second request from the same desktop dialog name raises the open one instead of opening another | `txcomp/src/dialogs.zig`, `txcomp/src/compositor.zig` |
| Mobile-first widgets (Widget Framework) | Rows are 44 px, 54 with a subtitle; a grouped list's card takes the other of `surface` and `surface_alt` from the window's background; a header bar centers its title on the whole bar; a scroll area scrolls by 44 px lines with the document view's wheel physics. A top-level column now takes the window's height, so a scroll area in it gets the room left | `txwidgets/src/window.zig` |
| Panel icon size (Top-Level) | 52 px icons, 14 px apart, centered in the 76 px panel; a status line runs under the icon | `txcomp/src/compositor.zig` |
| Quick drag out of the panel (Top-Level) | Released within 0.3 s of the press; `quick_drag_ms` | `txcomp/src/compositor.zig` |
| Reorder preview (Top-Level, Swapping) | The pointer rests 0.12 s on a tile before its window moves aside (`reorder_dwell_ms`); a drop before that still swaps. The target is found in the tiles as they were when the drag began, so a swap that moves the borders cannot flip it back and forth | `txcomp/src/compositor.zig` |
| Where a restored window goes after maximize (Top-Level) | The old tile order; the maximized window keeps its place, or goes last if it came from the panel | `txcomp/src/compositor.zig` |
| How app and object trust combine (User Signals) | An unknown object leaves the app's level; otherwise the lower of the two | `txcore/src/trust.zig` |
| Which apps are trusted (User Signals) | Kuroko's own apps always; an installed app (in the registry) unless the user marks it; any other app only when marked | `txcore/src/trust.zig`, `txcomp/src/compositor.zig` |
| A mark on a folder (User Signals) | Covers every file under it; the nearest marked folder wins, and a file's own mark wins over any folder | `txcore/src/trust.zig` |
| Who decides Focus and Recent (User Signals, Top-Level "Influence files") | txdesk: its recorder writes the facts (`facts.krkde`), its simple predictor the lists (`focus.krkde`); the compositor only reads them | `txdesk/src/focus.zig` |
| What earns Focus, for now | Keyboard-focus time, halving every 3 days, at least 2 minutes' worth; or a cycle that is due (opened in the first hour of the day on ≥ 3 days and on more than half of the last 14 days with use), during today's first hour | `txdesk/src/focus.zig` |
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
  Wayland plus the Kuroko protocol will carry.
- Wheel versus touchpad is guessed from fractional deltas; macOS reports no
  device type. Final tuning of the bands happens on Linux with libinput.
- Cmd is Super. Shortcuts avoid Cmd+W, Cmd+Q and Cmd+M, which the SDL window
  menu takes on macOS.
- Launch times are simulated per app (`start_ms`), so the launch placeholder
  and its progress can be seen.

## GPU rendering (txgl)

- **Draw list.** `Canvas` reduces every call to six physical-pixel
  primitives (fill, rounded rect, circle, line, glyph, image) and sends
  each through one function: rasterized at once, or recorded with its clip
  (`Canvas.recorder`). The compositor's `render` is unchanged; the backend
  chooses which canvas it gets.
- **CPU and GPU draw the same list.** `Canvas.replay` rasterizes a recording
  with the same code, so it is pixel-identical to drawing directly (tested
  per primitive and for whole compositor frames, which also checks that the
  core is deterministic).
- **Renderer** (`txgl/src/renderer.zig`): one shader; every primitive is a
  quad. Shapes use the canvas's signed-distance formulas, glyphs one shared
  R8 texture packed on first use, images RGBA textures (swizzled from
  0xAARRGGBB in the shader). Clips are scissor rects; quads are batched
  until the clip or the image changes. Premultiplied output.
- **Window pictures are kept on the GPU.** Each window buffer has an id (new
  per buffer) and a version (new per redraw); a texture is uploaded only
  when the version changes, and dropped after 120 frames unused. A closing
  window's shrinking picture keeps its id, so it is never uploaded again.
- **GL versions:** OpenGL ES 3.0 on Linux, OpenGL 3.3 core on macOS (its
  newest GL is 4.1). Functions are loaded at run time from the backend's
  loader (SDL now, EGL on DRM later); nothing links libGL.
- **Scaled pictures are smoothed** on the GPU (linear filtering); the CPU
  picks nearest pixels. Thumbnails differ slightly between the two paths.
- **Simulator:** GPU by default; `--cpu` or `TX_GPU=off` keeps the CPU path,
  and the CPU is the fallback if no GL context or shader works.
  `--snapshot FILE --gpu` reads the GPU frame back (to compare with the
  CPU's).
- **Measured** (`--tiled`, 12 s, same session): VM (virgl → ANGLE → Metal,
  1920x1163) frame build 4.1 ms mean on the GPU, 8.5 ms on the CPU; Mac
  4.2 ms and 7.3 ms.
- **Not yet:** Wayland apps' buffers are still copied into the window
  picture on the CPU (then uploaded); next they become textures of their
  own, then `linux-dmabuf` (no copy at all). The first frame is slow
  (shaders compile, glyphs upload).

## Identity and trust

- **Who a window belongs to.** txwl takes the client's PID from the socket
  (`SO_PEERCRED`) and its binary from `/proc/<pid>/exe` at connect time. The
  compositor keeps both per window and publishes them before the window's
  `opened` record (`SceneIdentity`, with the window's trust and the app's
  part of it), and again when the trust changes.
- **Marks.** txdesk keeps the user's marks in `trust.krkde` next to
  `apps.krkde` (`TrustMark`: app, file or folder; trusted or untrusted; the
  time; for an app, its signature: SHA-256 of the binary). It sends them to
  the compositor on connect (`DeskTrust` snapshot) and when they change.
  `txdesk trust ...` edits the file; a running txdesk notices (stat) and
  resends.
- **One set of rules** (`txcore/src/trust.zig`), used by both txdesk and the
  compositor. The compositor decides; txdesk only stores.
- **An installed app counts only by its own binary.** A client that claims
  an installed app's id (Wayland app id) with another binary gets no trust
  from it: shown on the VM with a copy of Alacritty at another path.
- **Marking from the compositor** (`requestTrust`, `markWindowApp`,
  `markWindowObject`): applies at once, then goes to txdesk
  (`TrustRequest`), which saves it and confirms. This is what the window's
  Security menu will call; the menu itself is not built yet (title-bar menus
  are labels only).
- **Signatures** are computed by txdesk (the compositor never reads a
  binary): when the user marks an app, and for each window's binary in its
  scene printout, cached per file version (size, time, inode). Recorded,
  not yet checked against marks.
- **The object in a window** is set through `setWindowObject`; nothing
  feeds it yet (fact 2 in User Signals: Kuroko apps, AT-SPI, open files).
  Until then a window's trust is its app's.
- On macOS (the simulator) there is no `/proc`: outside apps have no binary,
  so they are untrusted unless marked; Kuroko's own apps are trusted.

## Focus and Recent

- **Facts.** txdesk records one use per window from the scene it already
  mirrors: opened, closed, and seconds with keyboard focus. The app is its
  binary (from `SceneIdentity`), or its app id for Kuroko's own apps.
  Saved to `facts.krkde` when a window closes and at most once a minute;
  kept 60 days, at most 5000 uses.
- **Prediction** runs when windows open or close, keyboard focus moves,
  and once a minute (interest fades, cycles start and end). Focus first (up
  to 4), then Recent: the rest, by last opened, time only (up to 4).
  `focus.krkde` is written, and the compositor told (`DeskNotice`), only
  when the lists change.
- **The compositor** reads `focus.krkde` through its backend (the core does
  no I/O), when the launcher opens after a notice; the lists are frozen
  while it is visible. References it cannot resolve (an app no longer
  installed) are dropped. Without the file, Focus is empty and Recent is
  this session's launches, so the desktop works without txdesk.
- **The launcher** shows Focus, Recent, then all other apps: every app
  once. Focus and Recent share a row when they fit, else Recent goes under
  Focus. Each of their tiles has a reason line: "42 min this week",
  "usually now", "5 min ago", "yesterday".
- **Pause learning** (the top bar's Learning switch) is published to the
  services (`SceneSession`); while it is off, txdesk records nothing and
  ends the uses in progress.
- **Limits now:**
  - Apps only: nothing reports which file a window shows yet, so entries
    are never "app · file".
  - No login events: the first window of the day stands in for the login.
  - No idle detection: a focused window counts while the user is away.
  - `facts.krkde` and `focus.krkde` are readable by the user only (mode
    0600) but not encrypted yet, which the design asks for (Top-Level
    Design, "Sensitive like the history"). `trust.krkde` is 0600 too.

## App icons

- **txdesk draws them, the compositor copies pixels.** After each scan,
  txdesk turns each installed app's icon file (resolved from its desktop
  entry) into 64 and 128 px squares, the icon centered, and keeps them in
  `icons.krkde` (`IconImage`, straight-alpha ARGB). Only new or changed icon
  files (by time) are drawn again. The compositor reads the file when told
  (`DeskNotice.icons_changed`) and never decodes an image format: icon
  files come from packages Kuroko does not control.
- **PNG** is decoded by txdesk itself (every color type and depth, palettes
  with transparency; interlaced files are skipped). **SVG** goes through
  `rsvg-convert` (librsvg, installed by `setup.sh`). Scaling averages areas
  when shrinking and is bilinear when growing, on premultiplied colors.
- **Drawing:** the canvas has `drawImage` for images with their own alpha
  (window pictures stay opaque); the GPU renderer has a matching shader
  branch. The launcher, title bars, panel thumbnails and launch
  placeholders show the icon; an app without one keeps its letter tile.
  Kuroko's own apps have no icon files yet.
- **Not yet:** icon themes (only the path the desktop entry resolves to),
  and the compositor reads `icons.krkde` on its own loop (a few hundred KB,
  once per change).

## Text: Hebrew and direction

- **Glyphs:** Inter has no Hebrew, so each UI atlas has a Hebrew fallback
  atlas of the same size and weight, rendered from Noto Sans Hebrew
  (`fonts/hebrew-*.krkde`, `tools/fontgen/gen_fonts.py --hebrew`). A glyph is
  looked up in the UI atlas, then the fallback, else drawn as '?'. Other
  scripts (Arabic, CJK, emoji) still show '?'.
- **Points and cantillation** (U+0591–U+05C7 marks) are kept as empty,
  zero-width glyphs: placing them over their letter needs shaping, which
  the atlases do not have. Text with niqqud shows its letters only.
- **Direction:** `txwidgets/src/bidi.zig` reorders each drawn line from
  logical to visual order: a subset of UAX #9 (paragraph direction from the
  first strong letter, digits and neutrals resolved by their neighbors,
  runs reversed, brackets mirrored). No explicit embeddings or isolates.
  `Canvas.text` draws in visual order; `textEllipsis` puts the ellipsis on
  the left in right-to-left text. Labels are still placed (left, centered)
  as before, whatever their direction.
- **Text fields** still place the caret and selection in logical order, so
  editing Hebrew in a Kuroko text field is not right yet.

## Animation over slow frames

- A stall is a frame that comes much later than the machine's usual pace:
  over 40 ms and over 2.5x the usual gap between frames (for example apps
  redrawing at a new size on a HiDPI screen). The usual gap is learned while
  drawing continuously (`FramePace`; gaps over 100 ms are idle time and do
  not count), so a slower machine (the VM, a software renderer) animates in
  real time with fewer frames instead of in slow motion.
- Compositor animations that were running at the previous frame (window
  moves, flights to and from the panel, the travel outline, flashes,
  closing, full-screen zoom, space slides) are held for the stall, so they
  play from where they were instead of jumping to the end. Animations that
  started after the previous frame (by the input that ended an idle pause)
  are never held. `Compositor.holdOverStall`.
- The simulator reports the real frame rate on exit ("frame interval");
  SIGINT/SIGTERM end it cleanly with that summary.

## Ubuntu ARM VM

- `tools/ubuntu/build.sh` (or `make ubuntu` from the root `Makefile`) cross-compiles for `aarch64-linux-gnu`. The simulator links
  against a stub libSDL3 (`tools/txsim/src/sdl_stub.zig`, soname
  `libSDL3.so.0`) because the Mac has no SDL3 for the target; a test keeps
  the stub in step with `sdl.zig`. At run time the VM's real libSDL3 is
  loaded.
- Zig derives `.fingerprint` in `build.zig.zon` from the package `.name`, so
  a rename breaks every build ("invalid fingerprint"). `tools/fingerprint.sh`
  takes the value zig suggests and writes it in; `build.sh` and the
  `test`, `run`, `clean` and `clean-ubuntu` make targets run it first.
- On the VM the simulator runs inside `cage` (Wayland kiosk, wlroots) with
  `SDL_VIDEODRIVER=wayland`, `WLR_RENDERER=gles2`. SDL3's KMS/DRM driver does
  not work in UTM: it scans out ARGB8888 framebuffers, and the virtio-gpu
  primary plane accepts only XRGB8888 (the commit fails, the console stays on
  screen). wlroots' Vulkan renderer finds only llvmpipe there. SDL's desktop
  OpenGL renderer needs GLSL 1.30 that virgl does not offer, so the renderer
  is `opengles2` (then `software`). The full-screen window takes the
  display's exact size. Kuroko's own Linux backend replaces all this.

## App registry (txdesk)

- txdesk keeps `~/.local/state/kuroko/apps.krkde` (Kuroko
  records `0x05xx`; `txcore/src/types.zig`): the apps, every file the
  scanner has looked at with its size, mtime and inode, and the search
  paths. txdesk is the only writer; a temporary file is renamed over the
  old one. Code in `txdesk/src/apps/`.
- Order: known apps are `stat`ed (gone: ghost; changed: version read
  again); the search paths are walked, skipping known files, inspecting new
  ones; then desktop entries not seen before name and describe the apps.
  On the VM the first scan takes about 0.35 s, a rescan about 7 ms.
- "Graphical" means: the binary calls a window-creating function
  (XCreateWindow, gtk_window_new, SDL_CreateWindow, ...) or carries the
  `xdg_wm_base` interface name, or a desktop entry a launcher shows names
  it. Linking a display library alone is a display client (xrandr). Data
  is searched for `xdg_wm_base` only in binaries that link a display
  library or that a desktop entry names. X11-only apps are left out unless
  `--x11`. Display servers (Xwayland, cage) are never apps.
- Known false positive: `gtk-builder-tool` (a window only in one
  subcommand). The planned Apps tool sets per-file overrides
  (`always_skip`, `always_app`), which the scanner never changes.
- A shell wrapper is followed through its last `exec` line;
  `"$VAR/name"` is taken relative to the script's folder (Chrome's
  `exec -a "$0" "$HERE/chrome"`). Scripts in other languages are found
  only through desktop entries.
- A ghost is revived when a new graphical binary has the same file name
  and, when both are known, the same package; only an unambiguous match.
- Packages: dpkg's `info/*.list` and `status`, read directly (merged /usr:
  `/bin/x` and `/usr/bin/x` both tried); snap and Flatpak by path. snap and
  flatpak themselves are not app keys: their apps are keyed by the path
  that names them (`/snap/bin/chromium`).
- The running txdesk loads `apps.krkde`, sends the compositor a snapshot
  when it connects (types `0x0301` DeskApp), scans at start and then every
  5 minutes, checks apt updates (`apt-cache policy`, no root, no network)
  at start and every 6 hours, saves when something changed, then sends the
  changed apps and a `saved` marker with the save count. The compositor
  keeps a read-only copy (`txcomp/src/apps.zig`); a skipped count makes it
  ask for a snapshot (`0x0202` DeskRequest). Entries are never removed from
  the copy, only hidden, so launcher indices stay valid.
- The launcher shows the installed apps after the built-in ones, with
  64 px icons for all. Installed apps get a letter tile until icons are
  decoded (PNG/SVG need a dependency). A ghost is faded with a dashed
  outline and "not installed" and does not start; an update is an up
  arrow in a circle on the icon. Running the upgrade waits for a password
  prompt (polkit).
- Starting an installed app: the compositor runs its command with
  `posix_spawnp` (`txcore/src/proc.zig`), field codes dropped, never
  waiting; SIGCHLD is ignored so children are reaped. Its window opens in
  Kuroko (see "Wayland server").
- `run.sh` sets `XDG_SESSION_TYPE=wayland`: Chrome and Electron choose
  Wayland from it; without it they try X11 and exit (no X server here).
- Hidden desktop entries that only carry another id (Chrome's
  `com.google.Chrome.desktop`, `NoDisplay=true`) are not read yet; the
  compositor will need them to match a window's Wayland app id.

## Wayland server (txwl)

- Pure Zig on libc sockets (no libwayland): the wire format, fds over
  SCM_RIGHTS, the peer's pid (SO_PEERCRED; its binary from
  /proc/<pid>/exe). Builds and tests on macOS with a test client.
- Globals: wl_compositor 6, wl_subcompositor 1, wl_shm 1 (ARGB8888,
  XRGB8888), wl_output 4, wl_seat 7 (pointer, keyboard), xdg_wm_base 5,
  zxdg_decoration_manager_v1 (always server side), wl_data_device_manager 3
  (accepted, ignored: no clipboard yet), wp_cursor_shape_manager_v1.
- The compositor decides: configure carries the tile's size and the states
  (activated, maximized, fullscreen, tiled on all edges); move, resize,
  maximize and full-screen requests only get the current state back. A
  frame of another size is cut or padded, never stretched.
- Shared memory only (no linux-dmabuf): on commit the picture is copied
  and the buffer released at once; GPU apps fall back to software (Chrome)
  or do not start (apps that need EGL, such as Alacritty). Subsurfaces are
  applied at once (no synchronized commits). Popups are placed with the
  positioner inside the window's content and clipped to it; a click
  outside a grabbing popup closes the popups. Keyboard focus stays on the
  window surface (not on grabbing popups).
- Keymap: the standard US layout by name (includes resolved by the app's
  libxkbcommon from xkb-data). Keys travel as evdev codes; txsim maps SDL
  scancodes (`tools/txsim/src/keycodes.zig`). Modifiers come from the
  input event (Shift, Ctrl, Alt, Super); Caps Lock is not tracked.
- Windows: a new toplevel is adopted by the compositor on its first
  commit, matched to the registry by the client's binary, then by app id;
  an unknown app gets a hidden entry. A launch from the launcher shows a
  placeholder that the window replaces, failed after 60 s without one.
  Closing asks the app (xdg_toplevel.close) and the window stays until the
  app destroys it.
- Socket `$XDG_RUNTIME_DIR/wayland-kuroko-N` with a lock file per name;
  apps Kuroko starts get WAYLAND_DISPLAY, XDG_SESSION_TYPE=wayland and no
  DISPLAY. Kuroko's sockets and received fds are close-on-exec.
- txsim polls the server: with apps connected the loop wakes every 4 ms.
  No ping/pong yet (a stuck app is not detected), and a client that
  shrinks its shared-memory file after creating a pool could fault the
  compositor (no SIGBUS guard yet).

## Known limits

- Desktop dialogs are opened by the backend (`Compositor.desktop_dialogs`); in the simulator, `openDesktopDialog` in `tools/txsim/src/main.zig` stands in for txdesk. The language dialog gets a copy of the languages and a callback that applies Done straight to `menus.System`; on Linux that is a message to txdesk, which tells the compositor.
- Labels do not wrap yet, so dialog notes are kept short.
- The top-bar menus act on `menus.System` in the compositor only: no desktop service reports connections, sound, devices or layouts yet, and no command goes out. The simulator fills it with samples (`sampleSystem` in `tools/txsim/src/main.zig`); without them the lists are empty and the layout is "EN".
- The simulator window is shrunk to fit the screen's usable area unless `--size` is given; scripted runs keep 1440 x 900.

- Rows of widgets do not wrap, so a fixed-content window dragged narrower than its content is cut on the right.
- A launch placeholder counts as growable until the app attaches; the layout may adjust once when the app reports its real size.
- No clipboard, no text area, no fill helper, no search field, no date picker
  yet.
- The launcher uses a solid tint; the blurred snapshot needs a blur pass in the GPU renderer.
- The panel has no scrolling; entries that do not fit above the apps button are not shown.
- Full-screen spaces exist only for full-screen windows; there are no general workspaces yet.
- A window that goes to the panel before it was ever tiled is drawn at its optimal size for the thumbnail.
- Menus in the title bar are labels only; dropdowns are not built.
- Scaled-down unfocused windows (multi-level scaling) are not done; windows
  that do not fit are resized.
- The compositor's own socket (txdesk and other services) has no
  peer-credential check yet (Tessel Store); Wayland clients do.
