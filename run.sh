#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
swiftc -module-cache-path .swift-module-cache CodexStatusApp.swift -o CodexStatusApp
./CodexStatusApp "$@"
