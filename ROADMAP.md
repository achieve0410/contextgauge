# ContextGauge Roadmap

The roadmap records intended outcomes, not release promises.

## 0.1 — Public source preview

- Publish the audited MIT-licensed source repository.
- Support macOS 14+ and iOS 17+ with Xcode 26.
- Collect Senpi, Codex CLI, and Claude Code usage from local synthetic-tested
  parsers.
- Display token, cost, quota, provider, model, period, and device summaries.
- Sync aggregate-only records through a user-configured private CloudKit
  container.
- Keep prompt and response bodies out of persistence and sync.

## Later candidates

- Sandboxed or helper-based collection that preserves automatic discovery.
- More providers added only with synthetic fixtures and privacy review.
- Signed release artifacts after reproducible release automation exists.
- Optional export formats that remain local and explicit.

## Non-goals

- Hosted telemetry or a project-operated usage backend.
- Uploading raw conversations, prompts, responses, or credential files.
- Billing, invoicing, or claiming provider-authoritative cost totals.
- Official affiliation with OpenAI, Anthropic, Senpi, or any provider.
