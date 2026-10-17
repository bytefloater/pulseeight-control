#!/bin/sh
# Builds PulseEightControl.app (the executable, Sparkle, Info.plist and the Icon Composer icon) into
# ../out/macos/, ad-hoc signed.
#
#   package.sh [debug|release] [--universal] [--open]
#
# Settings, all optional, from the environment:
#   P8_VERSION             marketing version (default: the repository's VERSION file)
#   P8_BUILD               build number (default: 1)
#   P8_UPDATE_FEED_URL     where the app looks for updates         } give both or neither: an app with
#   P8_SPARKLE_PUBLIC_KEY  the key updates must be signed with     } neither never checks for updates
#
# The feed URL and key are put into the built app's Info.plist, not the source one, so development
# builds can't update themselves and the choice of where releases live is made at release time.
set -eu

cd "$(dirname "$0")"
config=release
open_after=0
universal=0
for arg in "$@"; do
    case "$arg" in
        debug | release) config=$arg ;;
        --universal) universal=1 ;;
        --open) open_after=1 ;;
        *) echo "usage: $0 [debug|release] [--universal] [--open]" >&2; exit 2 ;;
    esac
done

version="${P8_VERSION:-$(tr -d '[:space:]' < ../VERSION)}"
build="${P8_BUILD:-1}"
feed="${P8_UPDATE_FEED_URL:-}"
key="${P8_SPARKLE_PUBLIC_KEY:-}"
if { [ -n "$feed" ] && [ -z "$key" ]; } || { [ -z "$feed" ] && [ -n "$key" ]; }; then
    echo "Set both P8_UPDATE_FEED_URL and P8_SPARKLE_PUBLIC_KEY, or neither." >&2
    exit 2
fi

arch_flags=""
[ "$universal" = 1 ] && arch_flags="--arch arm64 --arch x86_64"

# shellcheck disable=SC2086 # the architecture flags are meant to split
swift build -c "$config" $arch_flags
# shellcheck disable=SC2086
bin="$(swift build -c "$config" $arch_flags --show-bin-path)/PulseEightControl"

app=../out/macos/PulseEightControl.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/PulseEightControl"
cp Info.plist "$app/Contents/Info.plist"

# Sparkle ships as a (universal) binary framework that SwiftPM unpacks under .build/artifacts. ditto keeps
# the framework's symlinks, which a plain cp would flatten and break.
sparkle="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -n 1)"
[ -n "$sparkle" ] || { echo "Couldn't find Sparkle.framework under .build/artifacts (did the build resolve it?)" >&2; exit 1; }
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"

# Version, and where to update from.
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
if [ -n "$feed" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $key" "$plist"
fi

# actool turns the .icon into Assets.car (Liquid Glass icon, macOS 26) and an .icns fallback.
xcrun actool PulseEightControl.icon \
    --compile "$app/Contents/Resources" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist /dev/null \
    --app-icon PulseEightControl --include-all-app-icons \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx

# Ad-hoc signature (no Developer ID yet). --deep signs Sparkle's nested helpers before the app.
# Deliberately without the hardened runtime: library validation would refuse to load Sparkle, whose
# signature is not an ad-hoc one. Updates are protected by Sparkle's own EdDSA check instead.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

echo "Built $(cd "$(dirname "$app")" && pwd)/PulseEightControl.app ($version, build $build, $([ -n "$feed" ] && echo "updates from $feed" || echo "no update feed"))"
[ "$open_after" = 1 ] && open "$app"
exit 0
