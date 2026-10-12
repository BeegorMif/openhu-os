# Build environment for the OpenHU OS images (scripts/build.sh): mkosi from Debian trixie, the same release the
# images are based on. reprepro is needed for the local package directory (PackageDirectories=), mkosi does not
# depend on it.
FROM debian:trixie-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        mkosi \
        reprepro \
        debian-archive-keyring \
        ca-certificates \
        xz-utils \
        zstd \
        git \
    && rm -rf /var/lib/apt/lists/*
