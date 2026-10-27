# Tesselix — Top-Level Design

Oct 9, 2026 · @feral keep

## Purpose and notation

This document records the top-level design of Tesselix: how the system is split, the binary format, the language and memory-safety model, and the main parts of the desktop the user sees. It builds on the design concept and on the human-factors reference. Details of individual apps are left for when they are built.

Notation:
- **(agreed)**: confirmed in discussion.
- **(suggestion)**: proposed, not yet confirmed.
- **[compositor]**: lives inside the compositor process, on or near the render and input path.
- **[desktop]**: lives outside the compositor, in separate processes.

"Desktop" in discussion can mean the compositor too; the tags say which side a subject belongs to.

## Foundations (agreed)

- **Tesselix** (formerly EZRA) is the whole system: compositor, desktop services and the apps shipped with it. The name comes from tessellation: windows tile the screen with no gaps and no overlaps.
- **Wayland only.** No X11 and no Xwayland. Apps that run only on X11 are not supported.
- **Latest libraries and Wayland protocols.** Versions are pinned per release and upgraded deliberately, not tracked automatically.
- **Latest solid versions** (agreed, 2026-10-14): a version line is used once it has been a stable release for at least 3 months, at its newest patch. Rule and current versions: `docs/dependencies.md`.
- **Language: Zig** for the compositor, the desktop services and Tesselix's own apps, so one shared Tesselix protocol library serves all of them (and gtty).

## Architecture

### Guiding rule

The compositor owns everything the user can see or touch and everything with a 0.1 s or per-frame deadline. Everything that thinks, learns or stores runs outside it, at lower priority, and talks to it only through Tesselix messages. If every desktop service crashes or hangs, the compositor keeps working as a plain, non-predictive desktop. The compositor is the most reliable part of the system.

### Components

