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

touch -t 202606040000 "fixtures/internal-subagent/sessions/2026/06/04/rollout-2026-06-04T00-00-00-44444444-4444-4444-4444-444444444444.jsonl"
touch -t 202606040001 "fixtures/internal-subagent/sessions/2026/06/04/rollout-2026-06-04T00-00-01-55555555-5555-5555-5555-555555555555.jsonl"
assert_status internal-subagent Idle

CODEX_HOME="$PWD/fixtures/idle" ./CodexStatusApp --once --debug >/dev/null
plutil -lint "launcher/Codex Status.app/Contents/Info.plist"
