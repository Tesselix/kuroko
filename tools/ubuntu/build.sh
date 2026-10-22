#!/bin/sh
# Builds Tesselix for the Ubuntu ARM VM into the shared folder.
#
#   sh tools/ubuntu/build.sh                 into ubuntu-share/tesselix
#   SHARE=/other/folder sh tools/ubuntu/build.sh
#   OPTIMIZE=Debug sh tools/ubuntu/build.sh  a Debug build
#   VM_SHARE=/mnt/x ...                      where the VM mounts the share
#                                            (only for the printed commands)
#
# Then on the VM:  sh /mnt/shared/tesselix/check.sh   (before the first run)
#                  sh /mnt/shared/tesselix/setup.sh   (once)
#                  sh /mnt/shared/tesselix/run.sh
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
share=${SHARE:-$root/ubuntu-share}
vm_share=${VM_SHARE:-/mnt/shared}
target=${TARGET:-aarch64-linux-gnu}
optimize=${OPTIMIZE:-ReleaseSafe}
out="$share/tesselix"

cd "$root"
zig build -Dtarget="$target" -Doptimize="$optimize" --prefix "$out"
cp tools/ubuntu/run.sh tools/ubuntu/setup.sh tools/ubuntu/check.sh tools/ubuntu/browser.sh "$out/"
chmod +x "$out/run.sh" "$out/setup.sh" "$out/check.sh" "$out/browser.sh" "$out/bin/"*
echo
echo "Built for $target ($optimize) in $out. On the VM:"
echo "  sh $vm_share/tesselix/check.sh"
echo "  sh $vm_share/tesselix/setup.sh     (once)"
echo "  sh $vm_share/tesselix/run.sh"
