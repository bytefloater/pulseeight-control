#!/bin/sh
# Starts or stops the fake NeoMatrix (p8fake) for the Xcode schemes, mirroring the VS Code tasks
# "Dev: prepare config" and "Fake matrix: start". Usage: fake-matrix.sh start|stop
#
# The fake is built with its own scratch path (out/fake) and runs in the background; its process id
# is kept in out/fake/p8fake.pid so a later start or stop can find it.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
pidfile="$root/out/fake/p8fake.pid"
port=8080

stop() {
    if [ -f "$pidfile" ]; then
        pid="$(cat "$pidfile")"
        # Only kill it if it still is p8fake (the pid may have been reused).
        if ps -p "$pid" -o command= 2>/dev/null | grep -q p8fake; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
}

start() {
    stop
    mkdir -p "$root/out/dev-config" "$root/out/fake"
    [ -f "$root/out/dev-config/settings.json" ] || cp "$root/PulseEightFakeServer/dev/settings.json" "$root/out/dev-config/settings.json"

    /usr/bin/xcrun swift build --package-path "$root/PulseEightFakeServer" --scratch-path "$root/out/fake" --product p8fake
    nohup "$root/out/fake/debug/p8fake" --port "$port" --password secret --quiet \
        > "$root/out/fake/p8fake.log" 2>&1 < /dev/null &
    echo $! > "$pidfile"

    # Wait (up to ~5 s) until it accepts connections so the app's first poll succeeds.
    i=0
    while [ $i -lt 50 ]; do
        if /usr/bin/nc -z 127.0.0.1 "$port" 2>/dev/null; then exit 0; fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "p8fake did not start; see $root/out/fake/p8fake.log" >&2
    exit 1
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
