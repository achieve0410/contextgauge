# ContextGauge

ContextGauge is a local-first macOS and iOS dashboard for AI coding-agent
usage. The macOS menu-bar app reads Senpi, Codex CLI, and Claude Code metadata,
normalizes token and cost totals locally, and can sync aggregate-only records
through the user's private CloudKit database. The iOS app is read-only.

ContextGauge does not persist or sync prompt or response bodies.

## Status

ContextGauge is pre-1.0 software intended for source-based local development.
It is not an official OpenAI, Anthropic, Senpi, or Apple product.

Signed and notarized app downloads are not published yet. Clone the repository
and build the app with Xcode using the instructions below.

## Requirements

For the macOS app and CLI:

- macOS 14 or later
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later

For full contributor verification:

- an iOS 17 or later Simulator runtime matching Xcode
- [Gitleaks](https://github.com/gitleaks/gitleaks) 8.30 or later

An Apple Developer team and private CloudKit container are optional. They are
required only for real CloudKit sync or deployment to a physical Apple device.

## Quick start: macOS app

```bash
git clone https://github.com/achieve0410/contextgauge.git
cd contextgauge
brew install xcodegen
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
open ContextGauge.xcodeproj
```

In Xcode:

1. Select the internal `TokenHubMac` scheme.
2. Select **My Mac** as the destination.
3. Choose **Product > Run**.

The unsigned local Debug app appears in the menu bar. No Apple Developer
account or CloudKit setup is needed to view local usage. An app started with
**Product > Run** belongs to Xcode's debug session and may stop when that
session or Xcode exits.

To use ContextGauge without keeping Xcode open, build a standalone local
Release app from Terminal instead:

```bash
xcodegen generate --spec project.yml --project .
xcodebuild \
  -project ContextGauge.xcodeproj \
  -scheme TokenHubMac \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Launch the resulting app independently:

```bash
open build/DerivedData/Build/Products/Release/ContextGauge.app
```

You may copy `ContextGauge.app` to `/Applications` before launching it. Once
started this way, the app runs independently of Xcode. This local build is
ad-hoc signed, not Developer ID signed or notarized, and is intended for use
on the Mac that built it.

If the full Xcode installation is already selected, the `xcode-select` command
can be skipped. Check with:

```bash
xcode-select -p
```

## First launch and usage data

ContextGauge reads existing local usage metadata from:

- Senpi: `~/.senpi/agent/sessions`
- Codex CLI: `~/.codex/sessions`
- Claude Code: `~/.claude/projects`

Run the corresponding coding agent at least once before expecting usage.
ContextGauge does not install or sign in to those tools. An empty dashboard is
expected when no supported session metadata exists; choose **Refresh** after
new activity.

Live quota is optional. Enable it in **Settings > Live Quota** only if you
consent to ContextGauge reading locally installed CLI credentials for the
selected provider. Access tokens are not written to the usage database or
CloudKit.

## Quick start: CLI

From the cloned repository:

```bash
swift run contextgauge --help
swift run contextgauge collect
```

The CLI uses the same default roots and local database as the macOS app.

Select the full Xcode installation before building:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build and verify all platforms

```bash
brew install gitleaks xcodegen
scripts/verify.sh
```

`scripts/verify.sh` creates an isolated Git manifest, audits it, runs Swift
tests, tests and builds the macOS app, and tests and builds the iOS app. A
successful run ends with:

```text
VERIFY_PASS
```

`project.yml` is the Xcode source of truth. Generated `.xcodeproj` files and
Xcode user state are not tracked. Open `ContextGauge.xcodeproj` after running
XcodeGen. The internal schemes remain `TokenHubMac` and `TokenHubiOS` for
source compatibility.

## Run the apps

### macOS

For development, generate `ContextGauge.xcodeproj` with XcodeGen and run the
internal `TokenHubMac` scheme on My Mac. For normal local use without an Xcode
debug session, follow the standalone Release build instructions above.

The app appears in the menu bar. Release builds enable hardened runtime. The
current app is intentionally not sandboxed because automatic local-log and
explicit-consent credential discovery require broader file access.

### iOS

1. For a simulator-only UI run, generate the project and select the internal
   `TokenHubiOS` scheme.
2. For real CloudKit sync or a physical device, configure signing and
   CloudKit placeholders as described below.
3. Run on an iPhone or matching simulator.

The iOS app reads aggregate records only. It does not collect local coding
agent logs or provider credentials. With example CloudKit values, the
simulator UI can launch but real aggregate sync is unavailable.

## CLI

The public CLI executable is `contextgauge`; its Swift target remains
`TokenHubCLI`. See the quick start above.

Use `--database`, `--senpi-root`, `--codex-root`, and `--claude-root` to point
at synthetic or explicitly selected inputs. CSV export is local and explicit.
Never attach real exports to public issues.

For persisted-data compatibility, the default local database remains:

```text
~/Library/Application Support/TokenHub/usage.sqlite
```

The legacy directory name is intentional and prevents existing local history
from disappearing during the public product rename.

## Apple and CloudKit configuration

The repository contains non-deployable examples:

- bundle prefix: `com.example.contextgauge`
- CloudKit container: `iCloud.com.example.ContextGauge`
- development team: empty

For real CloudKit sync or physical-device use:

1. Create macOS and iOS App IDs under your Apple Developer team.
2. Create one CloudKit container for the two apps.
3. Replace the example bundle IDs and container in your local `project.yml`
   and entitlement files.
4. Set your local development team.
5. Regenerate the Xcode project.

Do not commit real team IDs, provisioning profiles, certificates, private
keys, or private CloudKit identifiers.

## Data and privacy

ContextGauge may process:

- token counts and cache-token counts;
- provider and model identifiers;
- timestamps and deterministic event identifiers;
- estimated USD cost;
- quota percentage and reset timestamps;
- pseudonymous account IDs and device IDs;
- user-provided device display names.

ContextGauge does not retain prompt or response content. Collectors parse only
the fields required for usage aggregation. Errors are reduced to bounded
codes, and quota snapshots do not persist access tokens.

Local SQLite and private CloudKit aggregate records are still sensitive.
Protect the host account, CloudKit account, and database backups accordingly.

## Publication safety

Run the adversarial audit proof directly:

```bash
scripts/audit-publication.sh --self-test
```

It proves a synthetic private-key marker and absolute home path are rejected,
then proves the cleaned fixture passes. The public Git manifest excludes
internal agent state, generated output, Xcode user state, raw logs, databases,
CSV exports, screenshots, credentials, signing material, and real evidence.

See [SECURITY.md](SECURITY.md) for private reporting and the complete boundary.

## Architecture

The internal `TokenHubCore` and `TokenHubMacCore` module names are retained to
avoid a high-risk source and persisted-data migration during the product
rename. See [DESIGN.md](DESIGN.md) for the interface, privacy, and security
contract.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Contributions must use synthetic
fixtures and pass `scripts/verify.sh`.

## License

ContextGauge is available under the [MIT License](LICENSE). Adapted
MIT-licensed work and attribution are documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
