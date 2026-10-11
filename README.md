# OpenHU OS

Minimal Linux images for [OpenHU](https://github.com/average-web-dev/openhu), the open head unit for
Raspberry Pi and Linux. Flash it, boot it, and OpenHU starts.

> [!NOTE]
> Work in progress. There are no images yet.

## Plan

- **Base:** Debian 13 "trixie" (minimal), the same base OpenHU is built and tested on
- **Targets:** Raspberry Pi 4/5 (arm64, `.img` for SD card/USB) and x86_64 (`.iso` / live USB)
- **Contents:** OpenHU and aasdk from the OpenHU APT repository, Qt with eglfs (no desktop), PipeWire, BlueZ,
  NetworkManager
- **Robust in the car:** read-only root filesystem, separate partition for settings, plugins and logs

Roadmap: [average-web-dev/openhu#1](https://github.com/average-web-dev/openhu/issues/1)

## Related

- [openhu](https://github.com/average-web-dev/openhu) – the head unit application
- [openhu-plugins](https://github.com/average-web-dev/openhu-plugins) – official plugins
- [aasdk](https://github.com/average-web-dev/aasdk/tree/openhu) – Android Auto SDK (OpenHU fork)
