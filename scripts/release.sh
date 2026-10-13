#!/usr/bin/env bash
# Release files of a build in mkosi.output (scripts/build.sh --profile release): the disk image to flash, the update
# for "openhu-cli update" (root partition, unified kernel image), the package manifest and SHA256SUMS over all of them.
#
#   scripts/release.sh VERSION [DIR]      default dist/
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$1"
DIR="${2:-$REPO/dist}"
image="$REPO/mkosi.output/openhu-os_$VERSION.raw"
[ -f "$image" ] || { echo "$image missing, run scripts/build.sh --profile release --version $VERSION" >&2; exit 1; }

mkdir -p "$DIR"
"$REPO/scripts/add-update.sh" "$VERSION" "$DIR" >/dev/null
# 3.6 GB, mostly empty: grows to the whole SD card/disk on the first boot
xz -T0 -6 -c "$image" > "$DIR/openhu-os_$VERSION.raw.xz.part"
mv "$DIR/openhu-os_$VERSION.raw.xz.part" "$DIR/openhu-os_$VERSION.raw.xz"
cp "$REPO/mkosi.output/openhu-os_$VERSION.manifest" "$DIR/openhu-os_$VERSION.manifest.json"
(cd "$DIR" && sha256sum "openhu-os_$VERSION".* > SHA256SUMS)
ls -lh "$DIR"
