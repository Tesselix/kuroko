#!/bin/sh
# Builds Tesselix for the Ubuntu ARM VM into the shared folder.
#
#   sh tools/ubuntu/build.sh                 into ubuntu-share/tesselix
#   SHARE=/other/folder sh tools/ubuntu/build.sh
#
# Then on the VM:  sh <shared folder>/tesselix/setup.sh  (once)
#                  sh <shared folder>/tesselix/run.sh
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
share=${SHARE:-$root/ubuntu-share}
target=${TARGET:-aarch64-linux-gnu}
out="$share/tesselix"

cd "$root"
zig build -Dtarget="$target" --prefix "$out"
cp tools/ubuntu/run.sh tools/ubuntu/setup.sh "$out/"
chmod +x "$out/run.sh" "$out/setup.sh" "$out/bin/"*
echo
echo "Built for $target in $out. On the VM:"
echo "  sh <shared folder>/tesselix/setup.sh   (once)"
echo "  sh <shared folder>/tesselix/run.sh"
