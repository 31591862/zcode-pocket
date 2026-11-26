# Contributing

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Every contribution starts with an issue: that is where a problem is confirmed
and a direction agreed before any code is written. Chinese or English are
both fine.

## About this repository

This project started as a personal one. I built it for my own use, and many
of its settings and details simply follow my own habits and preferences. At
some point it looked useful to others with the same needs, so I decided to
open-source it. By then, though, the development history had grown around my
own work: real project and workspace names, my usage habits, and a few
features set up the way I personally need them, spread across too many files
to rewrite retroactively. Cleaning all of that up would have been a project
of its own, so I drew the boundary at the repository instead. The source is
published here; day-to-day development stays in a separate private
repository, and each release is exported from there.

Everything needed to build, audit and verify the app is published here: the
full source of every release, build instructions, the change log, the signing
fingerprint and checksums, and a public summary of the project's decisions
([docs/decisions.md](docs/decisions.md)). The released APK is built from
this tree, so nothing in the binaries is held back from the source, and each
export is checked for credentials and sensitive strings before it is pushed.

## What that means for contributors

This repository is a snapshot of each release, not a live development
history.

- **A fix written against this tree may not apply, or may already be fixed.**
  Please report bugs as issues; the maintainer reproduces and fixes them in
  the development repository. Analysis, logs and even a patch posted in the
  issue are welcome as references.
- **A merged pull request is re-applied in the development repository before
  the next sync**, so what ships may differ in detail from the pull request.
- **The discussion that shaped the code is summarized, not reproduced**, in
  [docs/decisions.md](docs/decisions.md).

Reports and patches that lead to a change are credited in the release notes.
If something you need in order to evaluate, build or contribute to the app
is missing, please open an issue.

## Reporting an issue

A useful issue explains the problem well enough for someone else to
understand and reproduce it. Please include:

- What you were trying to do, what happened, and what you expected instead.
- Clear steps to reproduce.
- The app version, your device and system version, and the ZCode desktop
  version (the issue form lists these).
- Relevant logs or screenshots.

Remove API keys, tokens, private file paths, and other sensitive information
before attaching logs or screenshots.

For device-specific problems you may be asked to help verify a fix, since
not every device can be tested here.

## Proposing a feature

Open an issue first and describe the problem you want to solve. A proposed
solution is helpful, but explaining the need matters more than prescribing an
implementation, and the current behavior may be intentional — check
[docs/decisions.md](docs/decisions.md) and the `known-limitation` issues
first. Wait for the maintainer to confirm the need and the direction before
implementing.

Changes to the existing interaction and visual design are discussed and
decided there, not taken from pull requests.

An issue is a report, not a commitment to a specific fix or release.

## Pull requests

Once a feature is confirmed in its issue, a pull request for a
self-contained additive feature is welcome and may be merged after review.

- Link the confirmed issue, and keep the pull request to that one feature.
- No new production dependency unless it was agreed in the issue.
- Follow the existing structure and visual language; user-facing strings in
  both Chinese and English; include tests.
- `flutter analyze` and `flutter test` must pass inside `app/`. CI runs both
  plus a debug build and a release compile, on Flutter 3.47.7. (CI needs
  maintainer approval to run for first-time contributors.)
- Describe what changed, why this approach, what you tested, and what you
  did not.
- Title it by what it does: a new capability, or a change in intended
  behavior, is a feature — not a fix.

Pull requests for bugs, or for features whose issue has not been confirmed,
may be closed without review — please open an issue instead.

## Building from source

See the **Build** section in the README (Flutter 3.47.x recommended;
`flutter pub get && flutter build apk --split-per-abi`).

Note: this is an unofficial third-party client. Anything that depends on the
official Web Remote Control protocol may need verification against the
official open-source implementation before it can be implemented here.
