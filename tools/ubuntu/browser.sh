#!/bin/sh
# Runs a third-party app, Google Chrome, on the VM's screen the same way
# run.sh runs Kuroko: inside cage, as a Wayland client. It checks that the
# VM can run a heavy GPU app before Kuroko hosts such apps itself (krksdl is
# not a Wayland server yet, so Chrome cannot open inside Kuroko).
#
#   sh browser.sh --install   once: Chrome from Google's apt repository
#                             (arm64 builds; apt, never snap). Updates come
#                             with  sudo apt upgrade
#   sh browser.sh             Chrome full screen; any options pass through.
#                             With Kuroko running (run.sh), it joins that
#                             cage and shows over Kuroko (works over SSH)
#   sh browser.sh https://example.org
#
#   KRK_GPU=off sh browser.sh  draw on the CPU, if the GPU path shows nothing
#   KRK_MODE=2560x1600 sh browser.sh   screen size, as in run.sh
#
# Run it from the VM's console (cage needs the console's seat).
# Seen on UTM (virgl) with Chrome 156: EGL refuses an ES 3.0 context, so
# the GPU process exits and Chrome draws on the CPU; pages still render.
#
# Quit: Ctrl+Shift+Q, or from SSH  pkill -f 'opt/google/chrom[e]/chrome'
#       (cage exits with it when browser.sh started cage).
# Log: ~/.cache/kuroko/browser.log
set -e
cache="$HOME/.cache/kuroko"
mkdir -p "$cache"

if [ "$1" = --install ]; then
    # Google's signing key and repository (the same files the .deb's own
    # cron job writes), then the package.
    keyring=/etc/apt/keyrings/google-chrome.gpg
    sudo install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor | sudo tee "$keyring" >/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y google-chrome-stable
    echo
    echo "Done. Run:  sh $0"
    exit 0
fi

browser=google-chrome-stable
if ! command -v "$browser" >/dev/null; then
    echo "Chrome is missing: run  sh $0 --install  first." >&2
    exit 1
fi
if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "/run/user/$(id -u)" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
# Wayland directly (no XWayland), and no first-run dialogs.
set -- --ozone-platform=wayland --no-first-run --no-default-browser-check "$@"
if [ "$KRK_GPU" = off ]; then
    set -- --disable-gpu "$@"
fi
log="$cache/browser.log"

# Kuroko already on screen (run.sh): join its cage. Chrome shows full
# screen over Kuroko, and closing it brings Kuroko back. Works over SSH.
if pgrep -x cage >/dev/null && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
    echo "== $(date '+%F %T')  joining the running cage  args: $*" >"$log"
    WAYLAND_DISPLAY=wayland-0 nohup "$browser" "$@" >>"$log" 2>&1 &
    echo "Chrome started on the running cage (log: $log)."
    exit 0
fi

if ! command -v cage >/dev/null; then
    echo "cage is missing: run  sh $(dirname "$0")/setup.sh  first." >&2
    exit 1
fi

# The same cage settings as run.sh (see the reasons there).
export WLR_RENDERER="${KRK_WLR_RENDERER:-gles2}"
export WLR_NO_HARDWARE_CURSORS=1
KRK_MODE="${KRK_MODE-2560x1440}"
if [ -n "$KRK_MODE" ] && ! command -v wlr-randr >/dev/null; then
    echo "wlr-randr is missing, so the screen stays at the VM's size: sudo apt install wlr-randr" >&2
    KRK_MODE=""
fi
export KRK_MODE

echo "== $(date '+%F %T')  mode=${KRK_MODE:-default}  gpu=${KRK_GPU:-on}  args: $*" >"$log"
status=0
cage -- sh -c '
    if [ -n "$KRK_MODE" ]; then
        out=$(wlr-randr | head -n1 | cut -d" " -f1)
        if wlr-randr --output "$out" --mode "$KRK_MODE" 2>/dev/null; then
            echo "screen: $out at $KRK_MODE"
        elif wlr-randr --output "$out" --custom-mode "$KRK_MODE"; then
            echo "screen: $out at $KRK_MODE (custom mode)"
        else
            echo "screen: could not set $KRK_MODE on $out"
        fi
    fi
    exec "$0" "$@"' "$browser" "$@" >>"$log" 2>&1 || status=$?
echo "== $browser exited with status $status" >>"$log"
tail -n 20 "$log"
exit $status
