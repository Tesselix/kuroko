#!/bin/sh
# Builds Kuroko for the Ubuntu ARM VM into the shared folder.
#
#   sh tools/ubuntu/build.sh                 into ubuntu-share/kuroko
#   SHARE=/other/folder sh tools/ubuntu/build.sh
#   OPTIMIZE=Debug sh tools/ubuntu/build.sh  a Debug build
#   VM_SHARE=/mnt/x ...                      where the VM mounts the share
#                                            (only for the printed commands)
#
# Then on the VM:  sh /mnt/shared/kuroko/check.sh   (before the first run)
#                  sh /mnt/shared/kuroko/setup.sh   (once)
#                  sh /mnt/shared/kuroko/run.sh
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
share=${SHARE:-$root/ubuntu-share}
vm_share=${VM_SHARE:-/mnt/shared}
target=${TARGET:-aarch64-linux-gnu}
optimize=${OPTIMIZE:-ReleaseSafe}
out="$share/kuroko"

cd "$root"
zig build -Dtarget="$target" -Doptimize="$optimize" --prefix "$out"
# Readable and runnable by everyone: on the VM the share shows the Mac's
# owner (uid 501), not the VM's user.
install -m 755 tools/ubuntu/run.sh tools/ubuntu/setup.sh tools/ubuntu/check.sh tools/ubuntu/browser.sh "$out/"
chmod 755 "$out/bin/"*
echo
echo "Built for $target ($optimize) in $out. On the VM:"
echo "  sh $vm_share/kuroko/check.sh"
echo "  sh $vm_share/kuroko/setup.sh     (once)"
echo "  sh $vm_share/kuroko/run.sh"
