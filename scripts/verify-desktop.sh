#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target WLKit
verification_dir="$(mktemp -d /tmp/micro-desktop.XXXXXX)"
fixture_pid=""
cleanup() {
    if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$verification_dir"
}
trap cleanup EXIT
swiftc -parse-as-library -I .build/debug/Modules scripts/verify-desktop.swift .build/debug/WLKit.build/*.o -o "$verification_dir/verify"
swiftc scripts/desktop-launch-fixture.swift -o "$verification_dir/desktop-fixture"
python3 scripts/desktop-test-server.py "$verification_dir" &
fixture_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -f "$verification_dir/ready" ]] && break
    sleep 0.05
done
[[ -f "$verification_dir/ready" ]]
"$verification_dir/verify" "$verification_dir" "$verification_dir/desktop-fixture"
wait "$fixture_pid"
fixture_pid=""
