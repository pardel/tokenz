# Changelog

Versions follow semantic versioning while the project is pre-1.0: a minor
bump for new features, a patch bump for fixes. `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml` carry the version and the build
number. `scripts/release.sh` takes a version's release notes from its
section here.

## 0.1.0 · 2026-10-10

First public release.

- Menu bar readings for Claude Code and Codex: a 5-hour plan percentage
  beside each provider's symbol and a weekly usage underline, green, orange
  or red by level. A missing or expired reading shows as missing, never as
  zero.
- A provider appears when its desktop app is installed or its session logs
  or plan feed exist, so the command-line tool alone is enough.
- Token totals for today, seven days and the last 30 days from local
  `~/.claude/projects` and `~/.codex/sessions` logs, counting copied,
  resumed and forked sessions once, with an activity chart and CSV export.
- Codex plan limits from its own logs. Claude plan limits through a status
  line: Settings sets it up on request (backing up `settings.json`, never
  replacing a status line you already have) or shows the line to add to
  your own.
- Local only: no network requests, no API keys, no conversation content
  kept. `scripts/test.sh` fails if networking code appears.
- Universal build for macOS 14 or later, signed with a Developer ID and
  notarised. Xcode project generated from `project.yml`, and a Homebrew
  release script.
