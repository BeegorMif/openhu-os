#!/usr/bin/env bash
# Screenshot of the OpenHU display as PNG, default vm/screen.png.
#   scripts/screenshot.sh [FILE]
# Taken in the guest with grim (dev image, what cage shows: works with GL); without grim through QEMU's QMP
# (only without GL, --no-gl).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VM="$DIR/../vm"
out="$(realpath -m "${1:-$VM/screen.png}")"

if "$DIR/ssh.sh" -o ConnectTimeout=3 'command -v grim >/dev/null' 2>/dev/null; then
  "$DIR/ssh.sh" 'socket=$(ls /run/user/900 | grep -E "^wayland-[0-9]+$" | head -1)
    runuser -u openhu -- env XDG_RUNTIME_DIR=/run/user/900 WAYLAND_DISPLAY="$socket" grim -' > "$out"
else
  python3 - "$VM/qmp.sock" "$out" <<'PY'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
f = sock.makefile("rw")
def call(cmd, **args):
    f.write(json.dumps({"execute": cmd, "arguments": args}) + "\n"); f.flush()
    while True:
        reply = json.loads(f.readline())
        if "error" in reply:
            sys.exit(reply["error"]["desc"])
        if "return" in reply:
            return reply["return"]
json.loads(f.readline())  # greeting
call("qmp_capabilities")
call("screendump", filename=sys.argv[2], format="png")
PY
fi
echo "$out"
