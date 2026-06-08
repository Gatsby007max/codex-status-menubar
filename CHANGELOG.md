# Changelog

## 0.1.0 - Unreleased

- Added native Swift/AppKit menu bar status utility.
- Added `--once` JSON snapshot mode.
- Added `--debug` diagnostics.
- Added read-only `CODEX_HOME` fixture support.
- Added rate-limit remaining display for 5h and 7D windows.
- Added pseudo desktop widget toggle.
- Added Pet-style stop text bubble.
- Added GitHub-ready documentation, fixtures, CI, and verification script.
- Moved periodic status collection off the AppKit main thread to avoid UI freezes while
  scanning larger local Codex session files.
- Added incremental parsing for appended session JSONL data to avoid reparsing the full
  active session file on each refresh.
