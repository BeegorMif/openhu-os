#!/usr/bin/env bash
# Boots the newest image from mkosi.output in QEMU/KVM with UEFI. The VM disk is a copy in vm/, settings survive
# restarts of the VM until --fresh.
#
#   scripts/run-vm.sh [--fresh] [--no-gl] [--res WxH] [--headless] [--phone VID:PID,...] [--ui gtk|x11|sdl]
#                     [--instance NAME --ssh-port PORT] [--no-phone] [--wifi] [--eth2 PORT] [--plugins PLUGINS]
#
#   --arch A    x86-64 (default, KVM) or arm64 (QEMU "virt" machine with AAVMF firmware: KVM on an arm64 host with
#               /dev/kvm, otherwise TCG emulation, slow: minutes to boot). Also OPENHU_VM_ARCH. Needs the packages
#               qemu-system-arm and qemu-efi-aarch64. This tests the image, not the Raspberry Pi hardware.
#   --fresh     new disk from the newest image (and fresh UEFI variables)
#   --image F   with --fresh: this image instead of the newest (e.g. an older version to test updates)
#   --no-gl     virtual GPU without 3D (cage/wlroots render with pixman, Qt with llvmpipe: slow video)
#   --res       display size, default 1280x720 (the GTK window reports its own size instead)
#   --ui UI     window: sdl (default), gtk or x11 (GTK through XWayland). The dev image draws the cursor in
#               software: the virtio GPU's cursor plane shows it about 64 px too low.
#   --headless  no window (CI); with GL (egl-headless) unless --no-gl. Screenshots: scripts/screenshot.sh
#               (with a GL window QEMU has no image to read back)
#   --phone IDS more phones to pass through, VID:PID in hex as lsusb shows them, comma separated (e.g. 04e8:6860).
#               Always passed through: 18d1:4ee1/4ee2 (Pixel, Fairphone) and 18d1:2d00/2d01 (every phone in
#               accessory mode). The phone must not be in use on the host.
#   --no-phone  no phone passthrough (a second VM next to the one with the phone)
#   --wifi      a virtual WiFi card (mac80211_hwsim, wlan0) on every boot, through a kernel command line extra
#               (SMBIOS, read by the UKI's systemd-stub); without it the VM has no WiFi like a PC without a card
#   --eth2 PORT a second Ethernet card on a virtual cable (UDP multicast on the host's loopback, PORT picks the
#               cable): VMs started with the same PORT see each other, e.g. the head unit as DHCP server and a
#               second instance as a device (openhu-cli ethernet mode, #15). No root or tap device needed.
#   --plugins D   share the host folder D into the guest (9p, mount tag "plugins"); default ../openhu-plugins if it exists
#   --no-plugins  no plugins share (a second VM next to the first, CI)
#   --instance  a second VM with its own disk, UEFI variables and QMP socket in vm/NAME/ (scripts/powerloss-test.sh);
#               needs its own --ssh-port (scripts/ssh.sh: OPENHU_VM_SSH_PORT=PORT)
#
# ssh: scripts/ssh.sh (port 2222), screenshot: scripts/screenshot.sh. Serial console on this terminal (Ctrl+A X
# quits QEMU).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VM="$REPO/vm"
# fixed: systemd derives the machine id from it in a VM
VM_UUID=6f70656e-6875-4f53-8000-000000000001
ARCH="${OPENHU_VM_ARCH:-x86-64}"
IMAGE=""; FRESH=0; GL=1; RES=1920x1080; HEADLESS=0; PHONE=""; UI=sdl; PHONES=1; SSH_PORT=2222; WIFI=1; ETH2=""; PLUGINS="$REPO/../openhu-plugins/plugins"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --no-gl) GL=0; shift ;;
    --res) RES="$2"; shift 2 ;;
    --headless) HEADLESS=1; shift ;;
    --phone) PHONE="$2"; shift 2 ;;
    --ui) UI="$2"; shift 2 ;;
    --no-phone) PHONES=0; shift ;;
    --instance) VM="$VM/$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --wifi) WIFI=1; shift ;;
    --eth2) ETH2="$2"; shift 2 ;;
    --plugins) PLUGINS="$2"; shift 2 ;;
    --no-plugins) PLUGINS=""; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

# What differs per architecture: QEMU binary, UEFI firmware (pflash), machine/CPU/accelerator, virtual GPU
case "$ARCH" in
  x86-64)
    QEMU=qemu-system-x86_64
    OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
    machine=(-machine q35,accel=kvm,vmport=off -cpu host)
    GPU=virtio-vga; GPU_GL=virtio-vga-gl ;;
  arm64)
    QEMU=qemu-system-aarch64
    OVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
    OVMF_VARS=/usr/share/AAVMF/AAVMF_VARS.fd
    if [ "$(uname -m)" = aarch64 ] && [ -w /dev/kvm ]; then
      machine=(-machine virt,accel=kvm -cpu host)
    else
      echo "arm64 VM without KVM: TCG emulation, expect a slow boot" >&2
      machine=(-machine virt,accel=tcg -cpu max,pauth-impdef=on)
    fi
    GPU=virtio-gpu-pci; GPU_GL=virtio-gpu-gl-pci ;;
  *) echo "unknown --arch $ARCH (x86-64 or arm64)" >&2; exit 1 ;;
esac
for f in "$OVMF_CODE" "$OVMF_VARS"; do
  [ -f "$f" ] || { echo "$f missing: install ovmf (x86-64) or qemu-efi-aarch64 (arm64)" >&2; exit 1; }
done
command -v "$QEMU" >/dev/null || { echo "$QEMU missing: install qemu-system-x86 or qemu-system-arm" >&2; exit 1; }

