# Publishing Checklist

This project is prepared for GitHub upload, but publishing itself should be an explicit final
action.

## Before Creating The Repository

```bash
./scripts/verify.sh
git status --short
git log --oneline --max-count=3
```

Confirm that generated files are not staged:

- `.swift-module-cache/`
- `CodexStatusApp`
- `launcher/Codex Status.app/Contents/MacOS/`
- `tmp/`
- `*.dSYM/`

## Suggested Repository Settings

- Name: `codex-status-menubar`
- Visibility: public or private, depending on your intent.
- Description: `Native macOS menu bar utility for read-only local Codex Desktop status and rate-limit visibility.`
- Topics:
  - `codex`
  - `macos`
  - `swift`
  - `appkit`
  - `menubar`
  - `developer-tools`
  - `local-first`
  - `desktop-widget`
  - `rate-limit`
  - `status-monitor`

## Upload Commands

Create an empty GitHub repository first, then run:

```bash
git remote add origin git@github.com:<owner>/codex-status-menubar.git
git push -u origin main
```

If using HTTPS with GitHub CLI:

```bash
gh auth setup-git
git remote add origin https://github.com/<owner>/codex-status-menubar.git
git push -u origin main
```

## After Upload

- Confirm GitHub Actions CI passes.
- Confirm README renders correctly.
- Confirm generated binaries were not uploaded.
- Add repository topics.
- Create a release only after manually launching the app on macOS.

