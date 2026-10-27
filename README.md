# Tesselix

An AI-aware Linux desktop: a Wayland compositor, desktop services and a widget
library, written in Zig. The name comes from tessellation: windows tile the
screen with no gaps and no overlaps.

The design is in [`docs/`](docs/README.md). Start with the Top-Level Design.

## Layout

| Folder | What it is |
| --- | --- |
| `txcore/` | Shared by everything: binary format and repair ladder, object registry (handles, guards), geometry, input events, theme roles, animation, wheel bands, timing histograms, IPC helpers |
| `txwidgets/` | Widget library (Mode A): canvas rasterizer, fonts, widget tree and layout, buttons, toggles, checkboxes, progress, text fields, the document view with the scrolling behavior |
| `txcomp/` | Compositor core: window model, attention tiling, chrome, top bar, launcher, shelf, event publisher. Backend-independent |
| `txwl/` | Tesselix as a Wayland server: the wire format, the core and xdg-shell protocols in pure Zig. Apps' windows become compositor windows like Tesselix's own |
| `txgl/` | The GPU renderer: draws the compositor's recorded frames with OpenGL ES 3.0 (OpenGL 3.3 on the Mac). Shared by every backend |
| `txdesk/` | Desktop services. Now: a stub context hub that prints the scene graph as text |
| `txdk/` | SDK for other languages (C ABI, Mode B UI host, bindings). Not started |
| `apps/controls/` | The controls app: every widget's behavior in one place, growing with the library |
| `tools/txsim/` | Simulator backend: runs the compositor in one SDL3 window on macOS |
| `tools/fontgen/` | Generates the font atlases (stopgap until the text stack is chosen) |

## Running on the Mac

The compositor core, desktop and widgets run on macOS through the simulator.
Only the Linux backend (DRM/KMS) needs the VM.

1. Install SDL3 and pkg-config: `brew install sdl3 pkg-config`
2. Install **Zig 0.16.0** (pinned, see `build.zig.zon`): `brew install zig`,
   then check with `zig version`. Before production the project moves to
   Zig 0.17; `docs/zig-notes.md` lists what that involves.
3. In this folder:

```sh
zig build test          # all unit tests
zig build run           # the simulator: a clean desktop, nothing started; the apps are in the launcher
zig build run -- --panel   # Controls, Scroll Lab and Notes wait in the panel
zig build run -- --tiled   # all five apps open on the desktop
zig build run -- --dark    # dark theme
zig build run -- --cpu     # draw on the CPU instead of the GPU (also TX_GPU=off)
zig build run-desk      # in a second terminal: the desktop service prints the scene
```

The build defaults to `ReleaseSafe` (how Tesselix ships). For debugging, add
`-Doptimize=Debug`. On exit, the simulator prints frame-time and
input-to-present histograms.

### Keys in the simulator

| Keys | Action |
| --- | --- |
| Cmd alone (press and release) | Launcher (Cmd is Super) |
| Cmd+X / Cmd+Z | Close / minimize the focused window |
| Cmd+Enter | Maximize, or restore when maximized |
| Cmd+F | Full screen (its own space), or back |
| "+" on a running app's launcher tile, or Shift+click / Shift+Enter | A new window of an app that is already running |
| Cmd+← / Cmd+→ | Slide between the desktop and full-screen spaces |
| Fn+← / Fn+→ | Home / End |
| Option+← | Back after a jump (document view) |
| Shift + wheel | Run (fast band) |

macOS uses Ctrl+←/→ to switch Spaces. To test word jumps in text fields, turn
those shortcuts off in System Settings → Keyboard → Keyboard Shortcuts →
Mission Control.

## Running from VS Code

Open `tesselix.code-workspace` (File → Open Workspace from File). VS Code
offers the two recommended extensions: Zig Language (`ziglang.vscode-zig`) and
CodeLLDB (`vadimcn.vscode-lldb`, needed for Run and Debug).

- **Run and Debug** (Cmd+Shift+D): pick a configuration, then F5 to debug or
  Ctrl+F5 to run without the debugger. Each builds first.
  - *Tesselix*, *Tesselix (dark)*, *Tesselix (apps in the panel)*
  - *Tesselix (script)*: plays a scripted session you pick, then stays open
  - *Tesselix (Debug build)*: a Debug build in `zig-out/debug`, for stepping
    through code
  - *Tesselix + desktop service*: the simulator and `txdesk` together
