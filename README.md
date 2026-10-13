# OpenHU OS

Minimal Linux images for [OpenHU](https://github.com/average-web-dev/openhu), the open head unit for
Raspberry Pi and Linux. Flash it, boot it, and OpenHU starts.

> [!NOTE]
> Work in progress: x86_64 (UEFI) images, developed in a VM. Raspberry Pi later.

## What is in the image

- **Base:** Debian 13 "trixie" (minimal, no apt in the image: it is updated as a whole; calls itself "OpenHU OS
  <version>" in the boot menu and os-release, `ID=debian` stays), built with
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
- **Audio:** PipeWire as the `openhu` user (lingering), realtime priority through rtkit, `pactl` works for OpenHU
- **Network:** NetworkManager (also the wireless Android Auto hotspot), BlueZ
- **Journal:** in RAM only (32 MB)
- **Boot splash:** Plymouth with the OpenHU logo on the shell's background (`splash/`), from early in the initrd until
  cage takes over the display. The images are rendered by `splash/make-images.sh`; replace `splash/theme/logo.png`
  with a real logo any time. `scripts/build.sh` packages the theme as `openhu-os-splash`.
- **Small initrd:** only the modules mkosi's initrd needs (54 MB unified kernel image instead of 136 MB)

- **A/B updates:** `openhu update` writes a new version into the other root slot and its unified kernel image into
  the ESP with three boot tries (systemd-boot boot counting). The new version is kept when OpenHU comes up
  (`openhu-boot-check.service`, then `systemd-bless-boot`); after three failed tries systemd-boot boots the version
  before again. A power cut during an update leaves the running version bootable. No automatic updates: Install in
  OpenHU (Settings → System) or `openhu update install` starts one, online or from a USB stick.
  The splash says when a new version is being tried ("try 1 of 3") and when a failed update was rolled back;
  `/run/openhu-os/boot-status.json` has the same for OpenHU (`normal`, `trial`, `updated` once the new version
  passed its boot check, `rollback`).

- **USB sticks:** mounted read-only under `/run/media/<name>` while plugged in (FAT32, exFAT, NTFS, ext4); a power cut
  or pulling the stick never harms it. Updates from a stick, see below.

Planned ([roadmap](https://github.com/average-web-dev/openhu/issues/1)): signed checksums
([#21](https://github.com/average-web-dev/openhu-os/issues/21)), Raspberry Pi 4/5.

## The openhu command

One command for the system, the settings of OpenHU and the running OpenHU (through its API on
`ws://127.0.0.1:<api port>`); Tab completes commands and, live from OpenHU, setting keys, pages, actions and plugins:

```bash
openhu help                         # all commands; openhu help <command> explains one
openhu status                       # OS version and update slots, OpenHU, Android Auto, WiFi, volume
openhu update check | install [--reboot] | status | cancel
openhu ssh status | on | off | password [--clear]
openhu time status | zone Europe/Berlin | zones | ntp on|off | set "2026-10-13 14:30"
openhu config list [prefix] | keys | get aa.fps | set aa.fps 60     # says when a reconnect or restart is needed
openhu page settings/system         # like tapping the dock: home, aa, settings[/<category>], store, plugin:<id>
openhu action media.next            # like a steering wheel button; openhu action --list
openhu volume 40 | +5 | -5 | mute   # openhu toast "Hello", openhu daynight auto|day|night
openhu plugin list | restart <id>   # openhu store list | install <id>, openhu bt devices, openhu wifi list | scan
openhu api volume.set '{"value": 40}'   # any API method; openhu api methods
openhu watch nav.* media.metadata   # events live
openhu log | restart                # OpenHU's log (journal of openhu-session), restart it
```

`--json` gives every command's result as JSON for scripts; errors end with exit code 1 (`{"error": ...}`). Without
a running OpenHU the system commands still work, the others say so. The system commands (`update`, `ssh`, `time`,
`restart`) need root: the `openhu` user runs them through `pkexec` (the polkit rule allows exactly these, OpenHU's
settings use them so), `openhu` does that by itself. The work is done by helpers in `/usr/libexec/openhu-os`
(`openhu-update`, `openhu-ssh`, `openhu-time`), which are not meant to be called directly.

## ssh

Off in the release image. OpenHU switches it on and sets root's password
([openhu#29](https://github.com/average-web-dev/openhu/issues/29)) with `openhu ssh`:

```bash
openhu ssh status --json                   # {"enabled", "running", "password", "keys"}
echo 'secret-password' | openhu ssh password   # at least 8 characters (asked twice on a terminal)
openhu ssh on                              # now and at every boot; off switches it off
```

Everything is on the data partition (`/etc` is read-only): the switch `/var/lib/openhu-os/ssh/enabled`, the
password hash (yescrypt) for `pam_pwdfile`, keys in `/var/lib/openhu-os/ssh/authorized_keys`, and the host keys,
which every device creates on the first start of sshd. sshd listens on every network, the phone's hotspot too.
After the login a greeting shows the version, the result of the last update and the most useful commands
(`/etc/update-motd.d/10-openhu-os`).

## Time zone, date and time

Set in OpenHU (Settings → System, [openhu#36](https://github.com/average-web-dev/openhu/issues/36)) with
`openhu time`:

```bash
openhu time status --json            # {"zone", "ntp", "synchronized", "time"}
openhu time zone Europe/Berlin       # applies at once, also to running programs
openhu time ntp off                  # time from the internet (systemd-timesyncd) off
openhu time set "2026-10-13 14:30"   # local time (or seconds since 1970), only with ntp off
```

`/etc/localtime` links to `/var/lib/openhu-os/time/localtime`, which links to the zone (UTC until one is
chosen). glibc and Qt follow both links; `timedatectl` does not and shows the zone as "n/a", `date` and
`openhu time` show it right. Time from the internet is on by default; switched off, the flag
`/var/lib/openhu-os/time/ntp-off` keeps systemd-timesyncd from starting. Setting the time also sets the hardware
clock. A Raspberry Pi 4 has none: after a power cut without internet it starts at the last time systemd saved.

## Releases

[GitHub releases](https://github.com/average-web-dev/openhu-os/releases): `openhu-os_<version>.raw.xz` to flash
(`xz -d`, then `dd` or balenaEtcher; grows to the whole disk on the first boot), the update for `openhu update`
(`openhu-os_<version>.root.raw.gz`, `openhu-os_<version>.efi`), the package manifest and `SHA256SUMS`.

### Update from a USB stick

A head unit usually has no internet. Copy the update files of a release to a USB stick on any computer:

```
SHA256SUMS
openhu-os_<version>.root.raw.gz
openhu-os_<version>.efi
```

into the stick's top folder or into `openhu-os/` (several versions: one folder each below `openhu-os/`, the newest
wins). FAT32, exFAT, NTFS or ext4. Plug it in: OpenHU shows "OpenHU OS <version> on the USB stick – tap to install",
Settings → System has the Install button. Leave the stick plugged in until the update is installed; pulled out
earlier, the update stops and the running version stays.

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
| Tools | `grim` (screenshots), strace, libinput-tools, … | none (`openhu` in both) |

## Run in a VM

```bash
scripts/run-vm.sh --fresh       # new VM disk from the newest image, window with 3D
scripts/ssh.sh                  # root shell in the VM
scripts/ssh.sh openhu status
scripts/screenshot.sh           # vm/screen.png (grim in the guest)
```

`run-vm.sh` options: `--ui sdl|gtk|x11` (window, default SDL), `--headless` (no window; GL via egl-headless),
`--no-gl` (no 3D: cage renders with pixman, Qt with llvmpipe, slow video; the QEMU window then lags one frame
behind, the guest itself is fine), `--res WxH` (the GTK window reports its own size instead), `--phone VID:PID,...`
(more phones to pass through, ids from `lsusb`), `--wifi` (a virtual WiFi card, `mac80211_hwsim`, on every boot).

The dev image lets cage draw the mouse cursor itself (`WLR_NO_HARDWARE_CURSORS=1`): the cursor plane of QEMU's
virtio GPU shows the pointer about 64 px too low, so every click seemed to land above the cursor.

The VM disk (`vm/disk.raw`, 16 GB sparse) keeps its data until `--fresh`.

### Updates

```bash
scripts/build.sh --version 2026.10.13.1        # a newer version
scripts/add-update.sh                          # newest build into mkosi.output/updates (root partition, UKI, SHA256SUMS)
scripts/serve-updates.sh                       # http://127.0.0.1:8070, the dev image's update server
scripts/ssh.sh openhu update check
scripts/ssh.sh openhu update install --reboot
scripts/ssh.sh openhu update status            # slots and boot entries: good, n tries left, failed
```

A USB stick for the running VM (`--instance NAME` for a second VM):

```bash
scripts/add-update.sh 2026.10.13.1 /tmp/stick/openhu-os   # the update files of a version into a folder
scripts/usb-stick.sh plug /tmp/stick                      # FAT32 image vm/stick.img from it, plugged in (--fs ext4)
scripts/usb-stick.sh pull
```

`run-vm.sh --fresh --image mkosi.output/openhu-os_<version>.raw` starts from an older version. Debian has no
`systemd-sysupdate`, so `openhu update` (helper `/usr/libexec/openhu-os/openhu-update`, Python) does the job,
always in the background as `openhu-update.service` (survives a closed ssh connection and OpenHU restarts;
`install` shows the progress until it is done, Ctrl+C only stops watching):

1. removes the boot entry of the version in the other slot and labels the slot `_empty`
2. streams `openhu-os_<version>.root.raw.gz` into the slot, checks the SHA-256, labels it `openhu_<version>`
3. writes `EFI/Linux/openhu-os_<version>+3.efi` (checked, then renamed)

Release images use the newest GitHub release (`/usr/lib/openhu-os/update.conf`, override in
`/var/lib/openhu-os/update.conf`). The download is checked against `SHA256SUMS` over HTTPS, not signed yet
([#21](https://github.com/average-web-dev/openhu-os/issues/21)).

USB sticks are a second source (`openhu-usb@<name>.service`, started by udev, mounts them and runs
`openhu-update scan`). `check` and `install` take the newest version of both, the stick on a tie; without internet a
stick is enough (`server_error` in `check --json`). A stick pulled during the update: error "the USB stick was
removed", the slot is empty again.

**For OpenHU** (the update button, [openhu#28](https://github.com/average-web-dev/openhu/issues/28)), in JSON:

```bash
openhu update status --json                    # running, other, entries (good/trying/failed), update, active, usb
openhu update check --json                     # {"current", "newest", "available", "source": "usb" | "online"}
openhu update install --no-wait --json         # starts openhu-update.service and returns ({"started": true})
openhu update cancel --json                    # the slot is empty again, the running version stays
cat /run/openhu-os/update.json                 # progress, no root needed
cat /run/openhu-os/usb-update.json             # newest version on the sticks: {"current", "version", "newer", "path"}
```

`update.json`: `{"state": "checking" | "installing" | "done" | "uptodate" | "error" | "cancelled", "from", "version",
"source": "usb" | "online", "phase": "root" | "kernel", "percent", "error"}` (percent over both, the root partition is 0–90). After `done`
OpenHU reboots through logind; after the reboot `/run/openhu-os/boot-status.json` says `updated` or, if the new version
did not come up, `rollback`. Errors: exit code 1 and `{"error": "..."}`.

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
mkosi.extra/                files in the image: session unit, sysusers, PAM, polkit, presets, journald, the openhu
                            command and its helpers, first boot partitions (usr/lib/repart.d: slot B, data), fstab for /var,
                            boot check, USB sticks (udev rule, openhu-usb@.service)
mkosi.postinst.chroot       users, masks the package's openhu.service (root, eglfs) until openhu#8
mkosi.finalize              empty machine id (read-only /etc)
scripts/                    build, fetch-debs, run-vm, ssh, screenshot, powerloss-test, update-test, add-update,
                            serve-updates, release, usb-stick
.github/workflows/image.yml CI: build, VM test, release on tags
host/                       udev rule for the development host
```

## Related

- [openhu](https://github.com/average-web-dev/openhu) – the head unit application
- [openhu-plugins](https://github.com/average-web-dev/openhu-plugins) – official plugins
- [aasdk](https://github.com/average-web-dev/aasdk/tree/openhu) – Android Auto SDK (OpenHU fork)
