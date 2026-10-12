#!/usr/bin/env bash
# Serves the update directory (scripts/add-update.sh) on 127.0.0.1:8070, the update server of the dev image
# (http://10.0.2.2:8070/ from inside the VM). In the VM: openhu-update check / openhu-update update --reboot
#
#   scripts/serve-updates.sh [DIR]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$REPO/mkosi.output/updates}"
mkdir -p "$DIR"
exec python3 -m http.server --bind 127.0.0.1 --directory "$DIR" 8070
