# ContextGauge Interface Contract

## Product surface

ContextGauge is a local-first macOS menu-bar utility and a read-only iOS
dashboard.
The interface prioritizes numeric readability, explicit privacy state, and
native platform behavior over decorative presentation.

## Visual system

- Use system typography, colors, materials, spacing, controls, and SF Symbols.
- Keep the macOS menu at 420 points wide.
- The menu contains only period/device filters, token and cost totals, usage
  history, and the pinned Refresh / Settings / Quit actions.
- Period choices are Today, Last 7 Days, Last 2 Weeks, Last 1 Month,
  Last 3 Months, Last 6 Months, and Last 1 Year. Every non-Today period is a
  rolling interval ending at tomorrow's start.
- Daily history uses a native bar chart with date on the x-axis and token
  usage on the y-axis.
- Provider consent, account profiles, launch-at-login, synchronization state,
  and collector diagnostics belong in the separate Settings scene.
- Cap menu height at the smaller of 720 points and the shortest active
  display's visible height minus 16 points. The information body scrolls while
  the action footer remains visible.
- Settings uses General, Live Quota, and Diagnostics tabs, is resizable from
  520 x 420 points, and scrolls within each long tab.
- ContextGauge uses regular app activation so its standard application menus are
  visible while the app or Settings is active.
- Use standard `Toggle`, `Picker`, `ProgressView`, `Label`, and
  `ContentUnavailableView` components.
- Do not add gradients, custom shadows, ornamental motion, or custom control
  chrome.
- Status text must remain readable in light and dark appearance and must not
  rely on color alone.

## Live quota consent

- Codex and Claude live quota access is off by default on each Mac.
- Each provider has an independent enable control.
- Enabling requires an explicitly selected private account profile.
- When CloudKit is not configured or unavailable, enabling creates a private
  local 256-bit account pseudonym instead; local quota access must not be
  blocked by optional synchronization.
- Disabled state copy: `Off`.
- Enabled without a profile: `Setup required`.
- Credential or provider failure: sanitized error code and `Unavailable`.
- ContextGauge must not read credential files, query Keychain, or call provider
  endpoints while a provider is disabled.
- Codex setup directs the user to run `codex login`; enabled access reads
  `$CODEX_HOME/auth.json` or `~/.codex/auth.json` and does not copy Codex
  credentials into Keychain.

## Account profiles

- Account profiles use user-created display names and random opaque
  pseudonyms.
- UI never displays access tokens, provider account IDs, email addresses, or
  pseudonyms.
- Switching profiles is explicit and does not delete another Mac's quota.

## Collector setup

- Missing configured root: `Source folder not found`.
- Existing root without JSONL files: `No usage logs found`.
- Partial parsing and unknown pricing remain nonfatal collector warnings.
- Setup actions never create, modify, or delete provider directories.

## Synchronized status

- macOS and iOS distinguish disabled, configuration-required, fresh, stale,
  unavailable, and provider-error states.
- iOS distinguishes never synchronized, no usage for the selection, and
  provider lookup failure.
- Provider status contains only provider, device, opaque account reference,
  timestamps, freshness, and sanitized error code.

## Accessibility

- Every icon-only action has an accessibility label.
- Toggle labels include provider names.
- Status rows include textual state in addition to symbols and colors.
- Controls remain keyboard accessible through native SwiftUI behavior.
- Progress indicators expose numeric accessibility values.

## Motion

Only native SwiftUI state transitions and progress animation are allowed.
No custom motion is introduced.

## Security and accepted debt

- Release is signed and uses Hardened Runtime.
- The macOS collector remains intentionally unsandboxed because it recursively
  reads hidden Senpi, Codex, and Claude directories and interoperates with
  existing credential storage. This is disclosed rather than hidden.
- App Sandbox plus security-scoped bookmarks/helper isolation is deferred
  because it would materially change automatic collection and credential
  access. No temporary file-access, JIT, automation, or library-validation
  exception entitlement is accepted.
- The canonical verifier must test and build every advertised macOS and iOS
  target without exclusions.