```
┌──────────────────────────── COMPOSITOR PROCESS ────────────────────────────┐
│ Input path (highest priority) → Focus & hit-testing → Layout executor      │
│ Renderer (DRM/KMS) ← Animation clock ← Window model / surface scene graph  │
│ Built-in UI: title bars, menus, top bar, launcher, panel, placeholders,    │
│              auth prompt, highlight overlays, lock screen                  │
│ Action validator  ◀── structured actions                                   │
│ Event publisher   ──▶ scene-graph deltas, input summaries                   │
└───────────────┬────────────────────────────────────────────▲───────────────┘
                │ Tesselix messages (Unix socket)             │
┌───────────────▼──────────── DESKTOP SERVICES ───────────────┴───────────────┐
│ Context hub ─ AT-SPI collector, system-state sampler, temporal calendar     │
│ Recorder    ─ raw ring buffer (RAM) → episodes                              │
│ Memory      ─ episode store, salience, cycles, working sets (encrypted)     │
│ Agent       ─ classical predictors + small local model → actions/rankings   │
│ Gateway     ─ only process with network access; remote-model escalation     │
│ Sysadmin    ─ proposals only; privileged actions through polkit             │
├─────────────────────────────── SHELL APPS ──────────────────────────────────┤
│ Processes · Trash · File picker (portal) · Network · Sound · Bluetooth ·    │
│ Notifications · Displays · Power · Settings                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Component | Where | Job | Deadline / priority |
| --- | --- | --- | --- |
| Input path | [compositor] | Pointer, keyboard, gestures; the pointer moves every frame | Per frame, top priority |
| Window model | [compositor] | Outputs, workspaces, windows, surfaces, focus; the native part of the scene graph | Per event |
| Layout executor | [compositor] | Attention tiling, scaling levels, multi-screen moves, hysteresis. Deterministic; the agent only gives hints | ≤ 0.1 s to start, animation 150–250 ms |
| Renderer + animation clock | [compositor] | Every frame at display refresh, clock-timed animations, flash limits (WCAG 2.3.1) | Per frame |
| Built-in UI | [compositor] | Title bars and menus, icon menu, top bar, summoned launcher, panel, launch placeholders, polkit prompt, highlight overlays, lock screen | Appear ≤ 0.1 s |
| Action validator | [compositor] | Accepts agent actions from the fixed vocabulary, rejects anything that would move what the user is looking at, rate-limits | Async, never blocks input |
| Event publisher | [compositor] | Emits scene-graph deltas and input summaries; drops data for subscribers that fall behind instead of waiting | Non-blocking |
| Context hub | [desktop] | Merges compositor deltas with AT-SPI widgets, system state (PSI, cgroups, network, power), time and calendar; joins by PID/cgroup | Seconds |
| Recorder | [desktop] | Raw ring buffer in RAM, folds into episodes at boundaries, honours password and blacklist rules | Seconds |
| Memory | [desktop] | Episode log, salience with decay, cycle detection, working-set graph; encrypted at rest | Background |
| Agent | [desktop] | Predictors do most of the work; the small local model interprets them and emits actions and rankings | Seconds, low CPU priority |
| Gateway | [desktop] | Builds the summary, asks the user for approval, calls the remote model; the only component allowed to reach the network | On demand |
| Sysadmin | [desktop] | Cleanup ranking, health, throttle and freeze requests, proposals | Background |
| Shell apps | [desktop] | Separate processes shipped with Tesselix (see Shell apps) | Normal app |

### Rules of the split

- **The agent never touches windows directly.** It sends actions; the compositor validates and executes them. "Prepare, don't move" is enforced in one place.
- **Back-pressure goes one way.** The compositor never waits on a desktop service. Slow subscribers miss deltas and resync from a full snapshot.
- **The compositor detects client death itself,** from the client's socket closing. Its memory safety never depends on another process.
- **Process isolation follows trust.** The recorder and memory hold sensitive data and have no network. The gateway has network and sees only summaries. Privileged actions go through polkit, never through a background root service.
- **Shell apps are shipped with Tesselix but are not inside the compositor.** A hung panel can't freeze the screen.
- **Powerful compositor abilities** (drawing over other windows, capturing their clicks, attention signals) are granted only to Tesselix's own processes over the Tesselix protocol, never to arbitrary apps.
- Wayland clients talk the Wayland protocol. The Tesselix binary format is for Tesselix's own messages and stored data only.
- **D-Bus** (AT-SPI, NetworkManager, StatusNotifierItem, menus) is used through sd-bus or a Zig D-Bus library, not GLib.

### Influence files (agreed)

Files are the interface between prediction and the desktop. The desktop reads them; whoever writes them can change: simple time-based predictors first, the AI later. Socket messages stay for events and immediate actions; files carry slow-changing state such as rankings and predictions.

- **Fact files: what happened.** Written only by the recorder: which app was opened, when, with which file, for how long. The AI reads them and **never edits them**, so a wrong conclusion can't rewrite its own evidence.
- **Influence files: what the desktop should offer.** Predicted apps for the launcher, predicted contexts for the switcher, later group suggestions and layout hints. Written by the predictors now, by the AI later.
- **References, not free content.** An entry can only point to things that exist: an installed app, a file in the fact history, a known group. The reader resolves each one and drops what it can't, so the AI can rank and choose but can't inject a command or a path.
- **Fixed schema in the Tesselix binary format,** with the same validation ladder, so a broken or half-written file is detected and skipped.
- **One file per writer.** The reader uses the AI's file when it is valid and fresh, and falls back to the predictors' file otherwise. Turning the AI off, or the AI failing, brings back the simple predictions.
- **Each entry carries its source and a reason code** ("same time yesterday", "AI"), so the user can see why it is offered, and the AI's suggestions can be compared with the simple ones.
- **Atomic writes** (write a temporary file, then rename). Readers are notified and read the file when they next need it.
- **Read at the moment of use** and frozen while visible, so an update never changes what the user is looking at.
- **Sensitive like the history:** influence files contain file names, so they are encrypted at rest with it, or kept in memory and rebuilt after login.

## Tesselix binary format (agreed)

All internal communication and metadata are stored in binary. Every structure starts with a validation word so a reader can check it, repair it when possible, log the repair and continue.

### Structure header (8 bytes)

```
offset  size  field
0       4     magic    = 0xFFFFFFFB  (largest 32-bit prime, 4294967291)
4       2     type     structure type ID
6       2     version  schema version of that type
```

On disk and on the wire (little-endian): `FB FF FF FF`. Written by a big-endian machine: `FF FF FF FB`.

- **The 32-bit prime detects byte order completely.** A 64-bit magic (`0xFFFFFFFFFFFFFFC5`) would add no detection power.
- **Type and version** catch a reader that lands on the wrong structure, which the magic alone cannot.
- **8 bytes keep alignment** for the 64-bit fields that follow, on both 32-bit and 64-bit machines.

### Records (16 bytes)

Top-level records (a socket message, an entry in a stored file) add a length and a checksum:

```
offset  size  field
0       8     structure header (magic, type, version)
8       4     length   bytes of payload after this header
12      4     crc32c   checksum of the payload
```

Nested structures carry only the 8-byte header. The length lets a reader skip what it can't parse; the checksum catches damage inside the payload.

### Portability rules

- **Fixed-width fields only** (u8–u64, i8–i64, f32, f64). No native `int`, `long`, `usize` or pointers. 32-bit and 64-bit machines then produce identical bytes.
- **Canonical byte order is little-endian.** Every writer writes little-endian; a big-endian reader swaps on load.
- **Explicit padding** in every struct.
- **References are IDs or offsets,** never memory addresses. Compositor object handles (index + generation) can serve directly as Tesselix IDs.
- In Zig, structures are `extern struct`, and `comptime` generates the validation, byte-swap and repair code for every type from its single definition.

### Validation and repair ladder

1. **Magic matches, type known, version supported** → read normally.
2. **Magic byte-swapped** → swap every field by its schema, log, continue.
3. **Version newer than supported** → read the known prefix, skip the rest by length, log.
4. **Type unknown** → skip the record by its length, log.
5. **Checksum fails** → drop the record, log, continue.
6. **Magic not found** → scan forward for the next magic at 4-byte steps, log the bytes skipped, continue.

Repairs are logged with their source (socket peer, or file and offset) and counted per source. A source that keeps needing repair is reported as a bug.

### Known limits

- The magic is mostly `FF` bytes, close to memory filled with `0xFF`. Exact comparison still rejects such data.
- Being prime does not make the check stronger than another constant. Its value is in being fixed, asymmetric in byte order and easy to spot in a hex dump.

## Language and memory safety

### Zig, with conditions (agreed)

- **Ship in `ReleaseSafe` mode.** Bounds and overflow checks stay on.
- **Pin one Zig version** for the whole project and upgrade deliberately. Zig is pre-1.0 and its standard library changes between releases.
- **Keep notes on the current std APIs in the repo,** so AI-written code targets the pinned version rather than older APIs from its training.
- **Test with Zig's debug allocator** (leaks, double free, use-after-free) and **fuzz** the Wayland protocol handlers and the Tesselix decoder, since both parse untrusted input.
- Precedent: River is a Wayland compositor written in Zig on wlroots, using the `zig-wayland` and `zig-wlroots` bindings.

### Foundation: our own compositor, no wlroots (agreed, 2026-10-27)

Tesselix needs full control of every part of the window system, so that an advanced window manager, the debugger (`docs/debugging.md`) and the trust and sensitivity features (`docs/user-signals.md`) can be built without working around someone else's object model.

- **Own Wayland server:** `txwl`, pure Zig, no libwayland.
- **Own GPU renderer:** `txgl`, OpenGL ES 3.0 (OpenGL 3.3 core on the Mac). The compositor core records a draw list; the renderer turns it into quads.
- **Own Linux backend, on the system libraries** that every compositor uses: libdrm (KMS), GBM, EGL, libinput, libxkbcommon, libseat. No wlroots.
- **What this costs:** the hardware edge cases wlroots solves (atomic modesetting, buffer formats and modifiers, multiple GPUs, hotplug, explicit sync) are ours to solve. They are built step by step, behind a thin backend interface, and tested on the VM and on bare metal.

### Where the risk is

- A compositor is a single-threaded event loop. Pointers used and dropped inside one call are safe.
- The risk is pointers **stored past the current event** ("focused surface", "window under the pointer", "drag target"), and callbacks that destroy objects while a list is being iterated. A client can destroy a surface between two events.
- Wayland clients never see compositor pointers, only numeric IDs. The risk is entirely internal.
- Across threads and processes: handles or IDs only, never pointers.

### Object registry, handles and guards (agreed)

Every object type with a lifetime problem goes through one mechanism. Plain allocation is used for everything else.

- **Registry.** One per object type (surfaces, windows, outputs, input devices, popups, buffers). Each slot holds the object, a generation number, a state (live or dead) and a count of active guards.
- **Handle.** Index + generation, 8 bytes. The only thing stored long-term: in other objects, in focus state, in the scene graph, and as the Tesselix ID.
- **Guard.** Code that needs the real object acquires a guard and releases it with `defer`:

```zig
const win = windows.acquire(handle) orelse return; // gone → nothing to do
defer win.release();
win.ptr.resize(w, h);
```

  - `acquire` returns an optional, so the compiler forces every caller to handle "the object is gone".
  - `defer` releases the guard on every exit path, including errors.
- **Destroy** is idempotent:
  1. Mark the object dead and increase the generation. Every later `acquire` with an old handle returns null.
  2. Wait while guards are active or the GPU still uses the buffer.
  3. Free it at the end of the frame, once guards are zero and the GPU fence has signaled.
- **No guard survives the current event.** A counter of active guards must be zero when control returns to the event loop. The check is one integer per event and stays on in `ReleaseSafe`. Debug builds record where each guard was acquired.
- **C-owned objects** (libwayland's `wl_resource`, wlroots surfaces) are wrapped: the registry entry subscribes to the C object's destroy signal and calls `destroy(handle)`.
- **Limits:** Zig can't stop code from copying `win.ptr` somewhere; "never store the raw pointer" is a convention. Debug builds poison freed memory so an escaped pointer crashes immediately in testing.

The compositor's memory safety then comes down to two rules: **store handles, and use guards with `defer`.**

## Window layout [compositor]

The layout executor decides every window's size and position. Apps can ask (maximize, minimize, move, resize), but the compositor decides what each request means.

### Rules (agreed)

- **No free-floating windows.** A window is never placed by hand and never left hanging in the middle of the screen. Its position always follows from the layout rules.
- **Size first, then place.** When a window opens, its width and height are calculated from its content (optimal size), then the layout executor decides where it goes.
- **Rows.** A screen holds up to **2 rows** and up to **4 windows** in total (the limit of about 4 items recognized at a glance). For example: 2 windows in row 0 and 1 window spanning row 1; with a 4th, 2 and 2.
- **Row height comes from content.** A row of small apps (indicators, short tools) can be shorter than the other row, which gets the rest of the height.
- **Window tile** (agreed, 2026-10-14): the area the layout allocates to a window. Tiles cover the screen with no gaps or overlaps; windows sit inside them.
- **A window fills 99% of its tile** (a parameter; agreed 2026-10-28, was about 95%), centered, so a thin margin shows where the tile ends and that there is no more room. (Replaces "a window smaller than its space is centered at its optimal size".)
- **A tile is as wide as its window needs:** the optimal width divided by the fill. Leftover width goes to the tiles of windows whose content can use it (growable: documents and other reflowable content); if none can, it is shared equally.
- **Too little room:** a window with fixed content keeps its tile and a growable window reflows into the rest; between two of the same kind, the focused one keeps its size.
- **The user adjusts, within the rules.** Dragging the shared border between two tiles, or between the two rows, resizes both tiles and the windows in them. The border is drawn as a line with a grip; the whole gap between the two windows is the grab area. The result is learned as a preference for that app or context.
- **Swapping:** dragging a window's title bar onto another window's tile swaps the two windows. While dragging, every tile is outlined and the target is highlighted.
- **The user's choice wins.** If the user opens several apps next to one that needs the full screen, the layout serves that choice rather than preventing it.
- **Switcher.** Super+Tab scales the current view down and shows all other open windows, groups and predicted contexts around it (see Switcher).

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   editor             │   browser            │   row 0: tall, gets most of the height
│                      │                      │
├──────────────────────┴──────────────────────┤
│        ┌───────────────────────┐            │   row 1: as tall as its content needs;
│        │  short app (centered) │            │   a smaller window is centered
│        └───────────────────────┘            │
└─────────────────────────────────────────────┘
```

