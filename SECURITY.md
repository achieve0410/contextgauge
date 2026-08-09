# Security Policy

## Supported versions

ContextGauge is pre-1.0 software. Security fixes are applied to the default
branch and the latest tagged release only.

## Reporting a vulnerability

Use
[GitHub private vulnerability reporting](https://github.com/achieve0410/contextgauge/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Never attach real Senpi, Codex CLI, or Claude Code logs. Do not include access
tokens, cookies, Apple signing material, CloudKit identifiers, database files,
screenshots, exports, account names, or absolute home-directory paths. Create
the smallest synthetic reproduction instead.

If a report accidentally contains a credential, revoke or rotate it before
submitting the report and state that rotation is complete. The maintainers
will acknowledge a report within seven days and will coordinate disclosure
after a fix is available.

## Security boundary

ContextGauge intentionally reads local coding-agent metadata on macOS. The
current macOS app is not sandboxed because automatic collection requires
access to user-selected local log locations. Release builds enable hardened
runtime, but users should treat the app and its local database as sensitive.

The project:

- parses token counts, model identifiers, timestamps, quota data, and
  estimated cost;
- does not persist or sync prompt or response bodies;
- stores normalized usage in a local SQLite database;
- uses only a user's private CloudKit database when sync is configured;
- reads provider credentials only after explicit live-quota consent;
- never includes real credentials, logs, databases, exports, screenshots, or
  signing identifiers in the public repository.

The checked-in bundle IDs, development team, and CloudKit container are
non-deployable examples. Replace them locally and keep real values out of
version control.

## Publication checks

Run both checks before proposing a release:

```bash
scripts/audit-publication.sh --self-test
scripts/verify.sh
```

The first command proves the audit rejects a synthetic private-key and local
home-path mutation. The second audits an isolated Git manifest before running
the full Swift, macOS, and iOS gates.
