# Security Policy

## Supported Versions

The current `0.x` release line receives security fixes.

## Reporting Vulnerabilities

Use GitHub Security Advisories when enabled. If advisories are not enabled, open an issue
that describes the impact without including private logs, credentials, or exploit payloads.

## Privacy Design

Codex Status Menubar is local-only and read-only. It reads local Codex JSONL state, extracts
status metadata, and renders a local menu bar UI.

## Files Read

The app reads:

- `$CODEX_HOME/session_index.jsonl`
- `$CODEX_HOME/sessions/**/*.jsonl`

If `CODEX_HOME` is not set, `$HOME/.codex` is used.

## Data Handling Policy

- Do not write to `$CODEX_HOME`.
- Do not modify Codex app bundles or Pet files.
- Do not send data over the network.
- Do not commit real Codex session logs.
- Do not include prompts, model responses, credentials, or raw private logs in fixtures.

## Generated Files

Local build outputs, compiler caches, generated app executables, and local reports must stay
out of Git.

