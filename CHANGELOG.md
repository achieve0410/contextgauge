# Changelog

All notable ContextGauge changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.2.0] - 2026-08-12

### Added

- Native macOS menu-bar dashboard and read-only iOS dashboard.
- Local Senpi, Codex CLI, and Claude Code usage collection.
- Local SQLite aggregation and private CloudKit aggregate sync.
- Explicit-consent live quota support with sanitized failure reporting.
- Period comparison and token-composition insights in the macOS dashboard.
- Actionable empty-state and provider-specific collection diagnostics.
- Publication audit, synthetic fixtures, cross-platform verification, and OSS
  governance files.

### Changed

- Public product identity selected as ContextGauge.
- iOS credential-path compilation now uses a platform-safe home fallback.
- Snapshot and UI tests no longer read real logs or write repository evidence.
- Collection results distinguish successful collection from attempts with errors.

### Fixed

- Senpi, Codex CLI, and Claude Code collectors report semantically malformed
  usage rows instead of silently dropping or zero-coercing them.
- SQLite aggregate and device reads reject interrupted queries instead of
  returning partial results.

### Security

- Internal agent state, generated outputs, logs, databases, exports,
  screenshots, credentials, and Xcode user state are excluded from the public
  manifest.

This is a source-only GitHub checkpoint release. No signed or notarized app,
installer, CLI binary, or other binary asset is attached.

[Unreleased]: https://github.com/achieve0410/contextgauge/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/achieve0410/contextgauge/releases/tag/v0.2.0
