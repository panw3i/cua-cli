#!/bin/sh
# Install cua: LCU (runtime only, no agent registration) if missing, then cua into ~/.local/share/cua-cli
# with a link at ~/.local/bin/cua. Requires macOS on Apple Silicon and the official ChatGPT app.
set -eu
LCU_VERSION=${LCU_VERSION:-0.13.1}
LCU_SHA256=${LCU_SHA256:-a8c75bed3ea85d22427ab3a39bb8498082f2199548630f14411cc82758dc2f33}
here=$(cd "$(dirname "$0")" && pwd)
dest=$HOME/.local/share/cua-cli
bindir=$HOME/.local/bin

[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "cua: macOS on Apple Silicon is required" >&2; exit 1; }
[ -d /Applications/ChatGPT.app ] || { echo "cua: install the ChatGPT desktop app first (https://chatgpt.com/download/)" >&2; exit 1; }

if [ ! -x "$HOME/.local/share/lcu/current/bin/lcu" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  archive=lcu-$LCU_VERSION-darwin-arm64.tar.gz
  echo "Downloading LCU $LCU_VERSION..."
  curl -fsSL -o "$tmp/$archive" "https://github.com/amontlabs/lcu/releases/download/v$LCU_VERSION/$archive"
  echo "$LCU_SHA256  $tmp/$archive" | shasum -a 256 -c -
  mkdir "$tmp/x"
  tar -xzf "$tmp/$archive" -C "$tmp/x"
  (cd "$tmp/x"/* && ./scripts/install.sh --runtime-only --yes)
fi

mkdir -p "$dest/bin" "$bindir"
cp "$here/cua.mjs" "$dest/cua.mjs"
cp "$here/bin/cua" "$dest/bin/cua"
chmod 755 "$dest/bin/cua"
ln -sf "$dest/bin/cua" "$bindir/cua"
echo "cua installed: $bindir/cua"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "Add $bindir to PATH to run 'cua' directly." ;; esac
echo "First use: run 'cua js \"await cua.getState()\"' from a terminal and grant Accessibility / Screen Recording when macOS asks."
