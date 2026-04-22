#!/bin/sh
# tigerclaw installer — downloads the latest release binary for the
# host platform into /usr/local/bin (or $TIGERCLAW_INSTALL_PREFIX/bin
# if set) and seeds ~/.tigerclaw/config.json with placeholder content.
#
# Real release URLs land with the CI release workflow; this script is
# already wired to consume them via $TIGERCLAW_RELEASE_BASE so the
# moment the workflow publishes its first artifact, the script works
# unchanged.
set -eu

PREFIX="${TIGERCLAW_INSTALL_PREFIX:-/usr/local}"
RELEASE_URL_BASE="${TIGERCLAW_RELEASE_BASE:-https://github.com/example/tigerclaw/releases/latest/download}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS-$ARCH" in
  darwin-arm64|darwin-aarch64) TARGET=macos-arm64 ;;
  darwin-x86_64) TARGET=macos-x86_64 ;;
  linux-x86_64) TARGET=linux-x86_64 ;;
  linux-aarch64|linux-arm64) TARGET=linux-arm64 ;;
  *) echo "unsupported platform: $OS-$ARCH" >&2; exit 1 ;;
esac

ARTIFACT="tigerclaw-$TARGET"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "downloading $ARTIFACT..."
curl -sSfL "$RELEASE_URL_BASE/$ARTIFACT" -o "$TMP/tigerclaw"
chmod +x "$TMP/tigerclaw"

echo "installing to $PREFIX/bin/tigerclaw..."
if [ -w "$PREFIX/bin" ]; then
  mv "$TMP/tigerclaw" "$PREFIX/bin/tigerclaw"
else
  sudo mv "$TMP/tigerclaw" "$PREFIX/bin/tigerclaw"
fi

mkdir -p "$HOME/.tigerclaw"
if [ ! -f "$HOME/.tigerclaw/config.json" ]; then
  cat > "$HOME/.tigerclaw/config.json" <<'EOF'
{
  "models": {
    "providers": {}
  }
}
EOF
  chmod 600 "$HOME/.tigerclaw/config.json"
  echo "wrote stub config to $HOME/.tigerclaw/config.json"
fi

echo "done. run: tigerclaw doctor"
