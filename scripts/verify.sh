#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swiftc -module-cache-path .swift-module-cache CodexStatusApp.swift -o CodexStatusApp

assert_status() {
  local fixture="$1"
  local expected="$2"
  local output

  output="$(CODEX_HOME="$PWD/fixtures/$fixture" ./CodexStatusApp --once)"
  printf '%s\n' "$output"

  if ! grep -q "\"status\" : \"$expected\"" <<< "$output"; then
    printf 'Expected fixture %s to report status %s\n' "$fixture" "$expected" >&2
    exit 1
  fi
}

assert_status idle Idle
assert_status thinking Thinking
assert_status failed Failed
assert_status empty "No Data"

CODEX_HOME="$PWD/fixtures/idle" ./CodexStatusApp --once --debug >/dev/null
plutil -lint "launcher/Codex Status.app/Contents/Info.plist"