### Close, minimize, maximize, full screen (agreed, 2026-10-14)

Every window has four buttons: **close, minimize, maximize, full screen**.

- **Tiling appears only with two or more windows.** A lone window fills the whole work area, with no tile margin.
- **Close** ends the app; the remaining windows take the room, animated. The closed window shrinks to nothing at its center, fading as it goes (agreed, 2026-10-14).
- **Minimize** sends the window to the **panel**: it flies, scaled down, from where it was into its thumbnail. The remaining windows take the room; if one is left, it fills the screen.
  - **Minimizing shows the way too** (agreed, 2026-10-14): an outline travels from the window to its thumbnail, and the thumbnail flashes once when it lands. Windows sent to the panel by maximize flash there as well.
- **Maximize** has the effect of minimizing every other window: they fly to the panel and this window fills the work area. This is **maximized mode**.
  - While maximized, the maximize button shows **restore** (two overlapping squares). Restore brings back the windows that were tiled before, in their old order.
  - **Clicking a panel window** in maximized mode makes it the maximized window; the one that was maximized goes to the panel.
  - **Dragging a panel window** into the window area ends maximized mode and tiles the two windows; the others stay in the panel.
  - Minimizing or closing the maximized window also ends the mode and brings the others back.
  - Opening a new app ends the mode: the new window is tiled with the maximized one.
- **The panel lists every open app** (agreed, 2026-10-14; replaces "minimized windows only"), one entry per app in the order the apps were opened, as in the macOS Dock. It is on the left edge, below the top bar, always there, with one width. Its width comes out of the work area.
  - An entry is a live thumbnail of the app's most recently used window (or, when all are minimized, the most recently minimized), showing its top-left part, larger, with a large app icon resting on its bottom-left corner.
  - **On screen or minimized:** an app with a window on screen has a bar at the panel's edge beside its entry; an app whose windows are all minimized has its thumbnail dimmed.
  - **Clicking an entry** brings the window forward wherever it is, with the travel outline and the flash; a minimized one comes back to the window area; a full-screen one's space slides in.
  - **While the pointer is in an enlarged view** of a window that is on screen, that window's border on the desktop pulses slowly (one soft pulse every 1.2 s), so the eye finds it before clicking. (agreed, 2026-10-14)
  - At its top: **minimize all** and **close all**. Close all asks for a second click within 3 s ("Click again to close all"), since it can lose work.
  - At its bottom is the **apps button** (a grid of dots), which opens the launcher, so an app can be started again with the pointer alone.
  - **Hovering** a panel window shows it enlarged, past the panel's edge, with full-size buttons: **close**, **back to the window area**, **maximize** and **full screen**; a short label says what the hovered button does. The enlarged view works like the thumbnail: a click restores, a drag tiles. (agreed, 2026-10-14)
  - **Windows of one app are grouped** (agreed, 2026-10-14): one entry per app, with the **number of windows** in a red badge, in a large font, at its top-right corner.
  - **Hovering a group of several** lays all its windows out, enlarged, **over the window area**: a grid that starts beside the panel and grows to the right, then to a new row below, on a **semi-transparent** backing with a heading ("Notes: 3 windows"). The pointer can move between them; each has the same buttons as the single enlarged view, and a click brings that one back. **Esc** closes the view.
  - **Right-click an entry:** **Show all** (when the app has fewer than 4 windows and some are minimized) brings them back to the window area; **Minimize** sends the ones on screen to the panel; **Close all** closes them. In the enlarged views, the second button minimizes a window on screen and brings back a minimized one.
  - A **click** restores the window (outside maximized mode), which flies out of its thumbnail into a new tile.
  - **Every way out of the panel shows the way**, as from the launcher: an outline travels from the thumbnail (or the enlarged view) to where the window lands, the window grows out of it, then flashes once. (agreed, 2026-10-14)
  - A **drag** into the window area tiles the window where it is dropped: on the left or right half of the tile under the pointer, shown while dragging.
  - A **quick drag** (released within 0.3 s) puts the window in the first tile, next to the panel, wherever it is released.
  - Dragging a window's title bar onto the panel minimizes it.
