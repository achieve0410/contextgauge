#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' \
    "usage: scripts/verify.sh" \
    "Audits the publication manifest, then tests and builds macOS and iOS."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
INDEX_DIR="$(mktemp -d -t contextgauge-verify-index.XXXXXX)"
PUBLICATION_ROOT="$(mktemp -d -t contextgauge-verify-source.XXXXXX)"
MAC_DERIVED_DATA="$(mktemp -d -t contextgauge-verify-mac.XXXXXX)"
IOS_DERIVED_DATA="$(mktemp -d -t contextgauge-verify-ios.XXXXXX)"
SWIFT_SCRATCH="$(mktemp -d -t contextgauge-verify-swift.XXXXXX)"

cleanup() {
  rm -rf \
    "$INDEX_DIR" \
    "$PUBLICATION_ROOT" \
    "$MAC_DERIVED_DATA" \
    "$IOS_DERIVED_DATA" \
    "$SWIFT_SCRATCH"
}
trap cleanup EXIT

git \
  --git-dir="$INDEX_DIR/repository.git" \
  --work-tree="$ROOT" \
  init --quiet
git \
  --git-dir="$INDEX_DIR/repository.git" \
  --work-tree="$ROOT" \
  add --all
git \
  --git-dir="$INDEX_DIR/repository.git" \
  --work-tree="$ROOT" \
  checkout-index --all --prefix="$PUBLICATION_ROOT/"

PUBLICATION_COUNT="$(
  git \
    --git-dir="$INDEX_DIR/repository.git" \
    --work-tree="$ROOT" \
    ls-files \
    | wc -l \
    | tr -d ' '
)"
printf 'PUBLICATION_MANIFEST files=%s\n' "$PUBLICATION_COUNT"

"$PUBLICATION_ROOT/scripts/audit-publication.sh" "$PUBLICATION_ROOT"

printf 'SOURCE_FINGERPRINT '
find \
  "$PUBLICATION_ROOT/Package.swift" \
  "$PUBLICATION_ROOT/project.yml" \
  "$PUBLICATION_ROOT/Sources" \
  "$PUBLICATION_ROOT/Tests" \
  "$PUBLICATION_ROOT/scripts" \
  -type f -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | cut -d ' ' -f 1

xcodegen dump --spec "$PUBLICATION_ROOT/project.yml" >/dev/null
xcodegen generate \
  --quiet \
  --spec "$PUBLICATION_ROOT/project.yml" \
  --project "$PUBLICATION_ROOT"

PROJECT_PATH="$(
  find "$PUBLICATION_ROOT" -maxdepth 1 -name '*.xcodeproj' -print -quit
)"
if [[ -z "$PROJECT_PATH" ]]; then
  printf 'FAIL XcodeGen did not create a project\n' >&2
  exit 1
fi

DEBUG_SETTINGS="$(
  xcodebuild -showBuildSettings \
    -project "$PROJECT_PATH" \
    -scheme TokenHubMac \
    -configuration Debug
)"
RELEASE_SETTINGS="$(
  xcodebuild -showBuildSettings \
    -project "$PROJECT_PATH" \
    -scheme TokenHubMac \
    -configuration Release
)"

case "$DEBUG_SETTINGS" in
  *"CODE_SIGNING_ALLOWED = NO"*"ENABLE_HARDENED_RUNTIME = NO"*) ;;
  *) printf 'FAIL unexpected Debug security settings\n' >&2; exit 1 ;;
esac
case "$RELEASE_SETTINGS" in
  *"CODE_SIGNING_ALLOWED = YES"*"ENABLE_HARDENED_RUNTIME = YES"*) ;;
  *) printf 'FAIL unexpected Release security settings\n' >&2; exit 1 ;;
esac

swift test \
  --package-path "$PUBLICATION_ROOT" \
  --scratch-path "$SWIFT_SCRATCH"

xcodebuild -quiet test \
  -project "$PROJECT_PATH" \
  -scheme TokenHubMac \
  -destination platform=macOS \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet build \
  -project "$PROJECT_PATH" \
  -scheme TokenHubMac \
  -configuration Release \
  -destination platform=macOS \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

SIMCTL="$DEVELOPER_DIR/usr/bin/simctl"
if [[ ! -x "$SIMCTL" ]]; then
  printf 'FAIL simctl not found at %s\n' "$SIMCTL" >&2
  exit 1
fi
IOS_DEVICE_ID="$(
  "$SIMCTL" list devices available --json \
    | /usr/bin/python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
raise SystemExit("no available iPhone Simulator")
'
)"
IOS_DESTINATION="platform=iOS Simulator,id=$IOS_DEVICE_ID"

xcodebuild -quiet test \
  -project "$PROJECT_PATH" \
  -scheme TokenHubiOS \
  -destination "$IOS_DESTINATION" \
  -derivedDataPath "$IOS_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet build \
  -project "$PROJECT_PATH" \
  -scheme TokenHubiOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$IOS_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

IOS_APP="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/ContextGauge.app"
if [[ ! -d "$IOS_APP" ]]; then
  printf 'FAIL iOS app not found at %s\n' "$IOS_APP" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :UILaunchScreen' \
  "$IOS_APP/Info.plist" >/dev/null
then
  printf 'FAIL iOS app is missing UILaunchScreen metadata\n' >&2
  exit 1
fi

printf 'VERIFY_PASS\n'
