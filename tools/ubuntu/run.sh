#!/bin/sh
# Runs Tesselix full screen on the VM's own screen: the compositor with the
# desktop and the apps (txsim, SDL3 on KMS/DRM), and the desktop service
# (txdesk) in the background. Run it from the VM's console or over SSH;
# the picture appears on the VM's screen.
#
#   sh run.sh                 normal start
#   sh run.sh --dark          any txsim options pass through (--empty, --script NAME)
#
# Quit: Ctrl+C in this terminal (or close the session).
set -e
here=$(cd "$(dirname "$0")" && pwd)

# Run from a local copy: shared folders may drop the exec bit and are slow.
bin="$HOME/.cache/tesselix/bin"
mkdir -p "$bin"
install -m 755 "$here/bin/txsim" "$here/bin/txdesk" "$bin/"

if ! ldconfig -p | grep -q 'libSDL3.so.0'; then
    echo "libSDL3 is missing: run  sh $here/setup.sh  first." >&2
    exit 1
fi

# The console has no window system: SDL3 draws straight to the screen.
export SDL_VIDEODRIVER=kmsdrm
# Keep Tesselix's own sockets in the user's runtime dir.
if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "/run/user/$(id -u)" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

"$bin/txdesk" >"$HOME/.cache/tesselix/txdesk.log" 2>&1 &
desk=$!
trap 'kill $desk 2>/dev/null' EXIT INT TERM

"$bin/txsim" --fullscreen "$@"
