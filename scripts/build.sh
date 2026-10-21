#!/usr/bin/env bash
# Builds the OpenHU OS image with mkosi in a Debian trixie container. The image lands in mkosi.output/.
#
#   scripts/build.sh [--profile dev|release] [--architecture x86-64|arm64] [--version VERSION] [extra mkosi arguments]
#
# Needs the openhu and libaasdk packages in packages/ (scripts/fetch-debs.sh). The package cache and the
# incremental base image live in the Docker volume openhu-os-cache.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="openhu-os-builder:trixie"
PROFILE="dev"
ARCHITECTURE="x86-64"
# dots only: "_", "-" and "+" have a meaning in the update and boot counting file names
VERSION="${OPENHU_OS_VERSION:-$(date -u +%Y.%m.%d.%H%M)}"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --architecture|--arch) ARCHITECTURE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

case "$ARCHITECTURE" in
  x86-64) DEB_ARCH=amd64 ;;
  arm64) DEB_ARCH=arm64 ;;
  *) echo "unsupported architecture '$ARCHITECTURE' (use x86-64 or arm64)" >&2; exit 2 ;;
esac

cd "$REPO"
if ! ls packages/openhu_*_"$DEB_ARCH".deb packages/libaasdk_*_"$DEB_ARCH".deb >/dev/null 2>&1; then
  echo "packages/ needs openhu and libaasdk .deb files for $DEB_ARCH: run scripts/fetch-debs.sh --arch $DEB_ARCH" >&2
  exit 1
fi

# Builder image, rebuilt when its Dockerfile changes
hash="$(sha256sum docker/builder.Dockerfile | cut -c1-16)"
if [ "$(docker image inspect -f '{{index .Config.Labels "openhu-os.hash"}}' "$IMAGE" 2>/dev/null)" != "$hash" ]; then
  docker build --label openhu-os.hash="$hash" -t "$IMAGE" -f docker/builder.Dockerfile docker
fi

# Boot splash (Plymouth theme in splash/) as a package next to openhu and libaasdk: it is needed in the initrd too
stage="$(mktemp -d)"
splash_version="$(git log -1 --format=%cd --date=format:%Y.%m.%d.%H%M -- splash 2>/dev/null)"
[ -n "$splash_version" ] || splash_version="$(date -u +%Y.%m.%d.%H%M)"
install -Dm644 -t "$stage/usr/share/plymouth/themes/openhu" splash/theme/*
install -Dm755 splash/postinst "$stage/DEBIAN/postinst"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: openhu-os-splash
Version: $splash_version
Architecture: all
Maintainer: OpenHU <https://github.com/BeegorMif/openhu-os>
Depends: plymouth
Section: misc
Priority: optional
Description: OpenHU boot splash
 Plymouth theme: the OpenHU logo until OpenHU shows its first frame.
CONTROL
rm -f packages/openhu-os-splash_*.deb
dpkg-deb --root-owner-group -Zxz -b "$stage" packages/ >/dev/null
rm -rf "$stage"

# ssh key of the dev VM (scripts/ssh.sh), generated once, only for root login in dev images
mkdir -p local/dev-extra/root/.ssh
[ -f local/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "openhu-os dev VM" -f local/id_ed25519
cp local/id_ed25519.pub local/dev-extra/root/.ssh/authorized_keys
chmod 700 local/dev-extra/root/.ssh
chmod 600 local/dev-extra/root/.ssh/authorized_keys

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)
echo "Building OpenHU OS $VERSION (profile $PROFILE, architecture $ARCHITECTURE)"
# mkosi needs mount namespaces and its own /proc in the container
docker run --rm "${tty[@]}" --privileged \
  -v "$REPO:/src" -w /src \
  -v openhu-os-cache:/cache \
  "$IMAGE" bash -euo pipefail -c '
    architecture_repositories=()
    [ "$3" = arm64 ] && architecture_repositories=(--repositories=non-free-firmware)
    mkosi --architecture="$3" "${architecture_repositories[@]}" --profile="$1" --image-version="$2" \
          --cache-directory=/cache/incremental --package-cache-directory=/cache/packages \
          --workspace-directory=/cache/workspace "${@:5}" -f build
    chown -R "$4" mkosi.output' _ "$PROFILE" "$VERSION" "$ARCHITECTURE" "$(id -u):$(id -g)" "${EXTRA[@]}"

ls -lh mkosi.output/openhu-os_"$VERSION"*.raw
