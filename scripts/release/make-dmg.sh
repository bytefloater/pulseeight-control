#!/bin/sh
# Wraps an .app in a disk image with a shortcut to /Applications, for people to drag it across.
#
#   make-dmg.sh <path/to/App.app> <output.dmg> [volume name]
#
# The image is compressed, not signed or notarized (the app inside is ad-hoc signed). Sparkle can install
# updates straight from a .dmg, so the same file serves the first download and every update.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 <App.app> <output.dmg> [volume name]" >&2; exit 2; }
app="$1"
out="$2"
volume="${3:-PulseEight Control}"
[ -d "$app" ] || { echo "No such app: $app" >&2; exit 1; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/p8-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# ditto, not cp: it keeps the symlinks inside Sparkle.framework and the code signature intact.
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
hdiutil verify -quiet "$out"
echo "Built $out ($(wc -c < "$out" | tr -d ' ') bytes)"