- **Full screen**, separate from maximize: as on macOS, the window gets a **space** of its own (a workspace) and covers the entire screen, with no top bar and no panel. It zooms from its tile into the screen. The desktop keeps the other windows tiled.
  - The title bar is hidden; touching the top edge slides it down, with the four buttons. The full-screen button there shows **exit full screen** (arrows pointing in); the window shrinks back into its old tile.
  - Minimize or maximize on a full-screen window first leaves full screen.
  - Super+← and Super+→ slide between the desktop and the full-screen spaces. When a full-screen space exists, dots in the middle of the top bar (and at the right of the revealed title bar) show the spaces, the desktop as a square; clicking a dot goes there.
- Shortcuts: Super+X close, Super+Z minimize, Super+Enter maximize or restore, Super+F full screen.
- **Double-clicking a title bar** maximizes the window, or restores it when maximized (agreed, 2026-10-14).

### Suggestions

- (suggestion) **Opening a 5th window** sends the least recently used one to the panel, animated. Dropping the new window onto a slot replaces that slot's window instead.
- (suggestion) **Dragging a title bar** to another screen throws the window there; it never places it freely. (Swapping within a screen is agreed, above.)
- (suggestion) **Dialogs and popups** float, attached to their parent window.
- (suggestion) The limit of 4 stays per screen on large monitors too; a larger screen gives each window more room, not more windows.

## Launcher [compositor]

Opened by pressing and releasing **Super** alone. It shows all applications at once, after two sections: **Focus** (what the user really showed interest in) and **Recent** (the rest, by time).

### Layout (agreed)

- **A large rectangle covering most of the screen,** on the screen where the pointer is, centered on the pointer and clamped to the screen edges. The pointer is always inside it, near the center. Because it is large, it barely moves between openings, so its layout stays in almost the same place.
- **Three sections, in this order** (agreed, 2026-10-27): **Focus**, then **Recent**, then **All apps** (see `docs/user-signals.md`, "Focus, before recent").
  - **Focus** at the center, nearest the pointer: 3–4 entries.
  - **Recent** next to it: what is not in Focus, by time only (last opened first). (suggestion) 3–4 entries.
  - **All apps** around them, in a stable order (alphabetical or arranged by the user), never by usage. Visual groups of about 4.
- **Don't overload the user** (agreed, 2026-10-27): every item is shown once, and only where it matters most. Fewer, relevant items are easier to choose from than a long list (Human Factors, choice).
  - **Focus comes first; an entry in Focus never appears in Recent.**
  - **All apps lists only the apps not already shown** in Focus or Recent, in its stable order.
- **Opens on release of Super,** only if no other key was pressed while it was held, so Super+Tab and other shortcuts never flash it. Visible within 0.1 s.
- **No accidental hover:** highlights wait until the pointer actually moves.

### Focus and Recent (agreed)

- **An entry is an app, or an app with the file it had open** ("LibreOffice · report.odt"). Clicking it opens the app with that file. The file comes from the fact history, which stores a pointer to the file, never its content.
- **Focus is prepared first:** salience from real interest, and cycles that are due (this time yesterday, the same weekday last week, the same point last month), and what usually follows the current app. No language model is needed.
- **Recent is prepared second:** the entries not in Focus, by time only. (Before, recency was one of the predictions; now it is its own section.)
- **Later, the AI** writes its own influence file; the launcher reads whichever is valid (see Influence files).
- **Computed when the launcher opens, frozen while it is visible.**
- **An app already running** is focused (or opens the file in its existing window) rather than started again.
- **Running apps have a dot** under their name; two dots for two or more windows. (agreed, 2026-10-14)
- **Choosing a running app brings its window up wherever it is,** and shows the way to it: an outline travels from the icon to the window, then the window flashes once. A minimized window grows out of the icon into its tile; a new window grows out of the icon too; a full-screen window's space slides in. A window restored from the panel also flashes once when it lands. (agreed, 2026-10-14)
- **Two or more windows of the app:** a small floating panel opens under the icon with each window scaled down, labelled with where it is ("top left", "minimized", "full screen"), and a last tile for a new window. The window under the pointer is outlined on screen. Click one to bring it up; Esc or a click outside closes the panel. (agreed, 2026-10-14)
- **A new window of a running app:** hovering its tile shows a **"+"** at the icon's corner; clicking it opens a new window. Shift+click and Shift+Enter do the same. The chooser for several windows ends with a "New window" tile too. (agreed, 2026-10-14)
- **No history yet:** Focus is hidden or shows favorites; Recent is hidden until something was opened.
- A small reason under a Focus entry ("read for 25 min yesterday", "Mondays"); a Recent entry shows when it was opened ("yesterday 9:10").

### Filter (agreed)

Same as the switcher: on the first keystroke an edit box fades in at the top center and shows what is typed; the apps are filtered at once (any app, and file names on predicted entries); best match preselected, Enter opens it; Escape clears, then closes; both keyboard layouts. A section with no match becomes a ghost with a short "no match" label; if nothing matches, the whole grid is ghosted.

### Look (agreed)

- **A blurred rectangle as the launcher's wallpaper.** The desktop behind it is blurred inside the rectangle, and the edges fade into the sharp desktop.
- **Blur a snapshot, once,** at opening, at reduced resolution. The windows behind are frozen while the launcher is open; the user is focused on choosing the next app.
- **A light or dark tint over the blur** so icons and labels always have enough contrast.
- **Fade in** over 150–250 ms, never popping (epilepsy rule: no sudden brightness change).
- **One clear click boundary** inside the fade: inside is the launcher, a click outside closes it.
- **"Reduce transparency"** replaces the blur with a solid tint.
- **The switcher uses the same look.**
- The renderer needs its own blur shader; SceneFX (the wlroots scene-graph fork used by SwayFX) is a reference.
- Side note, to try later: with a GPU, the windows behind could keep refreshing under a live blur, so the user notices if something happens while choosing.

