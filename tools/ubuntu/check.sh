#!/bin/sh
# Checks the Ubuntu ARM VM before running Tesselix: CPU, display device and
# 3D acceleration, permissions, libraries, and anything that would hold the
# screen. Changes nothing. Run it on the VM:
#
#   sh /mnt/shared/tesselix/check.sh
here=$(cd "$(dirname "$0")" && pwd)
fail=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
in_group() { id -nG | tr ' ' '\n' | grep -qx "$1"; }

echo "System"
arch=$(uname -m)
[ "$arch" = aarch64 ] && ok "CPU aarch64" || bad "CPU is $arch; this build is for aarch64"
glibc=$(ldd --version 2>/dev/null | head -n1 | grep -o '[0-9]*\.[0-9]*$')
ok "glibc $glibc (needs 2.28 or newer)"
fs=$(findmnt -no FSTYPE -T "$here" 2>/dev/null)
ok "shared folder: $here ($fs)"
if [ -f "$here/bin/txsim" ] && [ -f "$here/bin/txdesk" ]; then
    ok "binaries present"
else
    bad "no bin/txsim or bin/txdesk in $here: run  make ubuntu  on the Mac"
fi

echo "Display (KMS/DRM)"
card=""
for c in /dev/dri/card*; do [ -e "$c" ] && card=$c && break; done
if [ -z "$card" ]; then
    bad "no /dev/dri/card*: in UTM set Display to virtio-gpu-gl-pci (GPU Supported)"
else
    drv=$(basename "$(readlink -f "/sys/class/drm/$(basename "$card")/device/driver")" 2>/dev/null)
    ok "$card (driver $drv)"
    [ "$drv" = virtio_gpu ] || warn "expected virtio_gpu in UTM"
    [ -r "$card" ] && [ -w "$card" ] && ok "$card readable and writable" \
        || bad "no access to $card: join the video group (setup.sh), log in again"
fi
ls /dev/dri/renderD* >/dev/null 2>&1 && ok "render node $(ls /dev/dri/renderD* | head -n1)" \
    || bad "no /dev/dri/renderD*: no 3D device"
feat=$(journalctl -k -b 2>/dev/null | grep -o 'features: .*' | head -n1)
[ -z "$feat" ] && feat=$(dmesg 2>/dev/null | grep -o 'features: .*' | head -n1)
case "$feat" in
    *+virgl*) ok "3D acceleration: virgl on" ;;
    *-virgl*) bad "virgl is off: in UTM enable GPU acceleration (virtio-gpu-gl-pci)" ;;
    *) warn "could not read the kernel log; check:  sudo dmesg | grep -i virgl" ;;
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
if [ -f "$here/bin/txsim" ]; then
    nf=$(ldd "$here/bin/txsim" 2>/dev/null | grep 'not found')
    [ -z "$nf" ] && ok "txsim resolves all its libraries" || bad "txsim: $nf"
fi

echo "Session"
holder=$(pgrep -l -x 'Xorg|Xwayland|gnome-shell|kwin_wayland|weston|sway|mutter|cage' 2>/dev/null)
[ -z "$holder" ] && ok "nothing else holds the screen" || bad "another display server is running: $holder"
pgrep -x txsim >/dev/null && bad "txsim is already running"
[ -n "$XDG_RUNTIME_DIR" ] || [ -d "/run/user/$(id -u)" ] && ok "runtime dir /run/user/$(id -u)" \
    || warn "no XDG_RUNTIME_DIR; Tesselix sockets need one (log in on the console or over SSH)"
if [ -n "$SSH_CONNECTION" ]; then
    warn "over SSH: the picture shows on the VM's screen, and keys typed there also reach its console login"
fi

echo
if [ $fail -eq 0 ]; then
    echo "Ready. Optional GL test on the console: kmscube (Ctrl+C to stop)."
    echo "Run:  sh $here/run.sh"
else
    echo "Fix the FAIL lines first."
fi
exit $fail
