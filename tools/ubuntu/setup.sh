#!/bin/sh
# Once, on the Ubuntu ARM VM: what Tesselix needs to run on the bare
# console (no X, no Wayland). SDL3 draws through KMS/DRM with EGL/GLES on
# Mesa (virgl in UTM) and reads the keyboard and mouse from the kernel (evdev).
set -e
sudo apt-get update
# libSDL3; the GBM/EGL/GLES libraries its KMS/DRM driver loads; Mesa's
# drivers (virgl for UTM's virtio-gpu-gl); kmscube to test KMS + GL alone.
sudo apt-get install -y libsdl3-0 libgbm1 libegl1 libegl-mesa0 libgles2 \
    libgl1-mesa-dri kmscube
# Screen and input devices without sudo.
missing=""
for g in video render input; do
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$g" || missing="$missing $g"
done
if [ -n "$missing" ]; then
    sudo usermod -aG video,render,input "$USER"
    echo
    echo "Added $USER to:$missing. Log out and back in once."
fi
echo
echo "Done. Check with:  sh $(dirname "$0")/check.sh"
echo "Then run:          sh $(dirname "$0")/run.sh"
