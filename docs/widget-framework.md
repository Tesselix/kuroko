# Kuroko — Widget Framework

Oct 14, 2026 · @feral keep

## Purpose and notation

One widget framework serves two kinds of apps **(agreed)**:

- **Kuroko's own desktop apps in Zig** (file manager, process window, trash, settings…). They must run as fast as possible.
- **Third-party apps for Kuroko in any language.** Developers can ship Kuroko apps without writing Zig or graphics code.

This document builds on the Top-Level Design. Where they differ, the Top-Level Design wins. Notation is the same: **(agreed)**, **(suggestion)**, **[compositor]**, **[desktop]**.

## Corrections to the first draft

The first draft put the widget tree inside the compositor and used text messages. Both contradict agreed decisions.

| First draft | Corrected | Why |
| --- | --- | --- |
| Widget tree, layout and rendering inside the compositor | In the app's own process, or in a UI host process per app [desktop] | Shell apps are separate processes; a bug in a file manager's list must never crash the session. The compositor keeps only its built-in UI. |
| JSON / YAML over the socket | Kuroko binary format records | All of Kuroko's own messages are binary, with the validation and repair ladder. A text format may exist for authoring, compiled ahead of time. |
| Socket in `/tmp` | `$XDG_RUNTIME_DIR/kuroko/`, mode 0700, peer checked with `SO_PEERCRED` | Per-user, not world-reachable. |
| Any client may target an "Overlay" layer | Third-party apps get normal windows only | Powerful compositor abilities belong only to Kuroko's own processes. |
| String IDs carried in events | Numeric node IDs; names stay client-side | Matches registry handles; cheap and safe to validate. |
| Hex colors and free styles | Theme roles ("surface", "accent", "danger") | Lets the framework guarantee contrast, light/dark, reduce transparency, flash limits, and that no state is shown by color alone. |
| Clients never use GTK or Qt | Only apps built on this framework | Any Wayland app (GTK, Qt, others) still runs on Kuroko. |
| "X11/Wayland-style split" | Kuroko's own split | Framework apps are Wayland windows; the app-to-host protocol is Kuroko's. |

## Architecture

Every framework window is a normal Wayland window (xdg-shell). The compositor draws its title bar, places it with attention tiling and treats it like any other app. The framework draws what is inside the window.

```
 Mode A: in-process (fastest)          Mode B: headless app (any language)

┌──────────────────────────┐          ┌─────────────┐ Kuroko  ┌─────────────────────┐
│ App: Zig, or any language│          │ App: Python,│◀─────────▶│ UI host (Zig),      │
│ through the C ABI        │          │ Go, JS…     │ Unix sock │ one per app         │
│   └─ widget library      │          │ no drawing  │           │   └─ widget library │
└────────────┬─────────────┘          └─────────────┘           └──────────┬──────────┘
             │ Wayland (xdg-shell, buffers)                                │ Wayland
             ▼                                                             ▼
        ┌──────────────────────────── COMPOSITOR ─────────────────────────────┐
        │ chrome, layout, focus, scene graph                                  │
        └─────────────────────────────────────────────────────────────────────┘
   widget tree, menus, status, content width ──Kuroko protocol──▶ compositor / context hub
```

### One library, two modes (suggestion)

- **Widget library (Zig).** Owns the widget tree, layout, text, input, animation and rendering into the window's buffers.
- **Mode A, in-process.** Kuroko's own apps link the library directly: no IPC per event or per frame. The library also exports a C ABI, so any language with FFI (Rust, Go through cgo, Python through cffi, C) can use it in-process too.
- **Mode B, headless.** The app sends its tree and handles events over a socket; a small UI host process, running the same library, renders it. For scripts, languages without easy FFI, and developers who want no native code at all. The app sleeps at 0% CPU until an event arrives.
- **The same structures in both modes.** Mode A calls functions with the structures that Mode B sends as messages. One schema, one behavior, and an app can move from Mode B to Mode A when it needs speed.
- **One UI host per app,** not one shared host: a crash takes down one app, permissions follow the app's identity, and the cost is a few MB per app. systemd socket activation with one process per connection is a simple way to spawn them.
- **The host runs in the app's cgroup scope** and tells the compositor the app's PID. Otherwise the compositor would see the host's PID, and the process window, system state and "which process owns this window" would point at the host instead of the app.

### Why not inside the compositor

- The compositor must stay the most reliable part. Parsing and laying out trees from untrusted apps there adds attack surface and risks missed frames.
- Built-in compositor UI (launcher, switcher, chrome, top bar, lock screen) stays in the compositor. (suggestion) It may reuse the widget library's code, compiled in, never fed by clients.

