#!/bin/sh
# Builds PulseEightControl.app (the executable, Info.plist and the Icon Composer icon) into
# ../out/macos/. Usage: package.sh [debug|release] [--open]
set -eu

cd "$(dirname "$0")"
config=release
open_after=0
for arg in "$@"; do
    case "$arg" in
        debug | release) config=$arg ;;
        --open) open_after=1 ;;
        *) echo "usage: $0 [debug|release] [--open]" >&2; exit 2 ;;
    esac
done

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/PulseEightControl"

app=../out/macos/PulseEightControl.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/PulseEightControl"
cp Info.plist "$app/Contents/Info.plist"

# actool turns the .icon into Assets.car (Liquid Glass icon, macOS 26) and an .icns fallback.
xcrun actool PulseEightControl.icon \
    --compile "$app/Contents/Resources" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist /dev/null \
    --app-icon PulseEightControl --include-all-app-icons \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx

# Ad-hoc signature so the bundle launches cleanly on this Mac.
codesign --force --sign - "$app"

echo "Built $(cd "$(dirname "$app")" && pwd)/PulseEightControl.app"
[ "$open_after" = 1 ] && open "$app"
exit 0
