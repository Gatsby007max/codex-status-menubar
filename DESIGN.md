# Design Blueprint

## Goal

Build a small external macOS utility that shows local Codex Desktop status without touching Codex internals. The app should be easy to compile with `swiftc`, resilient to changing JSONL schemas, and useful in both UI and CLI modes.

## Non-Goals

- Do not modify `Codex.app`.
- Do not modify Pet files or bundled Codex files.
- Do not write into `$CODEX_HOME`.
- Do not depend on Xcode project files.
- Do not require network access.

## Runtime Shape

```text
CodexStatusApp.swift
  AppDelegate
    - menu bar item
    - polling timer
    - menu rendering
    - desktop widget window
    - Pet-style stop bubble
  StatusCollector
    - resolves CODEX_HOME
    - scans sessions
    - parses JSONL defensively
    - extracts title/model/token/rate metadata
  StatusDetector
    - maps recognized events to Thinking/Running/Waiting/Idle/Failed/No Data
  --once
    - prints a JSON snapshot and exits
  --debug
    - prints selected file, recognized events, and status reason to stderr
```

## Data Flow

1. Resolve Codex home from `CODEX_HOME`, otherwise `$HOME/.codex`.
2. Read `session_index.jsonl` only as supplemental title metadata.
3. Enumerate `sessions/**/*.jsonl`.
4. Sort session candidates by file modification time, newest first.
5. Parse candidates until the first valid JSONL session is found.
6. Collect recognized events and metadata.
7. Detect final status.
8. Render either JSON (`--once`) or AppKit UI.

## Session Selection

The current implementation prefers actual session JSONL modification time over `session_index.jsonl` ordering. This was chosen because `session_index.jsonl` can point to a stale thread while the active file is still receiving updates.

Fallback behavior:

- Missing or unreadable `session_index.jsonl` does not cause `No Data`.
- Invalid index records are ignored.
- `No Data` is returned only when no valid session JSONL can be parsed.

## JSONL Parsing

The parser reads line by line and uses `JSONSerialization`.

Defensive choices:

- Malformed lines are ignored.
- Partial trailing lines are attempted once and ignored if invalid.
- Unknown fields are not fatal.
- Nested dictionaries and arrays are flattened into field paths.
- Event recognition inspects `type`, `event`, `name`, `status`, `kind`, `role`, `level`, and common token fields.

## Status Detection

Recognized event kinds:

- `taskStart`
- `taskComplete`
- `assistantActivity`
- `tokenCount`
- `waiting`
- `error`

Decision order:

1. `Failed` if a recent explicit error exists after the latest completion.
2. `Thinking` if an active run has recent assistant/token activity.
3. `Running` if an active run exists without very recent assistant/token activity.
4. `Waiting` if inactive state clearly waits for user input or approval.
5. `Idle` otherwise.

## Rate Limits

Rate-limit display is extracted from:

```text
payload.rate_limits.primary
payload.rate_limits.secondary
```

The UI labels windows by `window_minutes`:

- `300` minutes becomes `5h`.
- `10080` minutes becomes `7D`.

Remaining percent is calculated from `100 - used_percent`.

## UI

The app uses AppKit directly:

- `NSStatusBar` menu item.
- `NSMenu` dropdown.
- Custom `MiniBarView` for 5h/7D progress bars.
- `NSPanel` for pseudo desktop widget.
- `NSPanel` text bubble for Pet-style stop notification.

Activation policy is `.accessory`, and the generated app bundle sets `LSUIElement=true`.

## Persistence

The desktop widget toggle is stored in `UserDefaults`:

```text
DesktopWidgetEnabled
```

No app setting is written to Codex state.

## Public Repository Contents

Commit:

- `CodexStatusApp.swift`
- `run.sh`
- `install-desktop-launcher.sh`
- `scripts/verify.sh`
- `README.md`
- `DESIGN.md`
- `REVIEW.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `CHANGELOG.md`
- `PUBLISHING.md`
- `AGENTS.md`
- `LICENSE`
- `.gitignore`
- `.github/workflows/ci.yml`
- `fixtures/`
- `launcher/Codex Status.app/Contents/Info.plist`

Ignore:

- `.swift-module-cache/`
- `CodexStatusApp`
- generated app-bundle executable
- generated icon files
- `.DS_Store`
- `*.dSYM/`

## Future Work

- Expand fixture tests for waiting, malformed JSONL, and stale index fallback.
- Add optional SQLite metadata lookup with graceful fallback.
- Add a stable icon generation step or a committed small icon asset.
- Add duplicate-process handling for the desktop launcher.
- Add a release script that builds a clean `.app` bundle.

## Verification Design

The repository uses synthetic `CODEX_HOME` fixtures for repeatable checks:

- `fixtures/idle`
- `fixtures/thinking`
- `fixtures/failed`
- `fixtures/empty`

`scripts/verify.sh` compiles the Swift file, runs CLI snapshots against each fixture, checks
`--debug`, and lints the app bundle `Info.plist`. GitHub Actions runs the same script on
`macos-latest`.
