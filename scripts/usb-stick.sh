#!/usr/bin/env bash
# A USB stick for the running VM: makes a stick image from a folder (an MBR partition table and one FAT32 or ext4
# partition, like a stick from the shop) and plugs it in or pulls it out through QEMU's QMP.
#
#   scripts/usb-stick.sh [--instance NAME] plug DIR|IMAGE [--fs vfat|ext4]
#   scripts/usb-stick.sh [--instance NAME] pull
#   scripts/usb-stick.sh make DIR IMAGE [--fs vfat|ext4]
#
# A folder becomes vm/[NAME/]stick.img; it is made in the builder container (mtools), no root needed. Example, an
# update from a stick: a folder with the files of a release (SHA256SUMS, openhu-os_<v>.root.raw.gz,
# openhu-os_<v>.efi), e.g. vm/upif-updates.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VM="$REPO/vm"
BUILDER="openhu-os-builder:trixie"
FS=vfat
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --instance) VM="$VM/$2"; shift 2 ;;
    --fs) FS="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

make() {
  local dir image size
  dir="$(realpath "$1")"; image="$(realpath -m "$2")"
  # the files plus room for the file system
  size=$(( $(du -sm --apparent-size "$dir" | cut -f1) * 11 / 10 + 64 ))
  rm -f "$image"
  truncate -s "${size}M" "$image"
  case "$FS" in
    vfat) printf 'label: dos\nstart=2048, type=c\n' ;;
    ext4) printf 'label: dos\nstart=2048, type=83\n' ;;
    *) echo "unknown --fs $FS (vfat, ext4)" >&2; exit 1 ;;
  esac | sfdisk --quiet "$image"
  docker image inspect "$BUILDER" >/dev/null 2>&1 || { echo "no $BUILDER, run scripts/build.sh once" >&2; exit 1; }
  docker run --rm --user "$(id -u):$(id -g)" -v "$image:/stick.img" -v "$dir:/src:ro" "$BUILDER" sh -c "
    set -e
    if [ $FS = vfat ]; then
      mkfs.vfat -F 32 -n OPENHU --offset 2048 /stick.img >/dev/null
      mcopy -s -i /stick.img@@1M /src/* ::/
    else
      mke2fs -q -t ext4 -L OPENHU -d /src -E offset=1048576 /stick.img $(( size - 1 ))M
    fi"
  echo "$image: $FS, ${size} MB"
}

qmp() {
  python3 - "$VM/qmp.sock" "$@" <<'PY'
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
if sys.argv[2] == "plug":
    # a drive from drive_add goes away with its device
    out = call("human-monitor-command", **{"command-line": f"drive_add 0 if=none,id=stick,format=raw,file={sys.argv[3]}"})
    if out.strip() != "OK":
        sys.exit(out.strip())
    call("device_add", driver="usb-storage", id="stick", drive="stick", bus="xhci.0", removable=True)
else:
    call("device_del", id="stick")
PY
}

[ -S "$VM/qmp.sock" ] || [ "${1:-}" = make ] || { echo "no running VM ($VM/qmp.sock)" >&2; exit 1; }
case "${1:-}" in
  make)
    [ $# = 3 ] || { echo "usage: $0 make DIR IMAGE [--fs vfat|ext4]" >&2; exit 1; }
    make "$2" "$3" ;;
  plug)
    [ $# = 2 ] || { echo "usage: $0 plug DIR|IMAGE" >&2; exit 1; }
    image="$2"
    if [ -d "$2" ]; then
      image="$VM/stick.img"
      make "$2" "$image"
    fi
    qmp plug "$(realpath "$image")"
    echo "stick plugged in" ;;
  pull)
    qmp pull
    echo "stick pulled out" ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
