#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p "launcher/Codex Status.app/Contents/MacOS" "launcher/Codex Status.app/Contents/Resources"
swiftc -module-cache-path .swift-module-cache CodexStatusApp.swift -o "launcher/Codex Status.app/Contents/MacOS/CodexStatusApp"
chmod +x "launcher/Codex Status.app/Contents/MacOS/CodexStatusApp"
ditto "launcher/Codex Status.app" "$HOME/Desktop/Codex Status.app"
