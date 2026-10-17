#!/bin/sh
# End-to-end test of the macOS update path, with the real Sparkle and a feed served from this machine.
#
#   scripts/release/e2e-macos-update.sh
#
# Builds version 0.1.0 (build 1) and 0.1.1 (build 2), signs the 0.1.1 disk image with a throwaway key, serves
# a feed offering it, launches 0.1.0, asks it to check for updates, clicks through Sparkle's own windows, and
# checks that the installed app has become 0.1.1 and is still validly signed.
#
# Needs macOS and Accessibility permission for the terminal (it clicks Sparkle's buttons through System
# Events). Works in P8_E2E_DIR (default out/e2e); never touches out/macos or your real settings or Keychain.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="${P8_E2E_DIR:-$root/out/e2e}"
timeout="${P8_E2E_TIMEOUT:-240}"
old_version="0.1.0"
new_version="0.1.1"

rm -rf "$work"
mkdir -p "$work/site" "$work/old" "$work/new" "$work/config"
server_pid=""
app_path="$work/installed/PulseEightControl.app"

cleanup() {
    # Only processes started here: the server, and apps running from this folder's installed copy.
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    pkill -f "$app_path/Contents/MacOS/PulseEightControl" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; diagnose; exit 1; }
diagnose() {
    echo "--- recent Sparkle log lines:" >&2
    log show --last 5m --style compact --predicate 'process == "PulseEightControl" OR subsystem CONTAINS "sparkle" OR process == "Autoupdate"' 2>/dev/null \
        | grep -iE "sparkle|update|signature|error" | tail -25 >&2 || true
}

