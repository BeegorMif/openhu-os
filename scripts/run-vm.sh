#!/usr/bin/env bash
# Boots the newest image from mkosi.output in QEMU/KVM with UEFI. The VM disk is a copy in vm/, settings survive
# restarts of the VM until --fresh.
#
#   scripts/run-vm.sh [--fresh] [--no-gl] [--res WxH] [--headless] [--phone VID:PID,...]
#
#   --fresh     new disk from the newest image (and fresh UEFI variables)
#   --no-gl     virtual GPU without 3D (cage/wlroots render with pixman, Qt with llvmpipe: slow video)
#   --res       display size, default 1280x720. With a window, QEMU tells the guest the window size instead:
#               resize the window, or use --headless
#   --headless  no window (CI); with GL (egl-headless) unless --no-gl. Screenshots: scripts/screenshot.sh
#               (with a GL window QEMU has no image to read back)
#   --phone IDS more phones to pass through, VID:PID in hex as lsusb shows them, comma separated (e.g. 04e8:6860).
#               Always passed through: 18d1:4ee1/4ee2 (Pixel, Fairphone) and 18d1:2d00/2d01 (every phone in
#               accessory mode). The phone must not be in use on the host.
#
# ssh: scripts/ssh.sh (port 2222), screenshot: scripts/screenshot.sh. Serial console on this terminal (Ctrl+A X
# quits QEMU).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VM="$REPO/vm"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
# fixed: systemd derives the machine id from it in a VM
VM_UUID=6f70656e-6875-4f53-8000-000000000001
FRESH=0; GL=1; RES=1280x720; HEADLESS=0; PHONE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1; shift ;;
    --no-gl) GL=0; shift ;;
    --res) RES="$2"; shift 2 ;;
    --headless) HEADLESS=1; shift ;;
    --phone) PHONE="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$VM"
if [ "$FRESH" = 1 ] || [ ! -f "$VM/disk.raw" ]; then
  image="$(ls -t "$REPO"/mkosi.output/openhu-os_*.raw 2>/dev/null | grep -v '\.root-\|\.esp' | head -1)"
  [ -n "$image" ] || { echo "no image in mkosi.output, run scripts/build.sh" >&2; exit 1; }
  echo "New VM disk from $(basename "$image")"
  cp --sparse=always "$image" "$VM/disk.raw"
  truncate -s 16G "$VM/disk.raw"
  cp "$OVMF_VARS" "$VM/OVMF_VARS.fd"
fi

xres="${RES%x*}"; yres="${RES#*x}"
if [ "$HEADLESS" = 1 ] && [ "$GL" = 1 ]; then
  # 3D like the window, read back by QEMU: screenshots work (scripts/screenshot.sh)
  display=(-device "virtio-vga-gl,xres=$xres,yres=$yres" -display egl-headless)
elif [ "$HEADLESS" = 1 ]; then
  display=(-device "virtio-vga,xres=$xres,yres=$yres" -display none)
elif [ "$GL" = 1 ]; then
  display=(-device "virtio-vga-gl,xres=$xres,yres=$yres" -display gtk,gl=on,zoom-to-fit=off)
else
  display=(-device "virtio-vga,xres=$xres,yres=$yres" -display gtk,zoom-to-fit=off)
fi

# One passthrough slot per USB id the phone can have, none overlapping: Google's normal modes (MTP 4ee1, MTP+adb
# 4ee2; Pixel, Fairphone) and accessory mode (2d00, 2d01, after OpenHU switched the phone). With one 18d1 slot QEMU
# does not tell the guest that the phone came back as another device; with overlapping slots it moves the phone
# between them and the Android Auto session breaks.
usb=(-device qemu-xhci,id=xhci,p2=8,p3=8 -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0)
for id in 18d1:2d00 18d1:2d01 18d1:4ee1 18d1:4ee2 ${PHONE//,/ }; do
  usb+=(-device "usb-host,bus=xhci.0,vendorid=0x${id%:*},productid=0x${id#*:}")
done

exec qemu-system-x86_64 -name openhu-os -machine q35,accel=kvm -cpu host -smp 4 -m 4096 -uuid "$VM_UUID" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$VM/OVMF_VARS.fd" \
  -drive if=none,id=disk0,format=raw,file="$VM/disk.raw",cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=disk0,bootindex=1 \
  "${display[@]}" "${usb[@]}" \
  -audiodev pipewire,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -qmp unix:"$VM/qmp.sock",server=on,wait=off \
  -pidfile "$VM/qemu.pid" -serial mon:stdio