### Suggestions

- (suggestion) **Summoning with the mouse** (held button, gesture) opens the same launcher, since the pointer is inside it either way.

## Switcher [compositor]

Opened with **Super+Tab**. It replaces a separate "show all windows" mode. (agreed)

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│              │   [ search: as the user types ]│                  │
│ [▣] Mail     │                                │  ┌────┬────┐     │
│ [▣] Terminal │      current view              │  │ ed │ br │ grp │
│ [▣] Music    │      (scaled down,             │  └────┴────┘     │
│ [▣] Files    │       up to 4 windows)         │  ┌─────────┐     │
│   +5 more    │                                │  │  tax ×3 │ grp │
│ other apps   │                                │  recent groups   │
├──────────────┴────────────────────────────────┴──────────────────┤
│   [ tax report ]   [ dev: editor + ssh ]   [ morning mail ]       │  predicted contexts
└───────────────────────────────────────────────────────────────────┘
```

- **Current view:** the windows on screen shrink at once to a much smaller scale, in the center.
- **Left: other open windows,** top to bottom. Each is very small, with the app icon and a label to its right showing the window's title.
- **Right: recent groups** (up to 4). Each group is shown as its layout scaled down, larger than a single app on the left, with the titles of all its windows.
- **Bottom: predicted contexts,** a single row, from the agent's working sets.
- **Groups are made automatically.** When the user switches away from a view holding more than one window, that view becomes a group, and it appears on the right the next time.
- **Click** a window on the left: it replaces what is displayed. **Drag** it onto the current view: it is added to the view.
- **History and prediction stay apart:** the right side is what the user did, the bottom is what Tesselix expects.

### Filter (agreed)

- **The left strip shows about 4 to 7 windows;** beyond that it scrolls.
- **Typing filters at once,** across all three areas: windows, groups and contexts. What is typed appears in a search box above the scaled-down current view.
- **Matches are shown; non-matches are hidden.**
- **An area with no match at all** keeps showing its items as very transparent ghosts, so the layout never collapses or jumps.

### Scrolling (agreed)

- **The wheel scrolls the area under the pointer.** Over the current view or empty space, it scrolls the left strip, the area that usually overflows.
- **Side note, to try later:** scrolling all areas at once, at different speeds (the left strip faster than contexts, groups not at all). The switcher has few elements, so the user may quickly learn where to look. If tried, the predictable form is proportional: each overflowing strip moves so all reach their start and end together, and strips that fit don't move. Try it in the debug viewer or the working desktop.

### Suggestions

- (suggestion) **Hold to cycle.** Holding Super and tapping Tab moves through the recent groups; releasing switches. A single tap opens the switcher and keeps it open. Going back and forth between two contexts then becomes a habit.
- (suggestion) **Stable order** in the left strip (for example by opening time) rather than by recency, so each window keeps its place.
- (suggestion) **Click on the left** switches to that window alone, and the current view is saved as a group. **Drag onto a window** replaces that window; **drag into a gap or edge** adds it. Adding to a view that already holds 4 pushes out the least recently used one.
- (suggestion) **Group rules:** the same set of windows is one group, not a new one each time; a group remembers its layout (rows and borders); a window can belong to several groups; a closed group may stay as a context the agent can restore.
- (suggestion) **Clicking a predicted context** arranges its windows, launching missing apps with placeholders. About 4 contexts at most.
- (suggestion) **Search details:** a faint "type to filter" hint before typing; the best match preselected, Enter opens it, arrows move; Escape first clears the search, then closes the switcher; "+N more" at the end of the strip; a short "no match" label in a ghost area; typed keys matched in both Hebrew and English layouts.
- (suggestion) **Timing:** the shrink starts within 0.1 s of the key press and animates in 150–250 ms, interruptible; ghosts fade, never flicker.
- (suggestion) **At login,** the switcher opens on its own: no windows on the left yet, the groups from the last session on the right, predicted contexts at the bottom. Clicking a group restores it, launching its apps with their files and placeholders, in its saved layout. Escape or launching anything dismisses it; a setting turns it off. Tesselix restores apps, files and layout; state inside an app (browser tabs, cursor position) is the app's own.
- (suggestion) **Other ways to open it:** a gesture, the summoned surface, or pushing the pointer past a screen edge with a short dwell.

## Window chrome [compositor]

Title bars are drawn by the compositor for every app. They stay full size when a window's content is scaled down.

### Layout

```
at rest:   [icon] ·•• File Edit ┊ View… ┊        report.odt          [ free drag area ]
in use:    [icon] (⨯)(–)(+) File  Edit  View  Insert  Format  Tools  Help
```

Left to right: app icon, window buttons, app menu. The title is centered. The layout is the same in every language (see Languages).

### Window buttons

- Small at rest, so they act as a location cue without cluttering the bar. (agreed)
- **They expand to the right only** (agreed, 2026-10-14). The left edge of the group stays where it is, so the expanded buttons never cover the app icon. Expanded, each button takes the full height of the title bar, 1 px short at the top and bottom. The expanded group is drawn on top.
- (suggestion) If the window touches a screen edge, a button that would go off-screen is clamped to the edge.
- (suggestion) Protect close: a slightly larger gap before it, and it acts on release only if the pointer is still inside it.
- Touch and pen: the first tap expands, the second acts.
- Research: expanding targets are as fast to hit as targets that were always large, even when expansion starts late in the movement (McGuffin and Balakrishnan, 2002).

### App menu (agreed)

- **The menu belongs to its window,** in the title bar, never at the top of the screen.
- **At rest:** items are shown only up to a reserved drag zone around the title (about the middle third of the frame), so wider windows show more of the menu.
- **About to interact:** the whole menu grows across the bar and grows slightly in font size. Expansion triggers when the pointer slows or rests in the bar (about 80 ms) and collapses about 300 ms after it leaves, so passing over the bar doesn't trigger it.
- **The title stays visible** (agreed, 2026-10-14): while the menu is expanded the title moves to the right end of the bar instead of hiding; expanding the window buttons never hides it either.
- **The whole bar expands at once,** not item by item. Fisheye menus that magnify only the item under the pointer tested slower than plain menus (Hornbæk and Hertzum, 2007).
- **Overlay, don't resize.** The expanded bar is drawn over the top of the content; the app never re-lays itself out.
- **Stable positions:** for a given app the expanded menu always lays out the same way.
- **Press and move** anywhere on the frame, including on a menu item, moves the window. **Click** (press and release without moving) opens a menu.
- Too narrow for the full menu: as many top-level items as fit, then "»".
- **Keyboard:** Alt expands the focused window's bar, with access keys.
- **The summoned surface** shows the focused window's full menu with search, so any command can be found by name.
- **Source:** apps export their menus over D-Bus (`com.canonical.dbusmenu`, `org.gtk.Menus`), and the compositor renders them. Apps that don't export menus keep their own in-window menus.

### Languages (agreed)

- **The window layout never mirrors.** Buttons, icon and menu bar are at the top left in every language. Top-level menu items are laid out left to right in the app's order.
- **Dropdowns:** the width is calculated first, then text is aligned by its characters, using the first strong character (Unicode bidi, UAX #9). Each label is still shaped with normal bidi, so mixed labels render correctly.
- Shortcuts sit on the edge opposite the labels. Submenus open toward the side with room, with the arrow pointing that way. A dropdown always hangs from the left edge of its top-level item.
- The title is rendered with bidi, for mixed names like "דוח Q3.odt".

### Icon menu (agreed)

The app icon opens a menu for everything the window and the system own; the menu bar is the app's.

- **Opened by:** left-click on the icon (anchored under it), right-click on the icon or anywhere on the frame (at the pointer), or Alt+Space. The same menu opens wherever the app appears: title bar, panel thumbnail, summoned dock, launcher.
- **Moving between screens:** a small map of the monitors in their real arrangement, shown inline in the menu. One click on the target screen moves the window; it arrives at its optimal size, the layout there makes room, and focus and the pointer follow it.
- (suggestion) Contents, in groups of up to 4 that never change position:

| Group | Items |
| --- | --- |
| Window | Optimal size · Maximize · Move to screen (map) · Minimize |
| App | New window · Restart · Restart as root · Quit (all windows) |
| System | Resource use · Permissions · Force quit (only when not responding) |
| Assistant | Pin to favorites · Add to a working set · Don't learn from this app · Forget this app's history |
| Security (agreed: the group; suggestion: the items) | Trust of this app · Trust of this document · Mark as sensitive · Security settings… |

- (agreed) **Security** is where trust and sensitivity are managed in detail: the trust level of the app and of the object open in the window, raised trusts (from paste warnings) and taking them back, and sensitive marks. See `docs/user-signals.md`.

- No double-click-to-close on the icon.
- Force quit is user-initiated and asks for confirmation.

### Bottom border: status line (agreed)

All borders are 1–3 px. The bottom border carries the window's status and works the same on scaled windows and panel thumbnails.

| State | Bottom border |
| --- | --- |
| Normal | 1 px, plain |
| Progress (known) | 3 px, fill grows from left to right |
| Working (unknown length) | 3 px, a short segment moving slowly |
| Error or not responding | 3 px, **red and dashed**, plus an icon in the title bar |

- Red carries the meaning; the dash is there for users who can't see red.
- Motion is slow and smooth, never blinking (epilepsy rule).
- Sources of progress: launch estimates, `com.canonical.Unity.LauncherEntry` progress over D-Bus (used by many apps for downloads and copies), and Tesselix's own apps through the Tesselix protocol.

### Top frame: elevated privilege (agreed)

- **A red top frame plus a shield icon** means the window runs with elevated privilege.
- **Shown only for facts the compositor checked itself:** the client's user ID from the Wayland socket (`SO_PEERCRED`), or, for a terminal, a child process whose effective user ID is 0 in its process tree. gtty may add detail through the Tesselix protocol but never replaces the compositor's check.
- An app can't fake or hide this frame, because the compositor draws it.

## Launching apps (agreed)

- **A placeholder appears within 0.1 s** of the launch, at the window's final position and size, with the title bar. The other windows make room at that moment, so the layout changes once, when the user acts.
- **Size:** the compositor tells the app what size to be (Wayland `configure`), so the placeholder size is the final size. No statistics → maximized. With statistics → see Open questions.
- **Body:** the app icon and name on the theme background, faded in. (suggestion) No screenshot of a previous session.
- **Progress:** the bottom border shows launch progress.
  - Expected time = the average of the last few starts (about 5), so one glitch has little effect and a real change shows within a few launches.
  - **The expected time lands at 75% of the bar.** After that the bar creeps toward 100% ever more slowly.
- **Slow versus stuck:** past the expected time, the system-state layer checks the process. Still using CPU, disk or network → "working". Idle, or not answering the compositor's ping (`xdg_wm_base.ping`) → red dashed error state with a cancel option.
- **The placeholder's close button cancels the launch.**
- Keystrokes typed before the app is ready are not buffered (v1).

## Running as root

- **Any app can be run as root** from the launcher or the icon menu ("Run as root", "Restart as root"). (agreed)
- (suggestion) **Elevate the operation where possible, not the app.** Editors use the `sudoedit` pattern (edit a copy, write back as root); file managers use a polkit-backed helper (as GNOME's `admin://` does).
- (suggestion) **When the whole app must run as root:** launch through polkit (`pkexec`) with a clean environment and a separate home, so it never reads the user's config or creates root-owned files in the user's home. The Wayland socket is passed explicitly.
- **The compositor draws the password prompt,** so it can't be spoofed. It is a password field and is never recorded.
- A running app can't be elevated in place; "Restart as root" restarts it and warns about unsaved work.
- **AI rules:**
  - No prediction elevates: nothing is pre-launched or pre-warmed as root.
  - Authentication every time, cached at most briefly as polkit does.
  - The agent takes no automatic actions on root windows.
  - Being root grants no extra compositor permissions.

