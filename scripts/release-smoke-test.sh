#!/usr/bin/env bash
# Boots a release image (no ssh) in a VM (vm/release/, headless, no phone) and waits until the screen shows the
# OpenHU shell: the dock on the left (Theme.qml surface, #182021) next to the page background (#0f1317). The splash
# (background only) or a text console do not pass. The last screenshot stays in vm/release/screen.ppm.
#
#   scripts/release-smoke-test.sh [IMAGE]      default: the newest image in mkosi.output
# OPENHU_VM_OPTS: more run-vm.sh options, e.g. --no-gl on a host without GPU (CI)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO/vm/release"
image=()
[ $# -gt 0 ] && image=(--image "$1")

mkdir -p "$DIR"
"$REPO/scripts/run-vm.sh" --instance release --ssh-port 2225 --headless --no-phone ${OPENHU_VM_OPTS:-} --fresh "${image[@]}" \
  </dev/null >"$DIR/serial.log" 2>&1 &
QEMU=$!
trap 'kill -9 $QEMU 2>/dev/null || true' EXIT

qmp() { printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" | socat - UNIX-CONNECT:"$DIR/qmp.sock" 2>/dev/null; }

start=$SECONDS
while [ $((SECONDS - start)) -lt 90 ]; do
  sleep 5
  kill -0 $QEMU 2>/dev/null || { echo "FAIL: QEMU ended" >&2; exit 1; }
  qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$DIR/screen.ppm\"}}" >/dev/null || continue
  [ -s "$DIR/screen.ppm" ] || continue
  if python3 - "$DIR/screen.ppm" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
magic, size, maxval, pixels = data.split(b"\n", 3)
width, height = map(int, size.split())
def pixel(x, y):
    i = (y * width + x) * 3
    return pixels[i:i + 3]
def near(color, ref):
    return all(abs(c - r) <= 8 for c, r in zip(color, ref))
dock = pixel(width * 20 // 1280, height // 2)
page = pixel(width * 270 // 1280, height * 600 // 720)
sys.exit(0 if near(dock, (0x18, 0x20, 0x21)) and near(page, (0x0f, 0x13, 0x17)) else 1)
PY
  then
    echo "OK: OpenHU shell on screen after $((SECONDS - start)) s"
    exit 0
  fi
done
echo "FAIL: no OpenHU shell on screen within 90 s, last screenshot $DIR/screen.ppm" >&2
exit 1
