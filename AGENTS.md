# Codex Status Menubar Agent Guide

## Project Overview

Codex Status Menubar is a small native macOS Swift/AppKit utility that monitors local
Codex Desktop session state and renders a read-only status view in the menu bar.

## Repository Layout

- `CodexStatusApp.swift` contains the full app, collector, detector, menu UI, CLI mode,
  desktop widget, and Pet-style stop bubble.
- `run.sh` compiles and runs the binary for development.
- `install-desktop-launcher.sh` builds a minimal `.app` bundle and copies it to the Desktop.
- `fixtures/` contains sanitized Codex-home fixtures for CLI verification.
- `scripts/verify.sh` compiles the app and checks fixture statuses.
- `launcher/Codex Status.app/Contents/Info.plist` is the app bundle template.

## Development Rules

- Keep the app external and read-only.
- Do not modify `Codex.app`, Pet files, bundled Codex files, or real Codex state.
- Treat Codex JSONL schemas as unstable.
- Ignore malformed JSONL lines.
- Keep fixture data synthetic and sanitized.
- Do not commit `.swift-module-cache/`, generated binaries, generated app executables,
  or local reports.
- Keep `CodexStatusApp.swift` single-file unless there is a clear reason to split it.

## Verification

Run before publishing or opening a pull request:

```bash
./scripts/verify.sh
```

For local diagnostics:

```bash
./run.sh --once --debug
CODEX_HOME=fixtures/thinking ./run.sh --once --debug
```

## Release Expectations

- `./scripts/verify.sh` passes on macOS.
- `plutil -lint "launcher/Codex Status.app/Contents/Info.plist"` passes.
- `git status --short` is clean.
- Generated files are ignored.
- No real Codex logs, prompts, responses, credentials, or local private paths are committed.