## Top bar and control center

### Top bar (agreed)

- The top bar stays, for status and quick controls only. **No app menu.**
- From the right corner: **gear (settings)** in the corner, then **control center**, then **indicators** to their left. A corner is the easiest target on the screen.
- **At the left corner: the apps button** (a 3 x 3 grid of dots), which opens the launcher. The same icon, much larger, sits at the bottom of the panel. (agreed, 2026-10-14)
- **Every icon in the top bar is a button,** with a hover tint. In the simulator the gear and the control center open a first small panel of switches (dark mode, learning, natural scrolling for wheel and touchpad); the real control center is still to be designed.
- The top bar appears on every screen.

### Control center (suggestion)

Groups of up to 4, each with a main control and details one click away:

| Group | Quick controls |
| --- | --- |
| Connectivity | Wi-Fi · Bluetooth · VPN · Airplane mode |
| Sound | Output volume · output device · mic mute |
| Display | Brightness · night light |
| Focus and power | Do not disturb · power profile · battery |
| Assistant | Pause learning |

- **"Pause learning"** is one click from anywhere, with an indicator in the top bar showing whether Tesselix is learning.
- **Mic and camera in-use indicators** are drawn by the compositor so no app can hide them, each with its own icon, not just a colored dot.
- Opens on the screen where it was clicked or summoned.