mkdir -p "$VM"
if [ "$FRESH" = 1 ] || [ ! -f "$VM/disk.raw" ]; then
  image="${IMAGE:-$(ls -t "$REPO"/mkosi.output/openhu-os_*.raw 2>/dev/null | grep -v '\.root\.raw$' | head -1)}"
  [ -n "$image" ] || { echo "no image in mkosi.output, run scripts/build.sh" >&2; exit 1; }
  echo "New VM disk from $(basename "$image")"
  cp --sparse=always "$image" "$VM/disk.raw"
  truncate -s 16G "$VM/disk.raw"
  cp "$OVMF_VARS" "$VM/OVMF_VARS.fd"
fi

xres="${RES%x*}"; yres="${RES#*x}"
if [ "$HEADLESS" = 1 ] && [ "$GL" = 1 ]; then
  # 3D like the window, read back by QEMU: screenshots work (scripts/screenshot.sh)
  display=(-device "$GPU_GL,xres=$xres,yres=$yres" -display egl-headless)
elif [ "$HEADLESS" = 1 ]; then
  display=(-device "$GPU,xres=$xres,yres=$yres" -display none)
else
  gpu="$GPU"; [ "$GL" = 1 ] && gpu="$GPU_GL"
  case "$UI" in
    gtk|x11) ui="gtk,zoom-to-fit=off" ;;
    sdl) ui="sdl" ;;
    *) echo "unknown --ui $UI" >&2; exit 1 ;;
  esac
  [ "$GL" = 1 ] && ui="$ui,gl=on"
  [ "$UI" = x11 ] && export GDK_BACKEND=x11
  display=(-device "$gpu,xres=$xres,yres=$yres" -display "$ui")
fi

# One passthrough slot per USB id the phone can have, none overlapping: Google's normal modes (MTP 4ee1, MTP+adb
# 4ee2; Pixel, Fairphone) and accessory mode (2d00, 2d01, after OpenHU switched the phone). With one 18d1 slot QEMU
# does not tell the guest that the phone came back as another device; with overlapping slots it moves the phone
# between them and the Android Auto session breaks.
usb=(-device qemu-xhci,id=xhci,p2=8,p3=8 -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0)
if [ "$PHONES" = 1 ]; then
  for id in 18d1:2d00 18d1:2d01 18d1:4ee1 18d1:4ee2 ${PHONE//,/ }; do
    usb+=(-device "usb-host,bus=xhci.0,vendorid=0x${id%:*},productid=0x${id#*:}")
  done
fi

# Sound through the host's PipeWire; without it (CI) the guest still has its sound card
audio=none
[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ] && audio=pipewire

extra=()
if [ -n "$ETH2" ]; then
  # its own MAC per instance (the same on every start): the VMs on one cable must differ
  mac="$(printf '%s' "$VM" | md5sum | sed -E 's/^(..)(..)(..).*/52:54:01:\1:\2:\3/')"
  extra+=(-netdev "socket,id=net1,mcast=230.0.0.1:$ETH2,localaddr=127.0.0.1" -device "virtio-net-pci,netdev=net1,mac=$mac")
fi
# Extra kernel command line for the guest (one SMBIOS string, read by the UKI's systemd-stub)
cmdline=()
[ "$WIFI" = 1 ] && cmdline+=(modules_load=mac80211_hwsim mac80211_hwsim.radios=1)

# Plugins checkout shared into the guest (9p, mount tag "plugins"); skipped if the folder does not exist
if [ -n "$PLUGINS" ] && [ -d "$PLUGINS" ]; then
  echo "Sharing $(realpath "$PLUGINS") into the VM (mount tag: plugins)"
  extra+=(-virtfs "local,id=plugins,path=$(realpath "$PLUGINS"),mount_tag=plugins,security_model=none")
  cmdline+=("systemd.mount-extra=plugins:/var/lib/openhu/.openhu/plugins:9p:trans=virtio,version=9p2000.L,msize=1048576,nofail")
elif [ -n "$PLUGINS" ] && [ "$PLUGINS" != "$REPO/../openhu-plugins" ]; then
  echo "--plugins: $PLUGINS is not a directory" >&2; exit 1
fi

# shared helpers (openhu.py) sit next to plugins/ in the repo; mounted as a sibling in the guest
if [ -d "$PLUGINS/../common" ]; then
  echo "Sharing $(realpath "$PLUGINS/../common") into the VM (mount tag: common)"
  extra+=(-virtfs "local,id=common,path=$(realpath "$PLUGINS/../common"),mount_tag=common,security_model=none,readonly=on")
  cmdline+=("systemd.mount-extra=common:/var/lib/openhu/.openhu/common:9p:trans=virtio,version=9p2000.L,msize=1048576,nofail")
fi

if [ ${#cmdline[@]} -gt 0 ]; then
  cmdline_str="${cmdline[*]}"
  extra+=(-smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=${cmdline_str//,/,,}")
fi

exec "$QEMU" -name openhu-os -nodefaults "${machine[@]}" -smp 4 -m 4096 -uuid "$VM_UUID" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$VM/OVMF_VARS.fd" \
  -drive if=none,id=disk0,format=raw,file="$VM/disk.raw",cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=disk0,bootindex=1 \
  "${display[@]}" "${usb[@]}" "${extra[@]}" \
  -audiodev "$audio,id=snd0" -device intel-hda -device hda-duplex,audiodev=snd0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56 \
  -device virtio-rng-pci \
  -qmp unix:"$VM/qmp.sock",server=on,wait=off \
  -pidfile "$VM/qemu.pid" -serial mon:stdio