## Protocol (Mode B)

### Lifecycle

1. **Connect** to the UI socket in `$XDG_RUNTIME_DIR/kuroko/`. The peer is checked with `SO_PEERCRED`.
2. **Hello:** protocol version, app ID and capabilities; the host replies with its version and the current theme.
3. **Declare:** create a window and send its tree as a batch of node records.
4. **Run:** the host renders and handles hover, press, focus, scrolling and text editing itself.
5. **Events:** the host sends events with the node ID; the app answers with changes.
6. **Close:** the socket closing means the app is gone. The host destroys its windows; stale IDs resolve to nothing (registry handles and generations).

### Messages (suggestion)

- Every message is a **Kuroko record:** 16-byte header (magic, type, version, length, crc32c), with the full validation and repair ladder.
- **Node IDs are u32, chosen by the app** per connection, so a whole tree can be sent without waiting for replies. The host maps them to registry handles.
- **Strings** are length-prefixed UTF-8 inside the payload.
- **Atomic commits:** changes are grouped and applied together at the next frame, so the user never sees a half-applied update.

| Direction | Messages |
| --- | --- |
| App → host | hello, window create/close, node create, set property, move, remove, commit, list rows (reply), status (progress, working, error), menu export |
| Host → app | hello reply, event (node, kind, modifiers, value), list rows request (range), window state (size, visible, suspended), theme changed, error |

- **Limits** on message size, nodes per window, tree depth and message rate. A message over the limits is rejected with an error; the host never stalls.

### Bindings

- **The schema is the source of truth;** bindings are generated per language. This makes the Top-Level open question "schema language and code generation" a prerequisite for the framework.
- (suggestion) First bindings: Zig (native), a C header for the C ABI, then Go and Python.
- (suggestion) An optional text layout format for authoring, compiled to binary by a build tool. Hosts never parse text at run time.

## Widget model: parameters, controllers, policies (agreed)

Every widget is defined by three things, the same in Mode A and Mode B. The design takes the useful part of Flutter's controllers (state and commands separate from configuration) and leaves out what cannot work when the host never waits on the app.

### Parameters: what the widget is

- **Plain data,** set at creation and changeable later: theme roles, sizes, alignment, the scroller's marker settings.
- Validated and limited like every other input from an app.
- They cover most customization: an app uses the default widget and adjusts its parameters.

### Controller: live state, commands and events

- **Every widget has a controller: its node ID.** The app never creates or disposes of one.
- **Commands:** for example `scroll_to(line)`, `jump_back()`, `set_text`, `select(range)`, `focus`.
- **State:** current position, viewport range, selection, value.
- **Events:** coalesced notifications, for example `scrolled` (at most a few per second), `scroll_stopped`, `jumped`, `text_changed`, `submitted`.
- **Mode A:** a typed Zig handle with methods. **Mode B:** the same commands and events as messages, from the same schema.
- **Events are notifications, never vetoes.** The host never waits for the app. Rejecting input is declarative (a policy), or done afterwards by the app correcting the state through the controller.

### Policies: behavior from a fixed set

- Behavior is customized by **choosing from a fixed set,** never by app code running inside an interaction.
- Examples: jump anchor (pointer height or center marker); text filters (digits, number, email, max length), enforced by the library at keystroke speed; scroll physics (the standard bands, with only the speed scale adjustable).
- This keeps the 0.1 s acknowledgement and the human-factors rules (flash limits, acceleration caps, stable sorting) in the library, where third-party apps can't break them.

### Shared behavior and custom widgets

- **Linked scrolling** (a diff view, line numbers beside code) is a "scroll link group" parameter. Widgets in one group scroll together, handled entirely in the library.
- **Custom widgets** are built by composing existing widgets, not by overriding their internals. Custom-drawn widgets in Mode A are out of scope for v1, since they would break "the same structures in both modes".

### Parameter precedence

```
library defaults → user's system settings → app's parameters → user's per-app overrides
accessibility settings (reduce motion, reduce transparency, contrast) above all
```

- Each parameter in the schema states whether an app is allowed to set it at all.
- Example: the scroller's markers (see Look and Controls). The user sets them system-wide in Settings; a code editor may default the center marker to always on; the user can still override that for the editor.

## Widgets

### Who does what

- **The library:** layout, hit-testing, hover and press states, focus and keyboard navigation, text editing, scrolling, animation, theme.
- **The app:** business logic and data.

