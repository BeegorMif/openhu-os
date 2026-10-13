#!/usr/bin/env bash
# Power cut test: boots a second VM (vm/powerloss/: headless, no phone, ssh on port 2223) from the newest image and
# cuts its power (kill -9 of QEMU) at a random moment, ROUNDS times. The first cut hits the first boot (systemd-repart
# creating slot B and the data partition), the others hit OpenHU while it writes ~/.openhu/sources.list
# (store.sources.add/remove in a loop) next to a file writer on /var.
# Before the writing starts, every round saves settings and waits until they are written: a marker source in
# sources.list and the volume (WirePlumber state, written about a second after a change).
# After every cut the VM must come back into OpenHU with its settings:
#   - OpenHU's API answers within 90 s, no failed units
#   - / is the read-only erofs root, /var the data partition, read-write, root slot B exists
#   - sources.list still has the official plugin source and the marker of the round before
#   - the volume of the round before
#
#   scripts/powerloss-test.sh [ROUNDS]     default 10; the dev VM (scripts/run-vm.sh) may keep running
#
# QEMU writes through the host's page cache (cache=writeback): what the guest wrote before the cut survives, as with
# a disk without a volatile write cache. Lost are the guest's own caches and the writes in flight.
# On a failure the VM disk stays in vm/powerloss/ (OPENHU_VM_SSH_PORT=2223 scripts/ssh.sh after a restart with
# scripts/run-vm.sh --instance powerloss --ssh-port 2223 --headless --no-phone).
# OPENHU_VM_OPTS: more run-vm.sh options, e.g. --no-gl on a host without GPU (CI)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROUNDS="${1:-10}"
NAME=powerloss
PORT=2223
DIR="$REPO/vm/$NAME"
LOG="$DIR/serial.log"
QEMU=""

ssh_vm() { OPENHU_VM_SSH_PORT=$PORT "$REPO/scripts/ssh.sh" -o ConnectTimeout=2 "$@"; }

start_vm() {
  "$REPO/scripts/run-vm.sh" --instance "$NAME" --ssh-port "$PORT" --headless --no-phone ${OPENHU_VM_OPTS:-} "$@" </dev/null >>"$LOG" 2>&1 &
  QEMU=$!   # run-vm.sh execs QEMU
}

cut_power() {
  kill -9 "$QEMU" 2>/dev/null || true
  wait "$QEMU" 2>/dev/null || true
  QEMU=""
}

trap 'cut_power' EXIT

# Seconds until the API answers, fails after 90 s
wait_api() {
  local start=$SECONDS
  until ssh_vm openhu api system.ping >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge 90 ] || ! kill -0 "$QEMU" 2>/dev/null; then
      echo "FAIL: OpenHU did not come up, serial console in $LOG" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo $((SECONDS - start))
}

# Runs in the guest after every boot: prints a summary, exits 1 when something is broken
# $1, $2: marker and volume saved in the round before (empty: nothing saved yet)
check_guest() {
  ssh_vm "MARKER='$1' VOLUME='$2' sh -s" <<'EOF'
fail() { echo "FAIL: $*"; exit 1; }
failed="$(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)"
[ -z "$failed" ] || fail "failed units: $failed"
[ "$(findmnt -n -o FSTYPE /)" = erofs ] || fail "/ is not erofs"
findmnt -n -o OPTIONS / | grep -q '^ro' || fail "/ is not read-only"
[ "$(lsblk -n -o PARTLABEL "$(findmnt -n -o SOURCE /var)")" = openhu-data ] || fail "/var is not the data partition"
findmnt -n -o OPTIONS /var | grep -q '^rw' || fail "/var is not read-write"
status="$(openhu status --json)" || fail "openhu status: $status"
echo "$status" | grep -q '"running": true' || fail "openhu status: OpenHU not running: $status"
openhu help >/dev/null || fail "openhu help"
sources="$(openhu api store.sources.list)" || fail "store.sources.list: $sources"
echo "$sources" | grep -q '"official": true' || fail "official plugin source lost: $(od -c /var/lib/openhu/.openhu/sources.list | head -3)"
[ -z "$MARKER" ] || echo "$sources" | grep -q "$MARKER" || fail "saved source $MARKER lost: $sources"
volume="$(openhu api volume.get | grep -o '"volume": [0-9]*' | cut -d' ' -f2)"
[ -z "$VOLUME" ] || [ "$volume" = "$VOLUME" ] || fail "saved volume $VOLUME lost, volume is $volume"
lsblk -n -o PARTLABEL /dev/vda | grep -qx _empty || fail "root slot B missing"
fsck="$(journalctl -b -o cat -u 'systemd-fsck@*' | grep 'openhu-data:' | head -1)"
echo "sources $(echo "$sources" | grep -o '"index"' | wc -l), volume $volume, fsck: ${fsck#openhu-data: }"
EOF
}

# Saves a marker source (index 1, after removing all but the official source) and the volume, waits until they are
# written. The writer adds and removes the source behind it (index 2).
save_settings() {
  ssh_vm sh -s <<EOF >/dev/null
while openhu api store.sources.remove '{"index": 1}'; do :; done
openhu api store.sources.add '{"type": "url", "location": "$1"}'
openhu api volume.set '{"value": $2}'
sleep 3
EOF
}

# Writes in a loop until the power goes
start_writer() {
  ssh_vm 'cat > /run/powerloss-writer.sh && systemd-run --quiet --unit=powerloss-writer /bin/sh /run/powerloss-writer.sh' <<'EOF'
i=0
while :; do
  i=$((i + 1))
  openhu api store.sources.add "{\"type\": \"url\", \"location\": \"https://example.invalid/write-$i/\"}" >/dev/null
  openhu api store.sources.remove '{"index": 2}' >/dev/null
  dd if=/dev/urandom of=/var/tmp/powerloss.$((i % 4)) bs=64k count=16 conv=fsync status=none
  echo $i > /run/powerloss-cycles
done
EOF
}

mkdir -p "$DIR"
: > "$LOG"
echo "Power cut test, $ROUNDS rounds, VM in vm/$NAME"

marker=""; volume=""
for round in $(seq 1 "$ROUNDS"); do
  if [ "$round" = 1 ]; then
    start_vm --fresh
    delay=$((2 + RANDOM % 4))
    sleep "$delay"
    cut_power
    echo "round 1: power cut ${delay}s into the first boot"
    continue
  fi

  start_vm
  boot="$(wait_api)"
  result="$(check_guest "$marker" "$volume")" || { echo "round $round: $result"; exit 1; }
  echo "round $round: booted in ${boot}s, $result"
  marker="https://example.invalid/round-$round/"
  volume=$((20 + RANDOM % 70))
  save_settings "$marker" "$volume"
  start_writer
  delay=$((1 + RANDOM % 8))
  sleep "$delay"
  cycles="$(ssh_vm cat /run/powerloss-cycles 2>/dev/null || echo 0)"
  cut_power
  echo "round $round: power cut ${delay}s into writing (${cycles} write cycles)"
done

start_vm
boot="$(wait_api)"
result="$(check_guest "$marker" "$volume")" || { echo "final boot: $result"; exit 1; }
echo "final boot: booted in ${boot}s, $result"
cut_power
echo "OK: $ROUNDS power cuts survived"
