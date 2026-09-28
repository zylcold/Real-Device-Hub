#!/bin/bash
# Build Real Device Hub and install the `real-device-hub` command.
#
#   ./install.sh                 release build into /usr/local
#   ./install.sh --prefix DIR    release build into DIR
#   ./install.sh --no-link       build only, leave the binary in .build
set -euo pipefail

cd "$(dirname "$0")"

PREFIX="/usr/local"
LINK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-link) LINK=0 ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

command -v swift >/dev/null 2>&1 || {
  echo "ERROR: 'swift' not found. Install Xcode or run: xcode-select --install" >&2
  exit 1
}

echo "[install] Building release…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/RealDeviceHub"
[[ -x "$BIN" ]] || { echo "ERROR: $BIN not found" >&2; exit 1; }

# The dashboard ships as files next to the binary, so a bare symlink would lose
# it. Install the two halves of the layout instead:
#
#   $PREFIX/bin/real-device-hub
#   $PREFIX/share/real-device-hub/browser/
if [[ $LINK -eq 1 ]]; then
  mkdir -p "$PREFIX/bin" "$PREFIX/share/real-device-hub"
  cp "$BIN" "$PREFIX/bin/real-device-hub"
  chmod +x "$PREFIX/bin/real-device-hub"
  rm -rf "$PREFIX/share/real-device-hub/browser"
  cp -R browser "$PREFIX/share/real-device-hub/browser"
  echo "[install] Installed $PREFIX/bin/real-device-hub"
  echo "[install] Pages in $PREFIX/share/real-device-hub/browser"
  case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "[install] Note: $PREFIX/bin is not on your PATH." ;;
  esac
fi

echo "[install] Done. Run: real-device-hub"
