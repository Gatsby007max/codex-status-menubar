# GitHub Readiness Review

## Current Assessment

The project is publish-ready as a small macOS utility once the final GitHub repository is
created. The core value is contained in one Swift file, the build flow is simple, and the
repository now has fixture verification, CI, contribution docs, security notes, and a
publishing checklist.

## Strengths

- Single-file Swift/AppKit implementation is easy to audit.
- `./run.sh --once` makes status detection testable without opening UI.
- `--debug` reports the selected session, recognized events, and final reason.
- JSONL parsing is defensive and tolerant of schema changes.
- `session_index.jsonl` is no longer a hard dependency for status selection.
- Menu bar, desktop widget, and Pet-style text bubble are separated from the collector/detector logic.
- `CODEX_HOME` support makes fixtures possible.

## Public Files To Keep

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

## Generated Files To Exclude

- `.swift-module-cache/`
- `CodexStatusApp`
- `launcher/Codex Status.app/Contents/MacOS/`
- any generated `.icns` files
- `.DS_Store`
- `*.dSYM/`

## Design Differences From The Original MVP

- Polling is currently 3 seconds by default, not 1.5 seconds. The environment variable can lower it to 1.5 seconds.
- SQLite metadata lookup is not implemented in the restored source. Missing metadata remains `Unknown`.
- The app now includes rate-limit bars, a pseudo desktop widget, and Pet-style stop text, which were added after the original MVP.
- Session selection is mtime-first, with `session_index.jsonl` used only to supplement thread title.

## Remaining Risks

- JSONL event schemas may change, so status detection should continue to be tested with real anonymized fixtures.
- Rate-limit parsing currently expects `payload.rate_limits.primary` and `payload.rate_limits.secondary`.
- Desktop launcher installation generates a local `.app` bundle, but this is not a signed or notarized app.
- There is no formal duplicate-instance guard.
- The app opens `/Applications/Codex.app` directly; non-standard install locations are not handled.

## Recommended Test Matrix

Run these before publishing:

```bash
./scripts/verify.sh
./run.sh --once --debug
git status --short
```

Fixture cases to add:

- missing `session_index.jsonl`
- malformed `session_index.jsonl`
- malformed session JSONL line
- error followed by completion
- waiting for approval
- stale index fallback

## Suggested Release Checklist

- Confirm `git status --ignored` shows generated files as ignored.
- Run `./run.sh --once --debug` against current local data.
- Run fixture tests with `CODEX_HOME`.
- Re-run `./install-desktop-launcher.sh` and double-click the generated Desktop app.
- Launch the menu bar app and confirm Refresh, Open Codex, Desktop Widget toggle, and Quit.
- Update README if SQLite support or icon packaging is added later.

## Upload-Ready State

The intended final local state before GitHub upload is:

- repository initialized on `main`
- generated files ignored
- initial commit created
- worktree clean
- no remote configured until the user creates the GitHub repository
