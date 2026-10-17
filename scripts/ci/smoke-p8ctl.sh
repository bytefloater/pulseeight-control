#!/bin/sh
# Smoke test: the real p8ctl against the real p8fake over a real socket.
#
# Covers what the unit tests can't: the built executables, argument parsing, exit codes, and the HTTP
# transport end to end. Used by CI and fine to run locally:  scripts/ci/smoke-p8ctl.sh
#
# Builds into out/smoke (or $P8_SMOKE_SCRATCH). Kills only the p8fake it started.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${P8_SMOKE_SCRATCH:-$root/out/smoke}"
work="$(mktemp -d "${TMPDIR:-/tmp}/p8-smoke.XXXXXX")"
fake_pid=""

cleanup() {
    [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

# expect_contains <description> <haystack> <needle>
expect_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (wanted \"$3\" in: $2)" ;;
    esac
}

echo "== Building p8fake and p8ctl"
swift build --package-path "$root/PulseEightFakeServer" --scratch-path "$scratch/fake" --product p8fake >/dev/null
swift build --package-path "$root/PulseEightKit" --scratch-path "$scratch/kit" --product p8ctl >/dev/null
p8fake="$(swift build --package-path "$root/PulseEightFakeServer" --scratch-path "$scratch/fake" --show-bin-path)/p8fake"
p8ctl="$(swift build --package-path "$root/PulseEightKit" --scratch-path "$scratch/kit" --show-bin-path)/p8ctl"

echo "== Starting p8fake on a free port"
"$p8fake" --port 0 --password secret --bays 8 --quiet >"$work/fake.log" 2>&1 &
fake_pid=$!

port=""
i=0
while [ $i -lt 100 ]; do
    port="$(sed -n 's/^Fake NeoMatrix on http:\/\/[^:]*:\([0-9]*\).*/\1/p' "$work/fake.log" | head -n 1)"
    [ -n "$port" ] && break
    kill -0 "$fake_pid" 2>/dev/null || { echo "p8fake exited early:" >&2; cat "$work/fake.log" >&2; exit 1; }
    sleep 0.1
    i=$((i + 1))
done
[ -n "$port" ] || { echo "p8fake never reported its port:" >&2; cat "$work/fake.log" >&2; exit 1; }
echo "   listening on 127.0.0.1:$port"

ctl() { "$p8ctl" --host 127.0.0.1 --port "$port" --timeout 5 "$@"; }

echo "== Commands"
status="$(ctl status)"
expect_contains "status shows the model" "$status" "NeoMatrix"
expect_contains "status counts the ports" "$status" "8 in, 8 out"

ports="$(ctl ports)"
expect_contains "ports lists an input" "$ports" "Sky"
expect_contains "ports lists an output" "$ports" "Lounge TV"
expect_contains "output 0 starts on input 0" "$ports" "Lounge TV  [OK]  <- Sky"

routed="$(ctl route "apple tv" "LOUNGE TV")"
expect_contains "route by name (case-insensitive) is acknowledged" "$routed" "Changed"
expect_contains "the new route shows in ports" "$(ctl ports)" "Lounge TV  [OK]  <- Apple TV"

ctl set 5 1 >/dev/null
expect_contains "set by bay changes the route" "$(ctl ports)" "Bedroom TV  [OK]  <- Input 6"

echo "== Failures must be loud"
if out="$(ctl route "No Such Input" "Lounge TV" 2>&1)"; then
    fail "routing an unknown input should fail"
else
    expect_contains "an unknown input is named in the error" "$out" "No Such Input"
fi
if ctl set 99 0 >/dev/null 2>&1; then fail "setting a port that doesn't exist should fail"; else pass "setting a missing port exits non-zero"; fi
if ctl bogus >/dev/null 2>&1; then fail "an unknown command should fail"; else pass "an unknown command exits non-zero"; fi
if "$p8ctl" --host 127.0.0.1 --port 1 --timeout 2 status >/dev/null 2>&1; then
    fail "an unreachable matrix should fail"
else
    pass "an unreachable matrix exits non-zero"
fi

echo "== capture"
ctl capture "$work/capture" >"$work/capture.log"
count="$(ls "$work/capture" | wc -l | tr -d ' ')"
[ "$count" = "19" ] && pass "capture wrote 19 files (3 system + 16 ports)" || fail "capture wrote $count files, wanted 19"
details="$(cat "$work/capture/system-details.json")"
expect_contains "capture redacts the serial number" "$details" '"Serial":"REDACTED"'
expect_contains "capture keeps everything else" "$details" "NeoMatrix"
ctl capture "$work/capture-raw" --no-redact >/dev/null
expect_contains "--no-redact keeps the serial number" "$(cat "$work/capture-raw/system-details.json")" '"Serial":"FAKE'

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "All smoke checks passed"
