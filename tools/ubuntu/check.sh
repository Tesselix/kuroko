#!/bin/sh
# Checks the Ubuntu ARM VM before running Kuroko: CPU, display device and
# 3D acceleration, permissions, libraries, and anything that would hold the
# screen. Changes nothing. Run it on the VM:
#
#   sh /mnt/shared/kuroko/check.sh
here=$(cd "$(dirname "$0")" && pwd)
fail=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
in_group() { id -nG | tr ' ' '\n' | grep -qx "$1"; }

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo, as the user who runs Kuroko: group and"
    echo "session checks below are for root, not for you."
    echo
fi
echo "System"
arch=$(uname -m)
[ "$arch" = aarch64 ] && ok "CPU aarch64" || bad "CPU is $arch; this build is for aarch64"
glibc=$(ldd --version 2>/dev/null | head -n1 | grep -o '[0-9]*\.[0-9]*$')
ok "glibc $glibc (needs 2.28 or newer)"
fs=$(findmnt -no FSTYPE -T "$here" 2>/dev/null)
ok "shared folder: $here ($fs)"
if [ -f "$here/bin/krksdl" ] && [ -f "$here/bin/krkdesk" ]; then
    ok "binaries present"
else
    bad "no bin/krksdl or bin/krkdesk in $here: run  make ubuntu  on the Mac"
fi

echo "Display (KMS/DRM)"
card=""
for c in /dev/dri/card*; do [ -e "$c" ] && card=$c && break; done
if [ -z "$card" ]; then
    bad "no /dev/dri/card*: in UTM set Display to virtio-gpu-gl-pci (GPU Supported)"
else
    if [ -d /sys/module/virtio_gpu ]; then
        ok "$card (virtio_gpu loaded)"
    else
        warn "$card, but virtio_gpu is not loaded: in UTM use virtio-gpu-gl-pci"
    fi
    [ -r "$card" ] && [ -w "$card" ] && ok "$card readable and writable" \
        || bad "no access to $card: join the video group (setup.sh), log in again"
fi
ls /dev/dri/renderD* >/dev/null 2>&1 && ok "render node $(ls /dev/dri/renderD* | head -n1)" \
    || bad "no /dev/dri/renderD*: no 3D device"
feat=$( (journalctl -k -b 2>/dev/null; dmesg 2>/dev/null) | grep -o '[+-]virgl' | head -n1)
case "$feat" in
    +virgl) ok "3D acceleration: virgl on" ;;
    -virgl) bad "virgl is off: in UTM enable GPU acceleration (virtio-gpu-gl-pci)" ;;
    *) warn "virgl not found in the kernel log; run kmscube to test 3D (after setup.sh)" ;;
esac
modes=$(cat /sys/class/drm/card*-*/modes 2>/dev/null | head -n1)
[ -n "$modes" ] && ok "screen mode $modes"

echo "Input"
ls /dev/input/event* >/dev/null 2>&1 || bad "no /dev/input/event*"
in_group input && ok "in group input" || bad "not in group input (setup.sh, then log in again)"
for g in video render; do
    in_group "$g" && ok "in group $g" || bad "not in group $g (setup.sh, then log in again)"
done

echo "Libraries"
for l in libSDL3.so.0 libgbm.so.1 libEGL.so.1 libEGL_mesa.so.0 libGLESv2.so.2; do
    p=$(ldconfig -p 2>/dev/null | grep -m1 "$l " | sed 's/.*=> //')
    if [ -n "$p" ]; then ok "$l -> $(readlink -f "$p")"; else bad "$l missing: run setup.sh"; fi
done
dri=$(ls /usr/lib/aarch64-linux-gnu/dri/virtio_gpu_dri.so /usr/lib/aarch64-linux-gnu/dri/*virtio* 2>/dev/null | head -n1)
[ -n "$dri" ] && ok "Mesa virgl driver $dri" || warn "no Mesa virtio driver found (libgl1-mesa-dri / mesa-libgallium)"
if [ -f "$here/bin/krksdl" ]; then
    nf=$(ldd "$here/bin/krksdl" 2>/dev/null | grep 'not found')
    [ -z "$nf" ] && ok "krksdl resolves all its libraries" || bad "krksdl: $nf"
fi

command -v cage >/dev/null && ok "cage $(cage -v 2>&1 | head -n1)" || bad "cage missing: run setup.sh"
case "$WLR_RENDERER" in
    ""|gles2) ;;
    *) warn "WLR_RENDERER=$WLR_RENDERER in your environment (run.sh uses gles2 anyway)" ;;
esac

echo "Session"
holder=$(pgrep -l -x 'Xorg|Xwayland|gnome-shell|kwin_wayland|weston|sway|mutter|cage' 2>/dev/null)
[ -z "$holder" ] && ok "nothing else holds the screen" || bad "another display server is running: $holder"
pgrep -x krksdl >/dev/null && bad "krksdl is already running"
[ -n "$XDG_RUNTIME_DIR" ] || [ -d "/run/user/$(id -u)" ] && ok "runtime dir /run/user/$(id -u)" \
    || warn "no XDG_RUNTIME_DIR; Kuroko sockets need one (log in on the console or over SSH)"
if [ -n "$SSH_CONNECTION" ]; then
    warn "over SSH: start run.sh from the VM's console instead (cage needs the console's seat)"
fi

echo
if [ $fail -eq 0 ]; then
    echo "Ready. Optional GL test on the console: kmscube (Ctrl+C to stop)."
    echo "Run:  sh $here/run.sh"
else
    echo "Fix the FAIL lines first."
fi
exit $fail
