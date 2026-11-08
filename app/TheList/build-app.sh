#!/usr/bin/env bash
# Builds The Companion and wraps it into build/The Companion.app, signed for this Mac only.
# Usage: ./build-app.sh [release|debug] [--install]   (default: release)
#   --install  also copies it to ~/Applications (where Spotlight and Launchpad find it) and
#              restarts it from there. "Open at login" (E7.4) points at that copy.
set -euo pipefail
cd "$(dirname "$0")"

config="release"
install=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    release|debug) config="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
swift build -c "$config" --product TheList
bin="$(swift build -c "$config" --show-bin-path)/TheList"

app="build/The Companion.app"
rm -rf "$app" "build/The List.app" # the old name, before E9
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/TheList"

# The app icon is drawn in code (Logo.swift); turn it into AppIcon.icns.
iconset="$(mktemp -d)/AppIcon.iconset"
"$bin" --make-iconset "$iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"

todo_path="$(cd ../.. && pwd)/data/TODO.md"
sed "s|__TODO_PATH__|${todo_path}|" Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad-hoc signature: enough to run locally, which login items (E7.4) and the URL scheme (E7.3) need.
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"

if [[ $install == 1 ]]; then
  dest="$HOME/Applications/The Companion.app"
  # Quit whichever copy is running (build folder or installed), so the new one takes its place.
  osascript -e 'quit app id "com.jbanayo.thelist"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq TheList || break; sleep 0.25; done
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  ditto "$app" "$dest"
  open "$dest"
  echo "Installed and started $dest"
fi
