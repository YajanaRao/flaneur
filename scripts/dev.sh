#!/bin/sh
# dev.sh — watch Sources/ and Package.swift; on every save: incremental debug
# build, relaunch the app, and pop the panel (the binary toggles on --toggle
# when no other instance is running). Ctrl-C stops the loop, kills the dev
# instance, and relaunches the installed app if it was running before.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bin_dir=$(swift build --package-path "$root" --show-bin-path)
bin="$bin_dir/flaneur"

app_pid=""
restore_app=0

cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    if [ "$restore_app" = 1 ] && [ -d "$HOME/Applications/Flaneur.app" ]; then
        open "$HOME/Applications/Flaneur.app"
    fi
}
trap cleanup EXIT INT TERM

fingerprint() {
    { find "$root/Sources" -type f; echo "$root/Package.swift"; } \
        | sort | xargs stat -f '%N %m' | cksum
}

launch() {
    [ -n "$app_pid" ] && { kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; }
    "$bin" --toggle &
    app_pid=$!
}

# One instance per bundle id: the installed app yields to the dev build, and is
# restored on exit only if it was the one running.
if pgrep -x flaneur >/dev/null && ps -o comm= -p "$(pgrep -x flaneur | head -1)" | grep -q "Flaneur.app"; then
    restore_app=1
fi
killall flaneur 2>/dev/null || true

echo "▸ dev loop — edit Sources/, save to rebuild; Ctrl-C to stop"
swift build --package-path "$root"
launch
last=$(fingerprint)

while true; do
    sleep 0.5
    now=$(fingerprint)
    [ "$now" = "$last" ] && continue
    sleep 0.4 # let the write settle
    last=$(fingerprint)
    if swift build --package-path "$root"; then
        launch
        echo "▸ $(date +%H:%M:%S) relaunched"
    else
        echo "▸ build failed — previous instance kept; save again to retry"
    fi
done