- **Tasks** (Terminal → Run Task…): Build (Cmd+Shift+B), Build (Debug), Test,
  and the same run variants without a debugger. Compile errors appear in the
  Problems panel.

## Running on the Ubuntu ARM VM

The VM (Ubuntu Server 26.04 ARM, 3D acceleration) shares `ubuntu-share/`
with the Mac. Tesselix runs there full screen from the bare console: the
simulator runs inside `cage`, a minimal Wayland kiosk. SDL3's own KMS/DRM
driver cannot be used in UTM (it shows ARGB8888 frames; the virtio-gpu
screen plane takes only XRGB8888), so `run.sh` uses cage until Tesselix has
its own Linux backend.

On the Mac, in this folder:

```sh
make ubuntu                  # builds aarch64-linux into ubuntu-share/tesselix
make ubuntu OPTIMIZE=Debug   # a Debug build
make vm                      # prints the commands for the VM
```

(`make ubuntu` runs `tools/ubuntu/build.sh`; the root `Makefile` is a copy of
`tools/ubuntu/Makefile.in`: `cp tools/ubuntu/Makefile.in Makefile` once.) On the VM the share is mounted
read-only at `/mnt/shared` (`make ubuntu VM_SHARE=...` if it is elsewhere):

```sh
sh /mnt/shared/tesselix/check.sh   # is the VM ready? (changes nothing)
sh /mnt/shared/tesselix/setup.sh   # once: libSDL3, Mesa, kmscube, video/render/input groups
sh /mnt/shared/tesselix/run.sh     # the compositor, desktop and apps, full screen
sh /mnt/shared/tesselix/run.sh --dark --tiled   # txsim options pass through (--panel, --tiled, --dark)
```

A third-party app for comparison, Google Chrome, runs the same way (in cage, full
screen; Tesselix cannot host outside apps until it is a Wayland server):

```sh
sh /mnt/shared/tesselix/browser.sh --install   # once, from Google's apt repository (arm64)
sh /mnt/shared/tesselix/browser.sh             # quit with Ctrl+Shift+Q; joins a running Tesselix
TX_GPU=off sh /mnt/shared/tesselix/browser.sh  # CPU drawing, if the screen stays blank
```

`run.sh` also starts the desktop service in the background. It scans for
installed graphical apps (Chrome, Alacritty, ...) and the launcher lists
them after the built-in apps. They open in Tesselix's tiles: Tesselix is
their Wayland server (`wayland-tesselix-0` in the runtime directory), so
the compositor gives each window its size and place. Any Wayland app can
be pointed at it by hand: `WAYLAND_DISPLAY=wayland-tesselix-0 app`. By hand:
`~/.cache/tesselix/bin/txdesk apps list` (or `apps scan --verbose`).
Trust: any installed app is trusted; other apps, files and folders are
marked by hand with `txdesk trust app|file|folder <path> trusted|untrusted|clear`
(`txdesk trust list`, `txdesk trust check <path>`). The desktop service's
log shows each window's app, PID, signature and trust.
The desktop service's log is `~/.cache/tesselix/txdesk.log`; the
simulator's is `txsim.log`. Start `run.sh`
from the VM's console, logged in as yourself: cage needs the console's seat.
To quit, run `pkill txsim` over SSH (it prints a timing summary to the log); `pkill -9 txsim` if it hangs.

If the shared folder shows the Mac's owner (uid 501, group 20) and you cannot
read it, copy it to your home folder first and run from there:
`sudo cp -r /mnt/shared/tesselix ~/tesselix && sudo chown -R $USER: ~/tesselix`.

Cross-compiling needs no SDL3 for the target on the Mac: the build links
against a stub with the same names (`tools/txsim/src/sdl_stub.zig`), and the
VM's own `libSDL3.so.0` is used at run time.

## Linux (later)

Tesselix's own Linux backend (no wlroots; see the Top-Level Design,
"Foundation") drives the screen with libdrm/GBM/EGL and input with
libinput and libseat, and draws with the same GPU renderer (`txgl`). It
runs in a Linux VM (UTM on the Mac); see the Top-Level Design,
"Development environment".
