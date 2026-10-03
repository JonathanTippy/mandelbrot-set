#!/usr/bin/env bash
# Build an amd64/host-arch .deb of Critical Zoomer from the repo root.
# Usage: scripts/build_deb.sh [output.deb]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/cz_cursor_cargo_target}"

n=$(nproc)
start=$((n / 4))
end=$((start + n / 2 - 1))

VERSION=$(awk -F '"' '/^version = / { print $2; exit }' "$ROOT/Cargo.toml")
ARCH=$(dpkg --print-architecture)
OUT="${1:-$ROOT/packaging/critical-zoomer_${VERSION}_${ARCH}.deb}"

taskset -c "${start}-${end}" nice -n 10 \
  cargo build --release --manifest-path "$ROOT/Cargo.toml" --bin critical_zoomer

BIN="$CARGO_TARGET_DIR/release/critical_zoomer"
test -x "$BIN"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/pkg"

install -Dm755 "$BIN" "$DEST/usr/bin/critical_zoomer"
strip --strip-unneeded "$DEST/usr/bin/critical_zoomer"
install -Dm644 "$ROOT/packaging/critical-zoomer.desktop" \
  "$DEST/usr/share/applications/com.criticalzoomer.CriticalZoomer.desktop"
install -Dm644 "$ROOT/icons/assembly_chain_crosshair.png" \
  "$DEST/usr/share/icons/hicolor/512x512/apps/com.criticalzoomer.CriticalZoomer.png"
install -Dm644 "$ROOT/packaging/com.criticalzoomer.CriticalZoomer.metainfo.xml" \
  "$DEST/usr/share/metainfo/com.criticalzoomer.CriticalZoomer.metainfo.xml"

# Shared-library Depends via dpkg-shlibdeps (needs a stub source tree).
mkdir -p "$STAGE/src/debian/critical-zoomer/usr/bin"
cp "$DEST/usr/bin/critical_zoomer" "$STAGE/src/debian/critical-zoomer/usr/bin/"
cat > "$STAGE/src/debian/control" <<EOF
Source: critical-zoomer
Maintainer: Jonathan Tippy <jonathan@localhost>
Standards-Version: 4.6.2

Package: critical-zoomer
Architecture: $ARCH
Depends: \${shlibs:Depends}
Description: GPU-accelerated Mandelbrot set explorer
 Critical Zoomer.
EOF
(
  cd "$STAGE/src"
  dpkg-shlibdeps -Tdebian/substvars debian/critical-zoomer/usr/bin/critical_zoomer
)
SHLIBS=$(sed -n 's/^shlibs:Depends=//p' "$STAGE/src/debian/substvars")
# wgpu/eframe dlopen these; they will not show up in ldd.
for extra in \
  "libvulkan1 | vulkan-loader" \
  libwayland-client0 \
  libx11-6 \
  libxkbcommon0 \
  "libegl1 | libgl1"
do
  case ", $SHLIBS, " in
    *", ${extra}, "*) ;;
    *) SHLIBS="${SHLIBS}, ${extra}" ;;
  esac
done

SIZE=$(du -sk "$DEST" | cut -f1)
mkdir -p "$DEST/DEBIAN"
cat > "$DEST/DEBIAN/control" <<EOF
Package: critical-zoomer
Version: ${VERSION}
Section: graphics
Priority: optional
Architecture: ${ARCH}
Maintainer: Jonathan Tippy <jonathan@localhost>
Installed-Size: ${SIZE}
Depends: ${SHLIBS}
Homepage: https://github.com/JonathanTippy/mandelbrot-set
Description: GPU-accelerated Mandelbrot set explorer
 Critical Zoomer explores the Mandelbrot set with seamless deep zoom,
 GPU-accelerated perturbation rendering, and a focus on speed and
 calibration at extreme magnification.
EOF

cat > "$DEST/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 0755 "$DEST/DEBIAN/postinst"

mkdir -p "$(dirname "$OUT")"
dpkg-deb --root-owner-group --build "$DEST" "$OUT"
echo "Wrote $OUT"
dpkg-deb -I "$OUT"
