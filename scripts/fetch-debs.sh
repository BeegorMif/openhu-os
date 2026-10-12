#!/usr/bin/env bash
# Puts the openhu and libaasdk packages for the image into packages/, until the OpenHU APT repository exists
# (openhu#7).
#
#   scripts/fetch-debs.sh                 newest successful CI build of openhu main (openhu + the libaasdk it was
#                                         built against, both from the CI artifact)
#   scripts/fetch-debs.sh --ci RUN_ID     a specific CI run of average-web-dev/openhu
#   scripts/fetch-debs.sh --dir PATH      local .debs (e.g. ../openhu/docker/output); libaasdk must match the
#                                         aasdk openhu was built against
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-amd64}"
SOURCE="ci"
RUN_ID=""
DIR=""
case "${1:-}" in
  --ci) RUN_ID="${2:-}" ;;
  --dir) SOURCE="dir"; DIR="$2" ;;
  "") ;;
  *) echo "usage: $0 [--ci RUN_ID | --dir PATH]" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$SOURCE" = ci ]; then
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(gh run list -R average-web-dev/openhu -w ci.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')"
  fi
  echo "openhu CI run $RUN_ID, artifact openhu-$ARCH"
  gh run download "$RUN_ID" -R average-web-dev/openhu -n "openhu-$ARCH" -D "$tmp"
else
  cp -v "$DIR"/*.deb "$tmp"/
fi

# exactly one version of each package: the local repository (reprepro) rejects duplicates
rm -rf "$REPO/packages"
mkdir -p "$REPO/packages"
for name in openhu libaasdk; do
  deb="$(ls "$tmp"/${name}_*_"$ARCH".deb 2>/dev/null | sort -V | tail -1)"
  [ -n "$deb" ] || { echo "no ${name}_*_$ARCH.deb found" >&2; exit 1; }
  cp -v "$deb" "$REPO/packages/"
done
