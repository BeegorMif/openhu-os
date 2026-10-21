# Raspberry Pi 4B ARM64 image (UEFI bring-up)

The ARM64 image uses the Debian `arm64` kernel and systemd-boot. It is not a native Raspberry Pi firmware image yet.
The Pi's EEPROM firmware must first start the community Raspberry Pi 4 UEFI firmware; the UEFI firmware then starts
OpenHU OS from a second drive. This keeps the current UEFI, unified kernel image, and systemd-boot A/B scheme.

## Build

The OpenHU and libaasdk packages must both be built for ARM64. OpenHU's CI publishes the matching packages in its
`openhu-arm64` artifact. On a Pi or another ARM64 Debian machine:

```bash
scripts/fetch-debs.sh --arch arm64
scripts/build.sh --profile release --architecture arm64 --version 1.0
scripts/release.sh 1.0 dist
```

To use packages you built locally, pass their directory to `fetch-debs.sh`:

```bash
scripts/fetch-debs.sh --arch arm64 --dir /path/to/arm64/debs
```

That directory must contain matching `openhu_*_arm64.deb` and `libaasdk_*_arm64.deb` files. The ARM64 image job in
GitHub Actions builds a release artifact on a native ARM64 runner; it does not publish ARM64 files into the x86-64
release yet.

## Boot on a Pi 4B

Use two storage devices for this bring-up:

1. Prepare a small SD card for the Pi UEFI firmware. Follow the installation instructions in the
   [PFTF Raspberry Pi 4 UEFI firmware project](https://github.com/pftf/RPi4): use an MBR partition table with a FAT16
   or FAT32 EFI partition (type `0xef`) and extract the firmware archive to its root. This firmware is third-party
   and is not bundled in OpenHU OS.
2. Write `openhu-os_1.0.raw.xz` (or the version you built) to a separate USB drive. This erases the selected drive.
3. Insert both devices, power on, enter the UEFI setup if needed, and choose the OpenHU OS USB drive. USB boot from
   the UEFI firmware requires a sufficiently recent Pi EEPROM; update the EEPROM if the drive is not listed.

The PFTF firmware currently enables ACPI and limits visible RAM to 3 GB by default. Its setup utility can change
those settings. OpenHU OS ARM64 still needs validation on Pi hardware, particularly display acceleration, Wi-Fi,
Bluetooth, and USB Android Auto; a successful ARM64 image build alone does not confirm those peripherals work.

## Updates

The updater recognizes the ARM64 GPT root partition type and uses the same systemd-boot UKI try-counting process as
x86-64. During bring-up, keep ARM64 update files on an ARM64-only update source: the current release naming does not
yet distinguish x86-64 and ARM64 assets in one shared update directory or GitHub release.
