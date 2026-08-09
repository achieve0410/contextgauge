# Contributing to ContextGauge

Thanks for helping improve ContextGauge. Contributions must preserve the
project's local-first privacy boundary.

## Prerequisites

- macOS 14 or later
- Xcode 26 with a matching iOS Simulator runtime
- XcodeGen 2.46 or later
- Gitleaks 8.30 or later

Select the full Xcode installation before running UI tests:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Development setup

```bash
xcodegen generate --spec project.yml
scripts/verify.sh
```

`project.yml` is the Xcode source of truth. Generated `.xcodeproj` files and
Xcode user state are intentionally excluded from Git.

The Swift package keeps the internal `TokenHubCore` module name for source and
persisted-data compatibility. Public product surfaces use ContextGauge.

## Privacy rules

- Use only synthetic fixtures under `Tests/**/Fixtures`.
- Never add real JSONL logs, SQLite databases, CSV exports, screenshots,
  account names, credentials, device names, or absolute home paths.
- Do not store or assert prompt or response prose.
- Keep Apple team IDs, bundle IDs, and CloudKit containers as placeholders.
- Run `scripts/audit-publication.sh --self-test` after changing the audit.

## Tests

Behavior changes require a failing test at the affected seam before the
implementation change. Tests must not read a developer's home directory,
depend on existing user defaults, contact live services, write repository
evidence, sleep for timing, or rely on the current date without controlling
the fixture.

Run the canonical gate once:

```bash
scripts/verify.sh
```

It must finish with `VERIFY_PASS`. Do not suppress diagnostics, skip tests, or
add retries to make a failure disappear.

## Pull requests

Keep changes surgical. In the pull request:

- explain the user-visible behavior;
- name the privacy and security impact;
- list exact commands that passed;
- call out any intentionally retained internal `TokenHub` identifier;
- confirm no real user data or credential entered Git history.

By contributing, you agree that your contribution is licensed under the MIT
License in `LICENSE`.