### Initial set (suggestion)

| Kind | Widgets |
| --- | --- |
| Containers | Row, column, grid, stack, scroll area |
| Basic | Label, icon, image, button, toggle, checkbox, slider, text field, password field, progress bar |
| Data | Virtual list and table with sort header, tree, sparkline and load graph |
| Surfaces | Dialog attached to its parent, popover, menu |

### Mobile first (agreed, 2026-10-30)

The widgets start from what works on phones (iOS and Android), the most refined widget sets today, not from the classic desktop ones; the pointer and keyboard get hover tints, focus rings and shortcuts on top.

| Widget | What it is |
| --- | --- |
| Header bar | Title in the middle, a plain action at the left (Cancel), the main one at the right (Done), as at the top of a phone sheet |
| Search field | A rounded field with a magnifier and a clear button; filters as you type |
| Grouped list | Rows on a rounded card, with a small heading above and a note below |
| List row | A leading badge or icon, a title and an optional subtitle, and one trailing accessory: check mark, chevron, switch or value |
| Scroll area | Its content scrolls by rows with the standard wheel bands |

- **Later:** segmented control, stepper, chips, action sheet; swipe actions become a row's actions on hover.
- A list keeps its order while it is visible (the refresh rule); checking a row never moves it.
- The first users are Kuroko's own dialogs, starting with the language dialog, built with the SDK like any other app.

- **Virtual lists:** the library asks the app only for the rows in view (a callback in Mode A, a "list rows" request in Mode B). The process window and file manager need this for thousands of entries.

### Human-factors rules built into the library (follows agreed)

