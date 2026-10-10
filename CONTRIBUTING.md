# Contributing to Tokenz

Bug reports, documentation improvements, and focused pull requests are welcome.
For larger features or changes to usage accounting, open an issue first to
discuss the expected behaviour.

## Local setup

Use a Mac running macOS 14 or later with Swift 6 and the Xcode command line
tools. The project uses Swift Package Manager and has no third-party package
dependencies.

Fork and clone the repository, create a branch for your change, then run:

```sh
./scripts/test.sh
./scripts/build.sh
open dist/Tokenz.app --args --show
```

The build script generates the icon, builds the release executable, bundles
resources, and ad-hoc signs `dist/Tokenz.app`. If Tokenz is already running,
quit it before opening the rebuilt app.

For a regular preview window, use:

```sh
open dist/Tokenz.app --args --preview
```

To inspect usage numbers without opening the UI:

```sh
dist/Tokenz.app/Contents/MacOS/Tokenz --diagnose
```

Actual usage requires local Claude Code or Codex session logs. See the
[README](README.md) for folder settings and the Claude percentage feed.

## Project layout

- `Sources/UsageCore/`: parsing, incremental scanning, token accounting,
  quota windows, and activity aggregation.
- `Sources/Tokenz/`: the native app, menu bar rendering, panel, and preferences.
- `Tests/UsageCoreTests/`: accounting, parser, scanner, and calendar tests.
- `Resources/`: app artwork and bundle metadata.
- `scripts/`: testing, icon generation, app packaging, and the Claude status-line
  script that feeds plan percentages.

## Making changes

Keep pull requests focused and match the surrounding Swift style. Put usage
calculations in `UsageCore` so they can be checked independently of the UI.

Preserve these behaviours when changing accounting or display logic:

- Totals must not count cached tokens, repeated messages, or copied session
  history twice. Codex reasoning tokens are already part of output.
- Today and rolling periods use the Mac's calendar and timezone, including
  daylight-saving transitions.
- Menu bar providers sit side by side, with a 5-hour percentage beside each
  symbol and a weekly underline below. Hide the number for missing or expired
  5-hour readings and rounded zero; shrink the item instead of leaving a gap.
  Never substitute weekly usage for the number. Dotted underlines distinguish
  unavailable weekly readings from reported zero. Hover details retain exact
  values, resets, and report timestamps.
  Show a provider when its desktop app is installed or its session logs or
  plan feed exist, and retain a Tokenz icon when neither is found. Do not
  discard local session history based on installation status.
  Keep the group 22 points high with 2-point corners and 2.5-point underlines.
  Resolve colors from the menu bar appearance: green below 70%, orange from
  70% to under 90%, and red from 90%. Provider symbols match the active weekly
  underline colour, or remain neutral when weekly usage is unavailable.
  A reported weekly zero keeps the symbol green. Status colors
  must remain readable in light, dark, and highlighted states.
- Keep scanning incremental and preserve the five-minute refresh interval.
- Keep usage local. Avoid reading authentication files, making network calls,
  or retaining conversation content. `scripts/test.sh` fails on networking code.
- Write Claude's settings only on explicit confirmation: back up an existing
  `settings.json` first, keep its formatting, and never replace a status line
  the user already has. The logic is `UsageCore/ClaudeStatusLineSetup.swift`,
  tested in `Tests/UsageCoreTests/ClaudeStatusLineSetupTests.swift`.

Use small synthetic JSON fixtures for parser tests. Do not commit personal
session logs, credentials, private paths, or screenshots containing sensitive
information. `.build/` and `dist/` are generated outputs and are ignored.

## Validation and pull requests

Run `./scripts/test.sh` for code changes and `./scripts/build.sh` for app or
resource changes. Add regression tests for accounting, parsing, or calendar
bugs. For documentation-only changes, check the instructions and links.

For UI changes, inspect the panel and menu bar in light and dark appearances,
including loading, unavailable data, expired limits, and warning states where
relevant. Confirm that controls retain tooltips and accessible labels. Include
screenshots when they help a reviewer assess the change.

In your pull request, describe the problem, resulting behaviour, and validation
performed. Mention any limitations or checks you could not complete. Update
the README when setup or user-visible behaviour changes.

## Reporting bugs

Include your macOS version, steps to reproduce, expected and actual behaviour,
and which provider and period are affected. For parsing issues, provide a
minimal synthetic or redacted example that preserves the relevant numeric
fields. Review diagnostic output and screenshots before sharing them.

## License and assets

Original contributions are licensed under the project's [MIT license](LICENSE).
By submitting a contribution, you agree to make it available under that license.

Tokenz ships no third-party logos or trademarks: providers are marked with SF
Symbols. Do not add provider logos, and document the source of any new asset.