### Indicators

- **Tesselix's own indicators** (Wi-Fi, battery, sound, mic, learning) are built in, in fixed positions.
- **Third-party indicators** register through **StatusNotifierItem** (D-Bus) and appear to the left of Tesselix's. (agreed: no legacy X11 tray)
- (suggestion) Up to about 4 third-party indicators are visible; the rest go behind a "»" overflow, and the user chooses which stay visible.

### Bringing it to the pointer (agreed)

- Right-clicking the desktop opens a menu whose top row holds the gear, the control center and the key indicators, so the user doesn't travel to the corner.
- (suggestion) With attention tiling the empty desktop is rarely visible, so the same row also sits at the top of the **summoned surface** (dock/launcher at the pointer), reachable by the same hotkey or gesture from anywhere.

## Lock screen and greeter [compositor]

The **lock screen** covers a running session. The **greeter** is the login screen shown before any user session exists. Both are built after the compositor and the desktop; the greeter starts empty, but the place for information is part of the design from the beginning. (agreed)

### What they show (agreed)

- **Summaries only: counts, urgent flags and countdowns. Never content.** No senders, subjects, meeting titles, names or file names.
- **Greeter:** the summary of the user selected for login, for example "3 new messages, 1 urgent".
- **Lock screen:** the same rule, kept current while locked. For example "meeting in 3 minutes", with no details about the meeting.

### Summary structure (suggestion)

One Tesselix structure serves both screens. It has **no string fields at all**, so a bug or a careless service can't leak content onto the screen.

```
user summary
  generated_at   timestamp
  counts[]       (category enum, count)   mail, messages, notifications, tasks…
  urgent[]       (category enum, count)
  next_event_in  minutes, or none          meetings, Shabbat and chagim
  health_flags   bitfield                  backup failed, disk low, updates waiting…
```

### Where the data comes from (suggestion)

- **Lock screen:** the session is still running. Desktop services send the summary over the Tesselix socket; "urgent" comes from the agent and salience, countdowns from the temporal layer. The compositor only renders it.
- **Greeter:** the user's memory is encrypted and the session isn't running. The user's session writes the summary at logout and on lock into a small per-user file the greeter may read. It is a **snapshot**, so the greeter shows its age ("as of yesterday 18:40").
- **Opt-in per user, and per category.** Anyone at the machine can select a user and see the counts, so showing them is the user's choice.

### Rules (suggestion)

- **The compositor draws, services supply.** A missing or crashed service means an empty card, never a broken lock.
- **Information only.** No actions, launches or replies from the lock screen or greeter, so neither becomes a way around the lock.
- **Lock screen** uses `ext-session-lock-v1` inside the compositor.
- **Greeter** uses greetd as the login backend (PAM), runs inside Tesselix as the greeter's own system user, and reuses the lock screen's UI: the lock screen plus user and session choice. It accepts only system-sourced summaries and the per-user snapshot files.
- Password fields on both are never recorded.

## Shell apps [desktop]

Shipped with Tesselix, each in its own process. **Build the UI, reuse the standard backends,** so Tesselix stays compatible with every other app and tool.

| App | Backend | What Tesselix adds |
| --- | --- | --- |
| Processes | `/proc`, cgroups, process connector | See Process window |
| Trash | freedesktop Trash spec | Ordered by salience; snapshot before emptying |
| File picker | `xdg-desktop-portal` FileChooser | Search by memory and "relevant now" in every app's Open/Save dialog |
| Network | NetworkManager | Per-process traffic, unusual connections |
| Sound | PipeWire / WirePlumber | Per-app volume linked to its window |
| Bluetooth | BlueZ | Devices tied to the contexts they're used in |
| Notifications | `org.freedesktop.Notifications` | — |
| Displays | compositor | — |
| Power | UPower | — |

(suggestion) Quick controls (up to 4) in a small panel from the status item or summoned surface; "More" opens the full window.

## Process window

Today's process managers assume few processes, offer no real search and re-sort constantly. Details will be settled when the app is built; the direction:

### Scale

- **The process list is event-driven:** the kernel's process connector reports fork, exec and exit, so `/proc` isn't rescanned.
- **Totals per cgroup first** (systemd app scopes, `cpu.stat`, `memory.current`); per-process detail only for visible rows.
- **Data comes from the shared system-state sampler,** not the window's own polling.
- **Virtualized list:** only visible rows are rendered.
- **Views:** by app and window (grouped), process tree, flat, by user, by container.

### Search and lookup

- **Type-to-filter instantly** across name, command line, user, PID, window title, cgroup and container, with field filters such as `user:root cpu>10%`, `port:8080`, `file:~/reports/q3.odt`, `dir:/media/usb`.
- **"Who is using this?" lookups:**

| Question | Source |
| --- | --- |
| Who has this file open? | `/proc/*/fd`, `/proc/*/maps`, working directories |
| Who holds a lock on it? | `/proc/locks` |
| Who keeps this folder or drive busy? | Same, matching everything under the folder |
| Who uses this port? | `/proc/net/tcp`/`udp` matched to socket descriptors |
| Who uses the camera, mic or GPU? | `/dev/video*`, `/dev/snd/*`, `/dev/dri/*`, PipeWire streams |
| Which process owns this window? | The compositor (pick mode) |

- **The lookup appears where the pain is:** a failed unmount lists the processes keeping the drive busy; "Who is using this?" is available on files and folders in the file manager and picker.
- Seeing other users' and root's processes runs on demand through polkit.

### Process ↔ window (agreed)

- **Hover a row → its windows are highlighted:** a steady, thick outline with the app name and PID, faded in. Shelved windows are outlined on the shelf; windows on another screen get a marker at the screen edge pointing to them. Hover never moves anything.
- **"Go to window"** is an explicit action that brings the window into view and focuses it.
- **Pick mode:** in search mode, clicking any window, panel thumbnail or title bar jumps the process window to that window's process. The click is captured by the compositor and not passed to the app. The cursor and a label show the mode; Escape ends it.
- **Mapping:** the compositor knows each client's PID from the Wayland socket. Browsers and Electron apps map to the main process, with children listed; a single tab can't be identified reliably.

### Sorting (agreed)

