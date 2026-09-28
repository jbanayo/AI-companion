#!/usr/bin/env bash
# Builds The List and wraps it into build/The List.app, signed for this Mac only.
# Usage: ./build-app.sh [release|debug]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

config="${1:-release}"
swift build -c "$config" --product TheList
bin="$(swift build -c "$config" --show-bin-path)/TheList"

app="build/The List.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/TheList"

todo_path="$(cd ../.. && pwd)/data/TODO.md"
sed "s|__TODO_PATH__|${todo_path}|" Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad-hoc signature: enough to run locally, which login items (E7.4) and the URL scheme (E7.3) need.
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
