# OpenHU OS

Minimal Linux images for [OpenHU](https://github.com/average-web-dev/openhu), the open head unit for
Raspberry Pi and Linux. Flash it, boot it, and OpenHU starts.

> [!NOTE]
> Work in progress: x86_64 (UEFI) images, developed in a VM. Raspberry Pi later.

## What is in the image

- **Base:** Debian 13 "trixie" (minimal, no apt in the image: it is updated as a whole), built with
  [mkosi](https://github.com/systemd/mkosi)
- **Boot:** UEFI, systemd-boot, unified kernel image; no boot messages, about 4 s to OpenHU in the VM
- **Read-only root:** erofs (lz4hc, about 600 MB) in a fixed 3 GB slot labelled `openhu_<version>`; the unified kernel
  image boots exactly that slot (`root=PARTLABEL=openhu_<version>`). `/etc` is part of it, the machine id is transient.
- **Data partition:** `openhu-data` (ext4) on `/var`, created by systemd-repart on the first boot together with the
  empty second root slot (`_empty`, for A/B updates), takes the rest of the disk. Everything that changes lives
  there: OpenHU's settings and plugins, PipeWire state, NetworkManager connections, Bluetooth pairings. fsck repairs
  it after a power cut.
- **Display:** OpenHU in the [cage](https://github.com/cage-kiosk/cage) Wayland kiosk compositor on tty1
  (`openhu-session.service`), no desktop. Debian's Qt 6 has no eglfs.
- **User:** `openhu` (UID 900), home `/var/lib/openhu` with `openhu.ini` and `~/.openhu` (plugins, logs)
- **Audio:** PipeWire as the `openhu` user (lingering), `pactl` works for OpenHU
- **Network:** NetworkManager (also the wireless Android Auto hotspot), BlueZ
- **Journal:** in RAM only (32 MB)
- **Boot splash:** Plymouth with the OpenHU logo on the shell's background (`splash/`), from early in the initrd until
  cage takes over the display. The images are rendered by `splash/make-images.sh`; replace `splash/theme/logo.png`
  with a real logo any time. `scripts/build.sh` packages the theme as `openhu-os-splash`.
- **Small initrd:** only the modules mkosi's initrd needs (54 MB unified kernel image instead of 136 MB)

- **A/B updates:** `openhu-update` writes a new version into the other root slot and its unified kernel image into
  the ESP with three boot tries (systemd-boot boot counting). The new version is kept when OpenHU comes up
  (`openhu-boot-check.service`, then `systemd-bless-boot`); after three failed tries systemd-boot boots the version
  before again. A power cut during an update leaves the running version bootable. No automatic updates: only
  `openhu-update update` (later a button in OpenHU, openhu#28) starts one.
  The splash says when a new version is being tried ("Versuch 1 von 3") and when a failed update was rolled back;
  `/run/openhu-os/boot-status.json` has the same for OpenHU (`normal`, `trial`, `updated` once the new version
  passed its boot check, `rollback`).

Planned ([roadmap](https://github.com/average-web-dev/openhu/issues/1)): update from the OpenHU settings
([openhu#28](https://github.com/average-web-dev/openhu/issues/28)), signed checksums, Raspberry Pi 4/5.

## ssh

Off in the release image. OpenHU switches it on and sets root's password
([openhu#29](https://github.com/average-web-dev/openhu/issues/29)) through a small helper that the `openhu` user may
run as root with `pkexec` (polkit rule, this program only):

```bash
pkexec /usr/libexec/openhu-os/openhu-ssh status        # {"enabled", "running", "password", "keys"}
echo 'secret-password' | pkexec /usr/libexec/openhu-os/openhu-ssh password   # at least 8 characters
pkexec /usr/libexec/openhu-os/openhu-ssh enable        # now and at every boot; disable switches it off
```

Everything is on the data partition (`/etc` is read-only): the switch `/var/lib/openhu-os/ssh/enabled`, the
password hash (yescrypt) for `pam_pwdfile`, keys in `/var/lib/openhu-os/ssh/authorized_keys`, and the host keys,
which every device creates on the first start of sshd. sshd listens on every network, the phone's hotspot too.

## Releases

[GitHub releases](https://github.com/average-web-dev/openhu-os/releases): `openhu-os_<version>.raw.xz` to flash
(`xz -d`, then `dd` or balenaEtcher; grows to the whole disk on the first boot), the update for `openhu-update`
(`openhu-os_<version>.root.raw.gz`, `openhu-os_<version>.efi`), the package manifest and `SHA256SUMS`.

The workflow `.github/workflows/image.yml` runs on every push and pull request: newest OpenHU from its CI, dev image,
three power cuts in a VM (KVM on the runner, no GPU: `--no-gl`), release image, which must show the OpenHU shell
in a VM (`scripts/release-smoke-test.sh`, a screenshot check: ssh is off in a fresh release image). A tag `v<version>` (digits and dots,
e.g. `v2026.10.13`) publishes the release; release images update from `releases/latest/download/`.

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
| ssh | always on: root with the key in `local/id_ed25519` (`scripts/ssh.sh`), password `openhu` | off until switched on in OpenHU (below) |
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

### Updates

```bash
scripts/build.sh --version 2026.10.13.1        # a newer version
scripts/add-update.sh                          # newest build into mkosi.output/updates (root partition, UKI, SHA256SUMS)
scripts/serve-updates.sh                       # http://127.0.0.1:8070, the dev image's update server
scripts/ssh.sh openhu-update check
scripts/ssh.sh openhu-update update --reboot
scripts/ssh.sh openhu-update status            # slots and boot entries: good, n tries left, failed
```

`run-vm.sh --fresh --image mkosi.output/openhu-os_<version>.raw` starts from an older version. Debian has no
`systemd-sysupdate`, so `openhu-update` (`/usr/libexec/openhu-os`, Python) does the job:

1. removes the boot entry of the version in the other slot and labels the slot `_empty`
2. streams `openhu-os_<version>.root.raw.gz` into the slot, checks the SHA-256, labels it `openhu_<version>`
3. writes `EFI/Linux/openhu-os_<version>+3.efi` (checked, then renamed)

Release images use the newest GitHub release (`/usr/lib/openhu-os/update.conf`, override in
`/var/lib/openhu-os/update.conf`). The download is checked against `SHA256SUMS` over HTTPS, not signed yet.

`scripts/update-test.sh` runs the whole story in a second VM (`vm/updatetest/`, ssh 2224, update server 8071):
builds versions 1, 2 and a broken 3 (OpenHU masked), updates 1 → 2 (setting kept, marked good), cuts the power
while the next update writes the root partition (2 still boots, slot empty again) and installs 3 (three failed
tries, back on 2). About 6 minutes plus the builds; `scripts/update-test.sh V1 V2 V3` reuses builds.

### Power cut test

```bash
scripts/powerloss-test.sh 10    # 10 power cuts, about 30 s each
```

Boots a second VM (`vm/powerloss/`, headless, no phone, ssh on port 2223; the dev VM may keep running) and kills
QEMU at a random moment: first during the first boot (systemd-repart at work), then while OpenHU rewrites its plugin
sources and a file writer syncs to `/var`. Before each cut it saves a volume and a plugin source; after each boot
OpenHU must answer within 90 s with both still there, the official plugin source intact and no failed units.

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
mkosi.repart/               partitions of the image: ESP, root slot A (erofs, also split out as the update)
mkosi.extra/                files in the image: session unit, sysusers, PAM, polkit, presets, journald, openhu-api,
                            first boot partitions (usr/lib/repart.d: slot B, data), fstab for /var, openhu-update,
                            boot check
mkosi.postinst.chroot       users, masks the package's openhu.service (root, eglfs) until openhu#8
mkosi.finalize              empty machine id (read-only /etc)
scripts/                    build, fetch-debs, run-vm, ssh, screenshot, powerloss-test, update-test, add-update,
                            serve-updates, release
.github/workflows/image.yml CI: build, VM test, release on tags
host/                       udev rule for the development host
```

## Related

- [openhu](https://github.com/average-web-dev/openhu) – the head unit application
- [openhu-plugins](https://github.com/average-web-dev/openhu-plugins) – official plugins
- [aasdk](https://github.com/average-web-dev/aasdk/tree/openhu) – Android Auto SDK (OpenHU fork)
