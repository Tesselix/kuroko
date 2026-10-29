#!/bin/sh
# Keeps the package fingerprint in build.zig.zon valid.
#
#   sh tools/fingerprint.sh
#
# Zig derives .fingerprint from the package .name, so renaming the package
# (tesselix -> kuroko) makes every build fail with "invalid fingerprint".
# This asks zig for the value it expects and writes it into build.zig.zon.
# Any other build error is left for the real build to report.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

msg=$(zig build --help 2>&1 >/dev/null || true)
new=$(printf '%s\n' "$msg" | sed -n 's/.*invalid fingerprint: .*use this value: \(0x[0-9a-fA-F]*\).*/\1/p' | head -n 1)
[ -n "$new" ] || exit 0

sed -i.bak "s/\.fingerprint = 0x[0-9a-fA-F]*,/.fingerprint = $new,/" build.zig.zon
rm -f build.zig.zon.bak
echo "build.zig.zon: fingerprint updated to $new (package was renamed)"
