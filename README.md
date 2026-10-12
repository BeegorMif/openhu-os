# OpenHU OS

Minimal Linux images for [OpenHU](https://github.com/average-web-dev/openhu), the open head unit for
Raspberry Pi and Linux. Flash it, boot it, and OpenHU starts.

> [!NOTE]
> Work in progress: there is an x86_64 image for development in a VM. No releases yet, Raspberry Pi later.

## What is in the image

- **Base:** Debian 13 "trixie" (minimal, no apt in the image: it is updated as a whole), built with
  [mkosi](https://github.com/systemd/mkosi)
- **Boot:** UEFI, systemd-boot, unified kernel image; no boot messages, about 4 s to OpenHU in the VM
- **Display:** OpenHU in the [cage](https://github.com/cage-kiosk/cage) Wayland kiosk compositor on tty1
  (`openhu-session.service`), no desktop. Debian's Qt 6 has no eglfs.
- **User:** `openhu` (UID 900), home `/var/lib/openhu` with `openhu.ini` and `~/.openhu` (plugins, logs)
- **Audio:** PipeWire as the `openhu` user (lingering), `pactl` works for OpenHU
- **Network:** NetworkManager (also the wireless Android Auto hotspot), BlueZ
- **Journal:** in RAM only (32 MB)

Planned ([roadmap](https://github.com/average-web-dev/openhu/issues/1)): read-only root with a separate data
partition, A/B updates with automatic rollback, CI releases, Raspberry Pi 4/5.

## Build

Needs Docker, the GitHub CLI (`gh`, for the packages) and, for the VM, QEMU with KVM and OVMF.

```bash
scripts/fetch-debs.sh           # openhu + libaasdk from the newest openhu CI build into packages/
scripts/build.sh                # dev image (default) into mkosi.output/
scripts/build.sh --profile release
```

mkosi runs in a Debian trixie container (`docker/builder.Dockerfile`, `--privileged`). The package cache and the
cached base image are in the Docker volume `openhu-os-cache`: after the first build, a new openhu package takes about
3 minutes.

Profiles:

| | dev | release |
|---|---|---|
| ssh | root with the key in `local/id_ed25519` (`scripts/ssh.sh`), password `openhu` | no |
| Console | serial (`ttyS0`), Ctrl+Alt+F2 switches away from cage | none |
| Tools | `openhu-api`, `grim` (screenshots), strace, libinput-tools, … | none |

## Run in a VM

```bash
scripts/run-vm.sh --fresh       # new VM disk from the newest image, window with 3D
scripts/ssh.sh                  # root shell in the VM
scripts/ssh.sh openhu-api system.ping
scripts/screenshot.sh           # vm/screen.png (grim in the guest)
```

`run-vm.sh` options: `--ui sdl|gtk|x11` (window, default SDL), `--headless` (no window; GL via egl-headless),
`--no-gl` (no 3D: cage renders with pixman, Qt with llvmpipe, slow video; the QEMU window then lags one frame
behind, the guest itself is fine), `--res WxH` (the GTK window reports its own size instead), `--phone VID:PID,...`
(more phones to pass through, ids from `lsusb`).

The dev image lets cage draw the mouse cursor itself (`WLR_NO_HARDWARE_CURSORS=1`): the cursor plane of QEMU's
virtio GPU shows the pointer about 64 px too low, so every click seemed to land above the cursor.

The VM disk (`vm/disk.raw`, 16 GB sparse) keeps its data until `--fresh`.

### Android Auto in the VM (USB)

Google's USB ids `18d1:4ee1`/`4ee2` (Pixel, Fairphone) and `18d1:2d00`/`2d01` (every phone in accessory mode) are
passed through to the VM, other phones with `--phone`.
QEMU needs access to the phone on the host, once:

```bash
sudo cp host/70-openhu-os-vm.rules /etc/udev/rules.d/ && sudo udevadm control --reload
```

The phone must be connected with a **USB 2.0** link (a USB 2.0 cable or port): some phones cannot do accessory mode
over USB 3 ([openhu#24](https://github.com/average-web-dev/openhu/issues/24)). Stop other OpenHU instances on the
host first (e.g. the openhu dev container), they would grab the phone.

## Layout

```
mkosi.conf, mkosi.conf.d/   distribution, packages (base, session, openhu, kernel)
mkosi.profiles/             dev and release
mkosi.extra/                files in the image: session unit, sysusers, PAM, polkit, presets, journald, openhu-api
mkosi.postinst.chroot       users, masks the package's openhu.service (root, eglfs) until openhu#8
scripts/                    build, fetch-debs, run-vm, ssh, screenshot
host/                       udev rule for the development host
```

## Related

- [openhu](https://github.com/average-web-dev/openhu) – the head unit application
- [openhu-plugins](https://github.com/average-web-dev/openhu-plugins) – official plugins
- [aasdk](https://github.com/average-web-dev/aasdk/tree/openhu) – Android Auto SDK (OpenHU fork)
