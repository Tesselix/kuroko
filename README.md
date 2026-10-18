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
| `txdesk/` | Desktop services. Now: a stub context hub that prints the scene graph as text |
| `txdk/` | SDK for other languages (C ABI, Mode B UI host, bindings). Not started |
| `apps/controls/` | The controls app: every widget's behavior in one place, growing with the library |
| `tools/txsim/` | Simulator backend: runs the compositor in one SDL3 window on macOS |
| `tools/fontgen/` | Generates the font atlases (stopgap until the text stack is chosen) |

## Running on the Mac

The compositor core, desktop and widgets run on macOS through the simulator.
Only the Linux backend (wlroots) needs the VM.

1. Install SDL3 and pkg-config: `brew install sdl3 pkg-config`
2. Install **Zig 0.16.0** (pinned, see `build.zig.zon`): `brew install zig`,
   then check with `zig version`. Before production the project moves to
   Zig 0.17; `docs/zig-notes.md` lists what that involves.
3. In this folder:

```sh
zig build test          # all unit tests
zig build run           # the simulator: compositor + desktop + Controls and Scroll Lab
zig build run -- --empty --dark
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
  - *Tesselix*, *Tesselix (dark)*, *Tesselix (empty desktop)*
  - *Tesselix (script)*: plays a scripted session you pick, then stays open
  - *Tesselix (Debug build)*: a Debug build in `zig-out/debug`, for stepping
    through code
  - *Tesselix + desktop service*: the simulator and `txdesk` together
- **Tasks** (Terminal → Run Task…): Build (Cmd+Shift+B), Build (Debug), Test,
  and the same run variants without a debugger. Compile errors appear in the
  Problems panel.

## Running on the Ubuntu ARM VM

The VM (Ubuntu Server 26.04 ARM, 3D acceleration) shares `ubuntu-share/`
with the Mac. Tesselix runs there full screen on the bare console: the
simulator draws through SDL3's KMS/DRM driver, so no X or Wayland is needed.

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
sh /mnt/shared/tesselix/run.sh --dark --empty   # txsim options pass through
```

`run.sh` also starts the desktop service in the background (its log is
`~/.cache/tesselix/txdesk.log`). Ctrl+C in the terminal quits. Running it
over SSH works too; the picture appears on the VM's screen.

Cross-compiling needs no SDL3 for the target on the Mac: the build links
against a stub with the same names (`tools/txsim/src/sdl_stub.zig`), and the
VM's own `libSDL3.so.0` is used at run time.

## Linux (later)

The compositor's Linux backend uses wlroots. The `zig-wlroots` bindings
currently target Zig 0.15 and wlroots 0.20, so when the backend is built they
either support our Zig version or Tesselix keeps a thin binding of its own. It runs in a Linux VM (UTM on the
Mac); see the Top-Level Design, "Development environment".
