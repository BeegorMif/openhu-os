#!/usr/bin/env bash
# Adds a built version to the update directory that scripts/serve-updates.sh serves (and CI will publish):
# openhu-os_<version>.root.raw.gz (root partition), openhu-os_<version>.efi (unified kernel image), SHA256SUMS.
#
#   scripts/add-update.sh [VERSION] [DIR]      default: the newest build, mkosi.output/updates
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
DIR="${2:-$REPO/mkosi.output/updates}"

if [ -z "$VERSION" ]; then
  uki="$(ls -t "$REPO"/mkosi.output/openhu-os_*.efi 2>/dev/null | head -1)"
  [ -n "$uki" ] || { echo "no build in mkosi.output, run scripts/build.sh" >&2; exit 1; }
  VERSION="$(basename "$uki" .efi)"; VERSION="${VERSION#openhu-os_}"
fi
root="$REPO/mkosi.output/openhu-os_$VERSION.root.raw"
uki="$REPO/mkosi.output/openhu-os_$VERSION.efi"
[ -f "$root" ] && [ -f "$uki" ] || { echo "openhu-os_$VERSION.root.raw/.efi missing in mkosi.output" >&2; exit 1; }

mkdir -p "$DIR"
gz=gzip; command -v pigz >/dev/null && gz=pigz
# the slot is mostly zeros after the erofs file system: compresses to about its content
"$gz" -1 -c "$root" > "$DIR/openhu-os_$VERSION.root.raw.gz.part"
mv "$DIR/openhu-os_$VERSION.root.raw.gz.part" "$DIR/openhu-os_$VERSION.root.raw.gz"
cp "$uki" "$DIR/openhu-os_$VERSION.efi"
(cd "$DIR" && sha256sum openhu-os_*.root.raw.gz openhu-os_*.efi > SHA256SUMS)
ls -lh "$DIR"