- **Every action is acknowledged within 0.1 s** by the library itself, without waiting for the app. If the app hasn't answered an event after about 1 s, the widget shows a working state; past 5 s, a not-responding state with cancel.
- **Mode A apps never block the UI:** handlers return quickly, and long work runs on a worker with progress reported to the library.
- **Theme roles only.** Light and dark, reduce transparency and reduce motion are applied by the library.
- **Animations** are timed by the clock, 150–250 ms, ease-out, interruptible. Nothing flashes more than 3 times per second (WCAG 2.3.1); the library enforces it.
- **No state by color alone:** error, selected, disabled and warning states have built-in shapes or icons.
- **Text:** shaping, bidi (UAX #9), Hebrew and English, and alignment by the first strong character, as in the compositor's menus.
- **Sorted lists follow the refresh rule:** order frozen at the click, values update in place, idle-based re-sort, "N new" chip, no rendering while suspended.

## Integration with Kuroko

- **Chrome:** framework windows draw no title bar; the compositor draws it (server-side decorations).
- **Menus** are exported so the compositor shows them in the title bar and in the summoned surface's menu search.
- **Status:** progress, working and error reach the window's bottom border through the Kuroko protocol.
- **Optimal size:** the library reports the content region and reading width (in characters) to the compositor, which feeds optimal size and attention tiling.
- **Scene graph:** the library publishes its widget tree (roles, names, bounds, state). This is the "own apps via a custom protocol" source in the design concept: the richest structure, without AT-SPI.
- **Privacy:** password fields are marked, and the recorder never records them. Text field contents are not published. The per-app blacklist applies to framework apps too.
- (suggestion) A screen-reader (AT-SPI) bridge is out of scope for now; the tree is designed so one can be added later.

## Data service [desktop] (agreed)

A Kuroko service that gives every app the same shared data: reference lists, dictionaries, calendar, system and device information. Widgets can bind to it directly, so a dropdown of countries or drives needs no app code.

### Binding

- **System source** is one of the fixed source kinds for dropdowns, combo boxes, lists and the fill helper (see Look and Controls): a named source such as `countries`, `timezones`, `dictionary:he`, `drives`, `printers`.
- With a system source, the library talks to the service itself. The service is local, so the rule "the library makes no network calls" still holds.
- **Live sources send change events** (a drive plugged in). An open dropdown stays frozen while visible; the update shows the next time it opens.
- **Large sources are queried, not sent whole:** by prefix or by visible range, with limits.

### Contents

A facade over standard backends, not a reimplementation:

| Group | Examples | Backend |
| --- | --- | --- |
| Reference data | Countries, languages, currencies, time zones, units, with Hebrew and English names | Unicode CLDR |
| Dictionaries | Word lists per language | Hunspell dictionaries |
| Calendar | Holidays, Shabbat times, Hebrew dates | Temporal layer |
| System | CPU, memory, load | System-state sampler |
| Storage | Drives, mounts, free space | UDisks2 |
| Devices | Printers, audio devices, displays, Bluetooth | CUPS, PipeWire, compositor, BlueZ |
| Fonts | Installed fonts | fontconfig |
| Apps | Installed applications | Desktop entries |

### Access

- **Reference data** (countries, dictionaries, calendar): open to every app.
- **System and device data** (drives, printers, installed apps): open to Kuroko's own apps; third-party apps need a permission, granted through the portal mechanism, since this data can fingerprint the machine.
- **Personal data** (recent files, history, working sets, salience) is never offered to third-party apps through this service.

### Protocol and SDK

- **The Kuroko protocol** over a Unix socket in `$XDG_RUNTIME_DIR`, with the usual record format, validation and limits. No HTTP and no TCP port: a local port is reachable by any process and by web pages through DNS rebinding.
- **An SDK** per language for quick, easy use of the service: generated bindings plus convenience calls (list a source, query by prefix, subscribe to changes). First languages follow the framework bindings: Zig, C, then Go and Python.

## Security and trust (follows agreed)

- Sockets in `$XDG_RUNTIME_DIR`, mode 0700, peers checked with `SO_PEERCRED`.
- **Third-party apps get normal windows only.** Overlays, panels, top-bar slots, click capture and highlight overlays are only for Kuroko's own processes, over the compositor's Kuroko protocol.
- Using the framework grants no extra compositor permissions.
- Hosts parse untrusted input: limits on everything, fuzz tests for every decoder, `ReleaseSafe` builds.
- Running as root follows the Top-Level rules; a UI host runs as the same user as its app.

## Performance (suggestion)

- **Mode A:** no IPC on the hot path; the app renders its own window.
- **Mode B:** one message per user event or data change, never per frame.
- **Rendering:** on the CPU into shared-memory buffers by default (no GPU assumed); GPU buffers (dmabuf) when available. Damage tracking redraws only what changed.
- **Memory:** manual allocation in Zig, per-frame arenas, registry handles and guards. This replaces the draft's "zero GC, near-zero RAM" claim with rules that can be checked.
- **Measured** with the same histograms as the compositor: input-to-present latency and frame time, per app.

## Rules for AI code generation

1. Read the Top-Level Design first, especially the binary format, the object registry and the refresh rule.
2. Target the pinned Zig version, using the repo's notes on current std APIs. Build `ReleaseSafe`.
3. No app-specific logic in the library or the host.
4. Mode A and Mode B use the same structures, generated from one schema.
5. Store handles, use guards with `defer`; never store a raw pointer past the current event.
6. The host never waits on an app. Client death is detected from the socket closing.
7. Validate and limit every input from an app; every decoder has a fuzz test.
8. Theme roles only, never hard-coded colors. No state by color alone. No flash over 3 per second.
9. Acknowledge input within 0.1 s; time animations by the clock.
10. Every string is bidi-correct.
11. Third-party apps get no compositor powers.
12. Keep logic in pure Zig that builds and tests on macOS; keep the Wayland layer thin.
13. Customization is parameters, controller commands and events, and fixed policies. No app code runs inside an interaction, and events never veto.

## Development order (suggestion)

1. **On the Mac:** widget tree, layout and message structures in pure Zig, with unit tests; draw the output in the debug viewer.
2. **In the VM:** render into Wayland buffers. One window with labels, buttons and text.
3. **First real app in Mode A:** trash or the process window.
4. **C ABI, then the Mode B host,** with Go and Python bindings and a small sample app.
5. **Integration:** virtual lists, menu export, status border, content width and scene-graph publishing.

## Open questions

- [ ] Name of the framework.
- [ ] One UI host per app (suggested) or one shared host?
- [ ] Mode A threading: render on a separate thread from app logic, or one thread with strict non-blocking handlers?
- [ ] 2D rendering: own rasterizer, or an existing library (pixman, Cairo, a pure-Zig 2D library)?
- [ ] Text stack: HarfBuzz + FreeType + a bidi library, or pure Zig?
- [ ] Text layout format for authoring: needed at all, and which syntax?
- [ ] How the compositor decides that a process is "Kuroko's own".
- [ ] What third-party apps may publish to the scene graph, and how the user controls it.
- [ ] Packaging and sandboxing of third-party Kuroko apps (for example Flatpak with portals).
- [ ] Which parameters an app may set, and which only the user may set (per parameter, in the schema).
- [ ] Data service: its name, the naming scheme for sources, and which sources ship first.
