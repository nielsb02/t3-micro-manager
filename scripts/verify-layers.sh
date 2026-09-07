#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target WLKit
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/micro-layers-verify.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -I .build/debug -I .build/debug/Modules scripts/verify-layers.swift .build/debug/WLKit.build/*.o -o "$verification_dir/verify"
XDG_CONFIG_HOME="$verification_dir" "$verification_dir/verify"
