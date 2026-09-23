#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sources=()
for source in Sources/*.swift; do
  [[ "$source" == "Sources/VibeTranslateApp.swift" ]] || sources+=("$source")
done
binary="$(mktemp /tmp/vibe-chatgpt-tests.XXXXXX)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library "${sources[@]}" Tests/ChatGPTProviderTests.swift -o "$binary"
"$binary"
