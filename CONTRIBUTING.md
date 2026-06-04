# Contributing

## Setup

This project intentionally avoids an Xcode project. It builds with the system Swift compiler
on macOS.

```bash
./run.sh --once
```

## Development Commands

```bash
./run.sh
./run.sh --once
./run.sh --once --debug
CODEX_HOME=fixtures/thinking ./run.sh --once --debug
```

## Test Requirements

Run before opening a pull request:

```bash
./scripts/verify.sh
```

The verification script compiles the app, checks several synthetic fixtures, and validates
the launcher `Info.plist`.

## Fixture Rules

- Use synthetic JSONL only.
- Do not include real Codex prompts.
- Do not include real model responses.
- Do not include credentials or private local paths.
- Include malformed JSONL cases when changing parsing behavior.

## Status Detection Rules

- Prefer defensive field inspection over exact schema assumptions.
- Keep `Failed` detection conservative.
- Prefer `Idle` over `Waiting` when uncertain.
- Keep `CODEX_HOME` fixture support working.

## Pull Request Checklist

- `./scripts/verify.sh` passes.
- README and DESIGN are updated for behavior changes.
- No generated binaries or compiler caches are included.
- The app remains read-only with respect to Codex state.

