#!/usr/bin/env bash
# Renders the splash images (theme/logo.png, theme/dot.png) in a throwaway container. Colors and font of the OpenHU
# shell (Theme.qml: text #e8eef4, primary #4f9cf9, DejaVu Sans). Replace logo.png with a real logo any time.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/theme"
docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$DIR:/out" debian:trixie-slim bash -euo pipefail -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends imagemagick fonts-dejavu-core >/dev/null
  font=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
  magick -background none -fill "#e8eef4" -font "$font" -pointsize 160 label:OpenHU -trim +repage /out/logo.png
  magick -size 48x48 xc:none -fill "#4f9cf9" -draw "circle 24,24 24,4" /out/dot.png
  chown "$1" /out/logo.png /out/dot.png' _ "$(id -u):$(id -g)"
