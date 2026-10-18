#!/bin/sh
# Once, on the Ubuntu ARM VM: what Tesselix needs to run on the bare
# console (no X, no Wayland). SDL3 draws through KMS/DRM and reads the
# keyboard and mouse from the kernel (evdev).
set -e
sudo apt-get update
# libSDL3, and the GBM/EGL libraries its KMS/DRM driver loads.
sudo apt-get install -y libsdl3-0 libgbm1 libegl1
# Screen and input devices without sudo (log out and in once after this).
sudo usermod -aG video,render,input "$USER"
echo
echo "Done. Log out and back in once (for the video/render/input groups),"
echo "then run:  sh $(dirname "$0")/run.sh"
