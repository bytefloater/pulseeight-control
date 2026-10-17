#!/bin/sh
# Deletes out/ and the Swift .build folders, like the VS Code task "Clean: all build output".
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
rm -rf out PulseEightKit/.build PulseEightFakeServer/.build PulseEightControl-macos/.build
echo "Cleaned out/ and the Swift .build folders"
