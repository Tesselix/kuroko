#!/bin/sh
# Runs Kuroko full screen on the VM's own screen: the compositor with the
# desktop and the apps (txsim, the simulator), and the desktop service
# (txdesk) in the background.
#
#   sh run.sh                 normal start (from the VM's console)
#   sh run.sh --dark          any txsim options pass through (--panel, --tiled, --script NAME)
#   TX_DEBUG=1 sh run.sh      SDL3 logs every step (video, render, input)
#   TX_DISPLAY=kms sh run.sh  SDL3 straight on KMS/DRM, without cage (see below)
#   TX_MODE=2560x1600 sh run.sh   screen size, default 1920x1200 (one of the
#                             lines in /sys/class/drm/card0-Virtual-1/modes);
#                             TX_MODE= (empty) keeps the VM's own 1280x800
#
# How it reaches the screen: txsim runs inside cage, a minimal Wayland
# kiosk (wlroots) that shows one app full screen. SDL3's own KMS/DRM driver
# cannot be used on UTM: it puts ARGB8888 frames on the screen, and the
# virtio-gpu primary plane accepts only XRGB8888 (`kmscube -f AR24` fails
# the same way), so the screen stays blank. This lasts until Kuroko has
# its own Linux backend.
#
# Run it from the VM's console (cage needs the console's seat).
# Quit: from SSH,  pkill txsim   (prints the timing summary; cage exits with it).
#       pkill -9 txsim if it ever hangs.
# Logs: ~/.cache/kuroko/txsim.log (txsim and cage), txdesk.log.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cache="$HOME/.cache/kuroko"

# Run from a local copy: shared folders may drop the exec bit and are slow.
bin="$cache/bin"
mkdir -p "$bin"
install -m 755 "$here/bin/txsim" "$here/bin/txdesk" "$bin/"

if ! ldconfig -p | grep -q 'libSDL3.so.0'; then
    echo "libSDL3 is missing: run  sh $here/setup.sh  first." >&2
    exit 1
fi

display=${TX_DISPLAY:-cage}
case "$display" in
    cage)
        if ! command -v cage >/dev/null; then
            echo "cage is missing: run  sh $here/setup.sh  first." >&2
            exit 1
        fi
        # Screen size inside cage; unset means the default, empty means
        # leave the VM's preferred mode (1280x800).
        TX_MODE="${TX_MODE-1920x1200}"
        if [ -n "$TX_MODE" ] && ! command -v wlr-randr >/dev/null; then
            echo "wlr-randr is missing, so the screen stays at the VM's size: sudo apt install wlr-randr" >&2
            TX_MODE=""
        fi
        export SDL_VIDEODRIVER=wayland
        # wlroots draws with OpenGL ES (virgl). Its Vulkan renderer finds only
        # llvmpipe (CPU) in this VM and fails, so ignore a WLR_RENDERER=vulkan
        # from the environment unless TX_WLR_RENDERER says otherwise.
        export WLR_RENDERER="${TX_WLR_RENDERER:-gles2}"
        # Draw the pointer into the frame, not on the cursor plane: on virgl
        # the cursor-plane image comes out upside down while its hotspot
        # stays at the top, so clicks land above the visible tip.
        export WLR_NO_HARDWARE_CURSORS=1
        # No client-side title bar (libdecor) for SDL's window: cage shows one
        # full-screen window and needs none, and with it the pointer arrives
        # offset by the frame's height (clicks land ~50 px above the tip).
        export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR="${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-0}"
        ;;
    kms)
        export SDL_VIDEODRIVER=kmsdrm
        ;;
    *)
        echo "TX_DISPLAY must be cage or kms, not $display" >&2
        exit 1
        ;;
esac
# Renderer: OpenGL ES, else software. SDL's desktop OpenGL renderer needs
# GLSL 1.30, but virgl in UTM offers desktop GL only up to GLSL 1.20 (and
# GLSL ES 3.00). Override by setting SDL_RENDER_DRIVER yourself.
export SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-opengles2,software}"
# A Wayland session: apps that pick their display protocol at run time
# read this (Chrome and Electron fall back to X11 without it, and there is
# no X server here).
export XDG_SESSION_TYPE=wayland
# Keep Kuroko's own sockets in the user's runtime dir.
if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "/run/user/$(id -u)" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
if [ -n "$TX_DEBUG" ]; then
    export SDL_LOGGING='*=verbose'
fi

"$bin/txdesk" >"$cache/txdesk.log" 2>&1 &
desk=$!
trap 'kill $desk 2>/dev/null' EXIT INT TERM

log="$cache/txsim.log"
{
    echo "== $(date '+%F %T')  display=$display  mode=${TX_MODE:-default}  tty=$(tty)  ssh=${SSH_CONNECTION:+yes}  renderer=$SDL_RENDER_DRIVER  args: $*"
    echo "   SDL3: $(readlink -f "$(ldconfig -p | grep -m1 'libSDL3.so.0 ' | sed 's/.*=> //')")"
} >"$log"
if [ -n "$SSH_CONNECTION" ] && [ "$display" = cage ]; then
    echo "Note: over SSH cage may not get the screen; run this from the VM's console." | tee -a "$log"
fi
status=0
if [ "$display" = cage ]; then
    # Inside cage: set the screen size first (wlr-randr), then start txsim.
    export TX_MODE
    cage -- sh -c '
        if [ -n "$TX_MODE" ]; then
            out=$(wlr-randr | head -n1 | cut -d" " -f1)
            wlr-randr --output "$out" --mode "$TX_MODE" \
                && echo "screen: $out at $TX_MODE" \
                || echo "screen: could not set $TX_MODE on $out (see the modes in /sys/class/drm/card0-*/modes)"
        fi
        exec "$0" --fullscreen "$@"' "$bin/txsim" "$@" >>"$log" 2>&1 || status=$?
else
    "$bin/txsim" --fullscreen "$@" >>"$log" 2>&1 || status=$?
fi
echo "== txsim exited with status $status" >>"$log"
grep -v '^00:00:' "$log" | tail -n 40
exit $status
