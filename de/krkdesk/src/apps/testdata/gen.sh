#!/bin/sh
# Builds the ELF fixtures for elf.zig: tiny aarch64-linux binaries that link
# stub display libraries (same sonames, no code) and call or carry what the
# inspector looks for. Run from anywhere; needs only zig.
#
#   sh de/krkdesk/src/apps/testdata/gen.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
cc() { zig cc -target aarch64-linux-gnu -Os -s "$@"; }

stub() { # stub NAME SONAME SYMBOLS...
    name=$1; soname=$2; shift 2
    : >"$name.c"
    for s in "$@"; do echo "void $s(void) {}" >>"$name.c"; done
    cc -shared -Wl,-soname,"$soname" -o "lib$name.so" "$name.c"
}
stub wayland-client libwayland-client.so.0 wl_display_connect
stub wayland-server libwayland-server.so.0 wl_display_create
stub X11 libX11.so.6 XCreateWindow XOpenDisplay
stub gtk-3 libgtk-3.so.0 gtk_window_new

cat >wayland-app.c <<'C'
extern void wl_display_connect(void);
/* What wayland-scanner generates: the interface's name in read-only data. */
const char *volatile iface = "xdg_wm_base";
int main(void) { wl_display_connect(); return iface[0]; }
C
cat >x11-app.c <<'C'
extern void XOpenDisplay(void); extern void XCreateWindow(void);
int main(void) { XOpenDisplay(); XCreateWindow(); return 0; }
C
cat >x11-tool.c <<'C'
extern void XOpenDisplay(void);
int main(void) { XOpenDisplay(); return 0; }
C
cat >server.c <<'C'
extern void wl_display_create(void);
int main(void) { wl_display_create(); return 0; }
C
cat >gtk-app.c <<'C'
extern void gtk_window_new(void);
int main(void) { gtk_window_new(); return 0; }
C
cc -o "$here/wayland-app" wayland-app.c -L. -lwayland-client
cc -o "$here/x11-app" x11-app.c -L. -lX11
cc -o "$here/x11-tool" x11-tool.c -L. -lX11
cc -o "$here/server" server.c -L. -lwayland-server
cc -o "$here/gtk-app" gtk-app.c -L. -lgtk-3
ls -l "$here"
