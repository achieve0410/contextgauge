# Changelog

All notable ContextGauge changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Native macOS menu-bar dashboard and read-only iOS dashboard.
- Local Senpi, Codex CLI, and Claude Code usage collection.
- Local SQLite aggregation and private CloudKit aggregate sync.
- Explicit-consent live quota support with sanitized failure reporting.
- Publication audit, synthetic fixtures, cross-platform verification, and OSS
  governance files.

### Changed

- Public product identity selected as ContextGauge.
- iOS credential-path compilation now uses a platform-safe home fallback.
- Snapshot and UI tests no longer read real logs or write repository evidence.

### Security

- Internal agent state, generated outputs, logs, databases, exports,
  screenshots, credentials, and Xcode user state are excluded from the public
  manifest.

No public release has been published yet.
