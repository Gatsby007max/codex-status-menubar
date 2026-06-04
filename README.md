# Codex Status Menubar

Codex Status Menubar is a tiny native macOS utility that watches local Codex Desktop state and shows the latest thread status, token count, and rate-limit remaining values in the menu bar.

The app is external and read-only. It does not modify `Codex.app`, Pet files, bundled Codex files, or existing Codex state.

## Features

- Native Swift/AppKit menu bar app.
- CLI snapshot mode with `--once`.
- Verbose diagnostics with `--debug` or `--verbose`.
- Polls local Codex state every 3 seconds by default.
- Supports `CODEX_STATUS_POLL_INTERVAL`, clamped from 1.5 to 30 seconds.
- Reads `CODEX_HOME` first, then falls back to `~/.codex`.
- Selects the latest session from `sessions/**/*.jsonl` by modification time.
- Uses `session_index.jsonl` as supplemental title metadata.
- Ignores malformed JSONL lines and keeps running.
- Shows status: `Thinking`, `Running`, `Waiting`, `Idle`, `Failed`, or `No Data`.
- Shows 5h and 7D rate-limit remaining values when present in the JSONL payload.
- Includes a pseudo desktop widget that can be started or stopped from the menu.
- Shows a Pet-style text bubble when work transitions from active to stopped.

## Files Read

The app only reads local Codex state:

- `$CODEX_HOME/session_index.jsonl`
- `$CODEX_HOME/sessions/**/*.jsonl`

If `CODEX_HOME` is not set, `$HOME/.codex` is used.

The original MVP plan mentioned `$CODEX_HOME/state_5.sqlite` as an optional metadata source. The current restored implementation does not query SQLite yet; unknown title/model/token values are shown as `Unknown` instead.

## Build And Run

From this directory:

```bash
./run.sh
```

`run.sh` compiles the single Swift file and launches the app:

```bash
swiftc -module-cache-path .swift-module-cache CodexStatusApp.swift -o CodexStatusApp
./CodexStatusApp
```

The menu bar title shows:

```text
Codex: <Status>
```

When rate-limit data is available, the title also includes a compact rate badge.

## CLI Snapshot

Print one JSON snapshot and exit:

```bash
./run.sh --once
```

Print diagnostics to stderr:

```bash
./run.sh --once --debug
```

Use a fixture Codex home:

```bash
CODEX_HOME=/tmp/codex-fixture ./run.sh --once --debug
```

Change polling frequency:

```bash
CODEX_STATUS_POLL_INTERVAL=5 ./run.sh
```

## Verification

Run the publish-ready verification script:

```bash
./scripts/verify.sh
```

This compiles the app, checks synthetic `CODEX_HOME` fixtures, verifies `--debug`, and
validates the launcher `Info.plist`.

Fixture examples:

```bash
CODEX_HOME=fixtures/idle ./run.sh --once
CODEX_HOME=fixtures/thinking ./run.sh --once
CODEX_HOME=fixtures/failed ./run.sh --once
CODEX_HOME=fixtures/empty ./run.sh --once
```

## Desktop Launcher

Create a simple app bundle and copy it to the Desktop:

```bash
./install-desktop-launcher.sh
```

This generates:

```text
~/Desktop/Codex Status.app
```

Generated binaries are intentionally ignored by Git. Re-run the installer after source changes.

## Menu Actions

- `Refresh`: collect status immediately.
- `Start Desktop Widget` / `Stop Desktop Widget`: toggle the pseudo desktop widget.
- `Open Codex`: launch `/Applications/Codex.app`.
- `Quit`: close the menu app, widget, and temporary Pet-style bubble.

## Status Rules

- `No Data`: no valid session JSONL is found.
- `Failed`: recent explicit structured error marker exists, and no later completion marker exists.
- `Thinking`: a task/run is open and recent assistant or token activity is visible.
- `Running`: a task/run is open but no very recent assistant/token activity is visible.
- `Waiting`: inactive session clearly appears to wait for user input, approval, or next action.
- `Idle`: valid inactive session with no recent explicit failure or clear waiting marker.

When uncertain, the detector prefers `Idle` over `Waiting`.

## Troubleshooting

- If the status looks stale, run `./run.sh --once --debug` and check which JSONL session was selected.
- If no rate bar appears, the selected session may not include `payload.rate_limits`.
- If the Desktop app does not launch after double-clicking, re-run `./install-desktop-launcher.sh`.
- If build output appears in Git, confirm `.swift-module-cache/`, `CodexStatusApp`, and generated app-bundle binaries are ignored.
- If the app cannot read Codex state, try `CODEX_HOME=/path/to/fixture ./run.sh --once --debug`.

## Repository Notes

This directory is intended to be publishable as a small standalone project. Commit source, scripts, docs, `.gitignore`, and the app bundle `Info.plist` template. Do not commit compiler caches or generated binaries.

See `PUBLISHING.md` for the final GitHub upload checklist.