- **Sorting by a changing field** (CPU, memory, I/O) orders the list once, at the click, by values smoothed over a few seconds. Values keep updating in place; rows don't move.
- **Switching ascending/descending** reverses the same snapshot.
- **Manual refresh** (button, F5) re-sorts with current values.
- **Idle auto-refresh:** after the user hasn't interacted with the window (scroll, selection, hover over the list, typing in search) for a time based on the number of visible rows, about 1–2 minutes, the list re-sorts, animated, keeping the selection.
- **While hidden or shelved,** the list refreshes freely, so it's current when shown.
- **Between refreshes:** exited processes stay in place, greyed and marked "exited"; new processes appear on refresh, announced by a "N new" chip; the header shows how old the order is.

### History and actions

- Sparklines per row for recent CPU and memory; "what used the CPU 2 minutes ago" from the sampler's recent history.
- **Actions go through `pidfd`,** never the PID number, so a reused PID can't be hit by mistake.
- **Graduated actions:** freeze (cgroup freezer, reversible) → lower priority → stop (SIGTERM) → force kill (SIGKILL, confirmed). Root processes go through polkit.

## Refresh rule for Tesselix's own windows (agreed)

Applies only to windows Tesselix builds; other apps are not classified for now. Each app runs its own idle timer from its own input events; visibility comes from standard Wayland (frame callbacks, xdg-shell "suspended").

The deciding question is whether an update moves something the user is looking at:

| View | Updates |
| --- | --- |
| Values in place | Every second or two |
| Load graphs (CPU, memory, GPU, network) | Every few seconds; new data appends at the edge |
| Sorted lists and rankings | Idle-based refresh plus manual refresh |
| Mostly static text | On idle, or when the tab is opened |

## Development plan

### Order of work (agreed)

**Compositor → desktop → greeter.** The compositor comes first because everything else runs inside it, including the greeter. A very basic greeter exists from the beginning so Tesselix can be started as a normal session; the full greeter with the summary card comes last, built on the lock screen.

Until then Tesselix is started nested from an existing desktop, from a TTY, or as a session in the existing display manager (a `.desktop` file in `/usr/share/wayland-sessions/`).

### Development environment

- **macOS for the platform-independent parts.** Zig runs natively on the Mac, but a Wayland compositor does not: it needs Linux kernel interfaces (DRM/KMS, libinput, dmabuf).
- **A Linux VM on the Mac for the compositor** (agreed). The compositor runs **nested**, as a window inside the VM's own Wayland session, so it can crash and restart without losing the desktop. (suggestion) UTM for a full desktop VM, or Lima for a light command-line one.
- (suggestion) **Fedora or Arch in the VM rather than Ubuntu.** Tesselix uses the latest libraries and Wayland protocols, and Ubuntu lags on wayland-protocols.
- (suggestion) **A headless backend for automated tests** (no screen, frames read back), so compositor tests run in the VM.
- **Bare-metal Linux later** (agreed), for what a VM can't show truthfully: direct DRM/KMS, real GPU buffers and fences, monitor hotplug, multiple physical screens, high refresh rates and fast mice.

### Performance in the VM (agreed)

- A VM has less CPU, slower memory and more scheduling noise, so design problems (allocating in the hot path, rescanning instead of reacting to events, blocking the event loop, thrashing memory) show up **more** there.
- The rule works in one direction: smooth in the VM means smooth on hardware. Stutter in the VM may come from the hypervisor, so check before blaming the code.
- **Timing instrumentation from day one:** input-event-to-frame-presented latency, frame time and time per event, recorded as histograms rather than averages. The same build then runs on the VM and on bare metal, and the numbers are compared directly.

### Code split for the Mac (suggestion)

Keep the backend layer (DRM/KMS, input, the GL context) thin, and put the logic in pure Zig that builds and tests on any OS:

- The Tesselix binary format: comptime validation, byte-swap and repair.
- The object registry: handles, guards, generations, tested with the debug allocator.
- The layout executor as pure logic: windows, content widths, focus and screen geometry in; rectangles and scale levels out.
- Menu and text layout: dropdown widths, bidi alignment, "»" overflow, expanding buttons.
- The scene-graph model and delta encoding.

A small debug viewer on the Mac (SDL or raylib) can draw the layout executor's output, so attention tiling can be seen working before the compositor exists.

### Steps (suggestion)

1. **Foundations on the Mac:** Tesselix binary format and the object registry, with unit tests.
2. **Minimal nested compositor in the VM:** one output, xdg-shell windows, keyboard and pointer, focus, clean handling of client death, timing instrumentation.
3. **Window chrome and layout:** title bars and buttons, status border, launch placeholder, attention tiling and scaling.
4. **Compositor ↔ desktop services:** Tesselix socket, event publisher with scene-graph deltas, action validator, a stub service on the other end.
5. **First end-to-end loop:** scene graph → episode log → ranked summoned launcher.
6. **Bare metal:** run from a TTY on DRM/KMS, multiple screens, session file for the display manager.
7. **Lock screen, then the full greeter** on top of it, with greetd as the backend.

Steps 1–5 fit entirely on the Mac and the VM.

## Open questions

- [ ] Layout: how an app declares that it is growable (now: any window with a document view), and whether the user can override it per app.
- [ ] Layout: which window goes to which row when a new one opens (by height needed, by order, or by the user's last layout)?
- [ ] Placeholder size from statistics: the largest non-maximized size used, or the most recent size for this app on this screen?
- [ ] Window buttons: confirm the suggested heading-based anchor, edge clamping and close protection.
- [ ] Dropdown alignment in mixed-language menus: per item, or per menu by the direction of most labels?
- [ ] Dragging the title-bar icon of a document window: carry the file (as on macOS), or nothing?
- [ ] "Run as root" when an app supports the safer helper mode: choose it automatically, or ask?
- [ ] Pick mode: always on in search mode, or a separate target button and key?
- [ ] Process window default view: by app and window, process tree, or the last view used?
- [ ] Control center: which issues in the macOS and GNOME versions to avoid.
- [ ] Is anything permanently visible at the bottom of the screen as a hint for the summoned dock?
- [ ] Greeter counts while the user is logged out: a snapshot from logout only, or kept current by an opt-in service that never touches the encrypted memory?
- [ ] Which summary categories are shown by default on the lock screen and the greeter.
- [x] Foundation: our own compositor, no wlroots (see "Foundation", 2026-10-27).
- [ ] Message transport: one hub, or the compositor publishing directly to each subscriber?
- [ ] Tesselix type ID registry: a single 16-bit space, or split by component?
- [ ] Schema language for Tesselix structures and code generation.
- [ ] Stored files: per-file header with creation info and encryption parameters.
