#!/usr/bin/env bash
# A/B update test in a second VM (vm/updatetest/: headless, no phone, ssh on port 2224, update server on 8071):
#   1. version 1 boots, a setting is saved (volume)
#   2. update to version 2: boots from the other slot, is marked good, the setting is still there
#   3. power cut while the next update writes the root partition: version 2 boots, the slot is empty again
#   4. update to a broken version 3 (OpenHU masked): after three failed tries version 2 boots again
#
#   scripts/update-test.sh [V1 V2 V3]     versions already in mkosi.output (V3 built broken, see below);
#                                         without them the three images are built first (about 5 minutes)
#
# A broken version: scripts/build.sh --version V3 --kernel-command-line=systemd.mask=openhu-session.service
# OPENHU_VM_OPTS: more run-vm.sh options, e.g. --no-gl on a host without GPU (CI)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME=updatetest
PORT=2224
HTTP=8071
DIR="$REPO/vm/$NAME"
UPDATES="$DIR/updates"
LOG="$DIR/serial.log"
QEMU=""; SERVER=""

if [ $# -eq 3 ]; then
  V1="$1"; V2="$2"; V3="$3"
else
  base="$(date -u +%Y.%m.%d.%H%M)"
  V1="$base.1"; V2="$base.2"; V3="$base.3"
  "$REPO/scripts/build.sh" --version "$V1"
  "$REPO/scripts/build.sh" --version "$V2"
  "$REPO/scripts/build.sh" --version "$V3" --kernel-command-line=systemd.mask=openhu-session.service
fi

ssh_vm() { OPENHU_VM_SSH_PORT=$PORT "$REPO/scripts/ssh.sh" -o ConnectTimeout=2 "$@"; }
update_vm() { ssh_vm "OPENHU_UPDATE_URL=http://10.0.2.2:$HTTP/ openhu-update $*"; }
step() { echo "$(date +%T) $*"; }
fail() { echo "FAIL: $*" >&2; ssh_vm openhu-update status >&2 || true; exit 1; }

start_vm() {
  "$REPO/scripts/run-vm.sh" --instance "$NAME" --ssh-port "$PORT" --headless --no-phone ${OPENHU_VM_OPTS:-} "$@" </dev/null >>"$LOG" 2>&1 &
  QEMU=$!
}

cut_power() {
  kill -9 "$QEMU" 2>/dev/null || true
  wait "$QEMU" 2>/dev/null || true
  QEMU=""
}

cleanup() {
  cut_power
  [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
}
trap cleanup EXIT

# Waits until the VM runs version $1 (OpenHU answering unless $2 = any) within $3 seconds (default 90)
wait_version() {
  local start=$SECONDS
  until [ "$(ssh_vm 'grep IMAGE_VERSION= /usr/lib/os-release' 2>/dev/null)" = "IMAGE_VERSION=\"$1\"" ] &&
        { [ "${2:-}" = any ] || ssh_vm /usr/libexec/openhu-os/openhu-api system.ping >/dev/null 2>&1; }; do
    [ $((SECONDS - start)) -lt "${3:-90}" ] || fail "version $1 did not come up"
    sleep 2
  done
}

wait_good() {
  local start=$SECONDS
  until ssh_vm openhu-update status 2>/dev/null | grep -q "openhu-os_$1.efi: good"; do
    [ $((SECONDS - start)) -lt 60 ] || fail "version $1 was not marked good"
    sleep 2
  done
}

mkdir -p "$DIR"
: > "$LOG"
rm -rf "$UPDATES"
for v in "$V2" "$V3"; do "$REPO/scripts/add-update.sh" "$v" "$UPDATES" >/dev/null; done
python3 -m http.server --bind 127.0.0.1 --directory "$UPDATES" "$HTTP" >/dev/null 2>&1 &
SERVER=$!

step "1. version $V1"
start_vm --fresh --image "$REPO/mkosi.output/openhu-os_$V1.raw"
wait_version "$V1"
ssh_vm '/usr/libexec/openhu-os/openhu-api volume.set "{\"value\": 33}"' >/dev/null
sleep 3   # WirePlumber writes its state about a second later

step "2. update to $V2"
update_vm update --version "$V2" --reboot >/dev/null || true   # the ssh connection ends with the reboot
wait_version "$V2"
wait_good "$V2"
ssh_vm /usr/libexec/openhu-os/openhu-api volume.get | grep -q '"volume": 33' || fail "volume lost in the update"
ssh_vm cat /run/openhu-os/boot-status.json | grep -q '"state": "updated"' || fail "boot status not updated"
step "   runs, marked good, boot status updated, volume kept"

step "3. power cut while writing the root partition"
# in the background like OpenHU does it (openhu-update.service), progress from /run/openhu-os/update.json
update_vm start --version "$V3" >/dev/null
start=$SECONDS
until ssh_vm 'grep -Eq "\"phase\": \"root\", \"percent\": ([4-9][0-9])" /run/openhu-os/update.json' 2>/dev/null; do
  [ $((SECONDS - start)) -lt 60 ] || fail "update did not start"
  sleep 0.2
done
cut_power
start_vm
wait_version "$V2"
ssh_vm openhu-update status | grep -q "other slot: empty" || fail "half written slot not empty"
step "   $V2 boots, the other slot is empty"

step "4. update to the broken $V3"
update_vm update --version "$V3" --reboot >/dev/null || true
wait_version "$V3" any
step "   $V3 boots (try 1), waiting for three failed tries"
wait_version "$V2" "" 600
ssh_vm openhu-update status | grep -q "openhu-os_$V3+0-3.efi: failed" || fail "$V3 not marked failed"
step "   back on $V2, $V3 failed"

echo "OK: update, power cut during an update and rollback"