tool() { swift "$root/scripts/release/ed25519.swift" "$@"; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

step "Throwaway signing key"
keys="$(tool generate)"
private_key="$(echo "$keys" | sed -n 's/^private=//p')"
public_key="$(echo "$keys" | sed -n 's/^public=//p')"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
feed="http://127.0.0.1:$port/appcast.xml"
echo "   feed: $feed"

step "Building $new_version (the update) and $old_version (the app that will update itself)"
# Both carry the same feed and key, as every real release does: Sparkle refuses an update whose app wouldn't
# be able to verify the next one (it would strand people), and reports "improperly signed".
P8_VERSION="$new_version" P8_BUILD=2 P8_OUT_DIR="$work/new" P8_UPDATE_FEED_URL="$feed" P8_SPARKLE_PUBLIC_KEY="$public_key" \
    "$root/PulseEightControl-macos/package.sh" release >/dev/null
P8_VERSION="$old_version" P8_BUILD=1 P8_OUT_DIR="$work/old" P8_UPDATE_FEED_URL="$feed" P8_SPARKLE_PUBLIC_KEY="$public_key" \
    "$root/PulseEightControl-macos/package.sh" release >/dev/null
[ "$(plist_get "$work/old/PulseEightControl.app" CFBundleShortVersionString)" = "$old_version" ] || fail "the old app isn't $old_version"
[ "$(plist_get "$work/new/PulseEightControl.app" CFBundleShortVersionString)" = "$new_version" ] || fail "the new app isn't $new_version"

step "Packaging and signing the update, and publishing a feed that offers it"
dmg="$work/site/PulseEightControl-$new_version.dmg"
"$root/scripts/release/make-dmg.sh" "$work/new/PulseEightControl.app" "$dmg" >/dev/null
signed="$(ED25519_PRIVATE_KEY="$private_key" tool sign "$dmg")"
signature="$(echo "$signed" | sed -n 's/^signature=//p')"
length="$(echo "$signed" | sed -n 's/^length=//p')"
python3 "$root/scripts/release/appcast.py" add "$work/site/appcast.xml" --title "PulseEight Control (test)" \
    --version 2 --short "$new_version" --url "http://127.0.0.1:$port/PulseEightControl-$new_version.dmg" \
    --length "$length" --signature "$signature" --min-os 14.0 --notes "End-to-end test release." >/dev/null
python3 "$root/scripts/release/appcast.py" validate "$work/site/appcast.xml" --allow-http
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/site" >"$work/server.log" 2>&1 &
server_pid=$!

step "Installing $old_version where Sparkle will replace it"
mkdir -p "$work/installed"
ditto "$work/old/PulseEightControl.app" "$app_path"
# Plain http to this machine is refused by App Transport Security unless the app allows local networking.
# Test copy only: the shipped app has no such exception. Changing the plist breaks the signature, so re-sign.
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
    "$app_path/Contents/Info.plist"
codesign --force --deep --sign - "$app_path" 2>/dev/null
codesign --verify --deep --strict "$app_path"

step "Launching $old_version"
P8_CONFIG_DIR="$work/config" P8_SECRET_STORE=file "$app_path/Contents/MacOS/PulseEightControl" >"$work/app.log" 2>&1 &
app_pid=$!
sleep 4
kill -0 "$app_pid" 2>/dev/null || fail "the app exited right after launch (see $work/app.log)"

# Clicks the first button with one of these names in any of the app's windows; prints which.
click_button() {
    osascript - "$@" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
    tell application "System Events"
        if not (exists process "PulseEightControl") then return ""
        tell process "PulseEightControl"
            repeat with w in windows
                repeat with n in argv
                    if exists (button (contents of n) of w) then
                        click button (contents of n) of w
                        return (contents of n)
                    end if
                end repeat
            end repeat
        end tell
    end tell
    return ""
end run
APPLESCRIPT
}

# The text of Sparkle's error alert, if it is showing one ("Update Error!" and the reason); empty otherwise.
sparkle_error() {
    osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
    if not (exists process "PulseEightControl") then return ""
    tell process "PulseEightControl"
        repeat with w in windows
            try
                set t to (value of every static text of w) as string
                if t contains "Error" or t contains "error" then return t
            end try
        end repeat
    end tell
end tell
return ""
APPLESCRIPT
}

step "Asking it to check for updates (Sparkle may also have started a check on its own)"
osascript <<'APPLESCRIPT' 2>/dev/null || echo "   (menu item not clickable yet; relying on the automatic check)"
tell application "System Events"
    tell process "PulseEightControl"
        set frontmost to true
        click menu item "Check for Updates…" of menu 1 of menu bar item 2 of menu bar 1
    end tell
end tell
APPLESCRIPT

step "Clicking through Sparkle's windows until the installed app is $new_version (up to ${timeout}s)"
deadline=$(( $(date +%s) + timeout ))
last=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    installed="$(plist_get "$app_path" CFBundleShortVersionString)"
    if [ "$installed" = "$new_version" ]; then break; fi
    problem="$(sparkle_error)"
    [ -z "$problem" ] || fail "Sparkle reported: $problem"
    clicked="$(click_button "Install Update" "Install and Relaunch" "Install & Relaunch" "Relaunch" "Install")"
    if [ -n "$clicked" ] && [ "$clicked" != "$last" ]; then echo "   clicked \"$clicked\""; last="$clicked"; fi
    sleep 2
done

step "Result"
installed="$(plist_get "$app_path" CFBundleShortVersionString)"
build="$(plist_get "$app_path" CFBundleVersion)"
echo "   installed app: $installed (build $build)"
[ "$installed" = "$new_version" ] || fail "the app is still $installed after ${timeout}s"
[ "$build" = "2" ] || fail "the build number is $build, not 2"
codesign --verify --deep --strict "$app_path" || fail "the updated app's signature is not valid"
echo "   signature: valid"

# Sparkle relaunches the new version on its own; give it a moment and confirm it is running.
sleep 5
if pgrep -f "$app_path/Contents/MacOS/PulseEightControl" >/dev/null; then echo "   the updated app is running"; else echo "   (the updated app did not relaunch itself; the update itself is installed)"; fi

echo
echo "PASS: $old_version found $new_version in the feed, verified its signature, installed it and kept a valid signature."
