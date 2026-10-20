#!/bin/sh
# End-to-end test of the macOS update path, with the real Sparkle and a feed served from this machine.
#
#   scripts/release/e2e-macos-update.sh
#
# Builds releases v0.1.0 and v0.1.1 (the fields come from their tags, as in the workflow), signs the 0.1.1 disk image with a throwaway key, serves
# a feed offering it, launches 0.1.0, asks it to check for updates, clicks through Sparkle's own windows, and
# checks that the installed app has become 0.1.1 and is still validly signed.
#
# P8_E2E_SCENARIO picks what is tested (default: release):
#   release          v0.1.0 is offered v0.1.1 (no channel: everyone gets a release)
#   rc-on            v0.1.0 with "include pre-releases" turned on is offered v0.1.1.rc-01 (feed channel rc) and installs it
#   rc-unset         v0.1.0, the setting left alone, is NOT offered v0.1.1.rc-01 (releases only by default)
#   rc-follow-build  v0.1.0.beta-01, the setting left alone, IS offered v0.1.1.rc-01 (a beta build keeps getting pre-releases)
#
# Needs macOS and Accessibility permission for the terminal (it clicks Sparkle's buttons through System
# Events). Works in P8_E2E_DIR (default out/e2e); never touches out/macos or your real settings or Keychain.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="${P8_E2E_DIR:-$root/out/e2e}"
timeout="${P8_E2E_TIMEOUT:-240}"
# Every version field comes from a release tag (version.py), exactly as the release workflow gets them.
field() { python3 "$root/scripts/release/version.py" fields "$1" | sed -n "s/^$2=//p"; }
scenario="${P8_E2E_SCENARIO:-release}"
setting=""   # the "include pre-releases" setting written for the app: true, or nothing (unset)
expect="install"
case "$scenario" in
    release) old_tag="v0.1.0"; new_tag="v0.1.1" ;;
    rc-on) old_tag="v0.1.0"; new_tag="v0.1.1.rc-01"; setting="true" ;;
    rc-unset) old_tag="v0.1.0"; new_tag="v0.1.1.rc-01"; expect="ignore" ;;
    rc-follow-build) old_tag="v0.1.0.beta-01"; new_tag="v0.1.1.rc-01" ;;
    *) echo "unknown P8_E2E_SCENARIO '$scenario'" >&2; exit 2 ;;
esac
new_channel="$(field "$new_tag" channel)"
channel_args=""
[ "$new_channel" = release ] || channel_args="--channel $new_channel"
old_version="$(field "$old_tag" semver)"
new_version="$(field "$new_tag" semver)"
old_build="$(field "$old_tag" build)"
new_build="$(field "$new_tag" build)"

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

step "Scenario: $scenario ($old_tag -> $new_tag, setting: ${setting:-unset}, expecting it to be ${expect}ed)"
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
P8_VERSION="$new_version" P8_BUILD="$new_build" P8_CHANNEL="$(field "$new_tag" channel)" P8_LABEL="$(field "$new_tag" label)" P8_OUT_DIR="$work/new" P8_UPDATE_FEED_URL="$feed" P8_SPARKLE_PUBLIC_KEY="$public_key" \
    "$root/PulseEightControl-macos/package.sh" release >/dev/null
P8_VERSION="$old_version" P8_BUILD="$old_build" P8_CHANNEL="$(field "$old_tag" channel)" P8_LABEL="$(field "$old_tag" label)" P8_OUT_DIR="$work/old" P8_UPDATE_FEED_URL="$feed" P8_SPARKLE_PUBLIC_KEY="$public_key" \
    "$root/PulseEightControl-macos/package.sh" release >/dev/null
[ "$(plist_get "$work/old/PulseEightControl.app" CFBundleShortVersionString)" = "$old_version" ] || fail "the old app isn't $old_version"
[ "$(plist_get "$work/new/PulseEightControl.app" CFBundleShortVersionString)" = "$new_version" ] || fail "the new app isn't $new_version"

step "Packaging and signing the update, and publishing a feed that offers it"
dmg="$work/site/PulseEightControl-$new_version.dmg"
"$root/scripts/release/make-dmg.sh" "$work/new/PulseEightControl.app" "$dmg" >/dev/null
signed="$(ED25519_PRIVATE_KEY="$private_key" tool sign "$dmg")"
signature="$(echo "$signed" | sed -n 's/^signature=//p')"
length="$(echo "$signed" | sed -n 's/^length=//p')"
# shellcheck disable=SC2086 # the channel arguments are meant to split
python3 "$root/scripts/release/appcast.py" add "$work/site/appcast.xml" --title "PulseEight Control (test)" $channel_args \
    --version "$new_build" --short "$new_version" --url "http://127.0.0.1:$port/PulseEightControl-$new_version.dmg" \
    --length "$length" --signature "$signature" --min-os 14.0 --notes "End-to-end test release." >/dev/null
python3 "$root/scripts/release/appcast.py" validate "$work/site/appcast.xml" --allow-http --strict
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/site" >"$work/server.log" 2>&1 &
server_pid=$!

step "Installing $old_version where Sparkle will replace it"
mkdir -p "$work/installed"
ditto "$work/old/PulseEightControl.app" "$app_path"
# Plain http to this machine needs the app to allow local networking, which the shipped app's Info.plist already does
# (NSAllowsLocalNetworking), so the app is used exactly as packaged.
codesign --verify --deep --strict "$app_path"

step "Launching $old_version"
[ -z "$setting" ] || printf '{"updatePrereleases": %s}\n' "$setting" > "$work/config/settings.json"
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

if [ "$expect" = ignore ]; then
    # The feed's only newer item is on a channel this app didn't ask for, so Sparkle must say it is up to date and install nothing.
    step "Watching for 45s that Sparkle does NOT offer $new_version"
    deadline=$(( $(date +%s) + 45 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(plist_get "$app_path" CFBundleShortVersionString)" = "$old_version" ] || fail "the app became $(plist_get "$app_path" CFBundleShortVersionString): a pre-release was offered to an app that didn't ask for them"
        if [ -n "$(click_button "Install Update" "Install and Relaunch" "Install")" ]; then fail "Sparkle offered $new_version to an app that didn't ask for pre-releases"; fi
        click_button "OK" "Close" >/dev/null
        sleep 2
    done
    [ "$(plist_get "$app_path" CFBundleShortVersionString)" = "$old_version" ] || fail "the installed app changed"
    echo
    echo "PASS: $old_version ($scenario) was not offered $new_version, which is on the $new_channel channel."
    exit 0
fi

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
[ "$build" = "$new_build" ] || fail "the build number is $build, not $new_build"
codesign --verify --deep --strict "$app_path" || fail "the updated app's signature is not valid"
echo "   signature: valid"

# Sparkle relaunches the new version on its own; give it a moment and confirm it is running.
sleep 5
if pgrep -f "$app_path/Contents/MacOS/PulseEightControl" >/dev/null; then echo "   the updated app is running"; else echo "   (the updated app did not relaunch itself; the update itself is installed)"; fi

echo
echo "PASS: $old_version found $new_version in the feed, verified its signature, installed it and kept a valid signature."
