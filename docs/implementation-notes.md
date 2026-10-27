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
| Text stack and 2D rendering (Widget Framework) | Stopgap: own CPU rasterizer and pre-rendered Inter atlases; no shaping, no bidi, no Hebrew yet. The compositor's frame goes to the GPU as a draw list (see "GPU rendering") | `txwidgets/src/canvas.zig`, `font.zig`, `draw_list.zig` |
| Quick drag out of the panel (Top-Level) | Released within 0.3 s of the press; `quick_drag_ms` | `txcomp/src/compositor.zig` |
| Where a restored window goes after maximize (Top-Level) | The old tile order; the maximized window keeps its place, or goes last if it came from the panel | `txcomp/src/compositor.zig` |
| How app and object trust combine (User Signals) | An unknown object leaves the app's level; otherwise the lower of the two | `txcore/src/trust.zig` |
| Which apps are trusted (User Signals) | Tesselix's own apps always; an installed app (in the registry) unless the user marks it; any other app only when marked | `txcore/src/trust.zig`, `txcomp/src/compositor.zig` |
| A mark on a folder (User Signals) | Covers every file under it; the nearest marked folder wins, and a file's own mark wins over any folder | `txcore/src/trust.zig` |
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
- **Marks.** txdesk keeps the user's marks in `trust.tslx` next to
  `apps.tslx` (`TrustMark`: app, file or folder; trusted or untrusted; the
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
  feeds it yet (fact 2 in User Signals: Tesselix apps, AT-SPI, open files).
  Until then a window's trust is its app's.
- On macOS (the simulator) there is no `/proc`: outside apps have no binary,
  so they are untrusted unless marked; Tesselix's own apps are trusted.

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
- On the VM the simulator runs inside `cage` (Wayland kiosk, wlroots) with
  `SDL_VIDEODRIVER=wayland`, `WLR_RENDERER=gles2`. SDL3's KMS/DRM driver does
  not work in UTM: it scans out ARGB8888 framebuffers, and the virtio-gpu
  primary plane accepts only XRGB8888 (the commit fails, the console stays on
  screen). wlroots' Vulkan renderer finds only llvmpipe there. SDL's desktop
  OpenGL renderer needs GLSL 1.30 that virgl does not offer, so the renderer
  is `opengles2` (then `software`). The full-screen window takes the
  display's exact size. Tesselix's own Linux backend replaces all this.

## App registry (txdesk)

- txdesk keeps `~/.local/state/tesselix/apps.tslx` (Tesselix
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
- The running txdesk loads `apps.tslx`, sends the compositor a snapshot
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
  Tesselix (see "Wayland server").
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
- Socket `$XDG_RUNTIME_DIR/wayland-tesselix-N` with a lock file per name;
  apps Tesselix starts get WAYLAND_DISPLAY, XDG_SESSION_TYPE=wayland and no
  DISPLAY. Tesselix's sockets and received fds are close-on-exec.
- txsim polls the server: with apps connected the loop wakes every 4 ms.
  No ping/pong yet (a stuck app is not detected), and a client that
  shrinks its shared-memory file after creating a pool could fault the
  compositor (no SIGBUS guard yet).

## Known limits

- The gear and the control center open the same small panel of switches for now.
- The simulator window is shrunk to fit the screen's usable area unless `--size` is given; scripted runs keep 1440 x 900.

- Rows of widgets do not wrap, so a fixed-content window dragged narrower than its content is cut on the right.
- A launch placeholder counts as growable until the app attaches; the layout may adjust once when the app reports its real size.
- No clipboard, no text area, no fill helper, no search field, no date picker
  yet.
- The launcher uses a solid tint; the blurred snapshot needs a blur pass in the GPU renderer.
- The panel (minimized windows) has no hover preview and no scrolling; entries that do not fit above the apps button are not shown.
- Full-screen spaces exist only for full-screen windows; there are no general workspaces yet.
- A window that goes to the panel before it was ever tiled is drawn at its optimal size for the thumbnail.
- Menus in the title bar are labels only; dropdowns are not built.
- Scaled-down unfocused windows (multi-level scaling) are not done; windows
  that do not fit are resized.
- The compositor's own socket (txdesk and other services) has no
  peer-credential check yet (Tessel Store); Wayland clients do.
