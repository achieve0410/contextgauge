#!/usr/bin/env bash
set -euo pipefail

failures=0
self_test_fixture=""

fail() {
  printf 'PUBLICATION_AUDIT_FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

scan_publication_tree() {
  local root="$1"
  local relative
  local path

  root="$(cd "$root" && pwd)"
  failures=0

  for relative in \
    .omo \
    .senpi \
    .build \
    .swiftpm \
    build \
    DerivedData \
    .debug \
    .debug-journal.md \
    OMON_IMPLEMENTATION_REQUEST.md \
    docs/evidence
  do
    if [[ -e "$root/$relative" ]]; then
      fail "denied path: $relative"
    fi
  done

  while IFS= read -r -d '' path; do
    relative="${path#"$root"/}"
    case "$relative" in
      .git/*)
        continue
        ;;
      Tests/*/Fixtures/*.jsonl)
        ;;
      *.jsonl|*.csv|*.db|*.db-*|*.log|*.mdb|*.sqlite|*.sqlite-*|*.trace)
        fail "private data file: $relative"
        ;;
      *.key|*.p8|*.p12|*.pem|*.mobileprovision|*/auth.json|*/.credentials.json)
        fail "credential or signing file: $relative"
        ;;
      *.o|*.d|*.dia|*.pcm|*.swiftdeps|*.swiftmodule|*.swiftsourceinfo)
        fail "compiler artifact: $relative"
        ;;
      *.xcuserstate|*/xcuserdata/*)
        fail "Xcode user state: $relative"
        ;;
    esac
  done < <(find "$root" -type f -print0)

  while IFS= read -r -d '' path; do
    fail "symlink requires explicit review: ${path#"$root"/}"
  done < <(find "$root" -type l -print0)

  while IFS= read -r -d '' path; do
    fail "file exceeds 1 MiB: ${path#"$root"/}"
  done < <(find "$root" -type f -size +1M -print0)

  if rg -l --hidden \
    --glob '!.git/**' \
    --glob '!**/scripts/audit-publication.sh' \
    '(/Users/[[:alnum:]_.-]+|/home/[[:alnum:]_.-]+|file:///Users/)' \
    "$root" >/dev/null
  then
    fail "absolute user home path detected"
  fi

  if rg -l --hidden \
    --glob '!.git/**' \
    --glob '!**/scripts/audit-publication.sh' \
    'wonhyo' \
    "$root" >/dev/null
  then
    fail "private workstation username detected"
  fi

  if rg -l --hidden \
    --glob '!.git/**' \
    --glob '!CODE_OF_CONDUCT.md' \
    '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[A-Za-z]{2,}' \
    "$root" >/dev/null
  then
    fail "email address detected"
  fi

  if rg -l --hidden \
    --glob '!.git/**' \
    --glob '!**/scripts/audit-publication.sh' \
    '(BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[opusr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})' \
    "$root" >/dev/null
  then
    fail "high-confidence credential pattern detected"
  fi

  if [[ -f "$root/project.yml" ]]; then
    if rg -n 'DEVELOPMENT_TEAM:[[:space:]]*"?[A-Z0-9]{10}"?' \
      "$root/project.yml" >/dev/null
    then
      fail "non-placeholder Apple development team detected"
    fi
    if rg -n 'iCloud\.(?!com\.example\.ContextGauge)' \
      --pcre2 "$root/project.yml" >/dev/null
    then
      fail "non-placeholder CloudKit container detected"
    fi
  fi

  while IFS= read -r -d '' path; do
    case "$(file -b "$path")" in
      Mach-O*|ELF*|PE32*|"current ar archive"*|SQLite*|data)
        fail "binary or database artifact: ${path#"$root"/}"
        ;;
    esac
  done < <(find "$root" -type f -print0)

  if ! command -v gitleaks >/dev/null 2>&1; then
    fail "gitleaks is required"
  elif ! gitleaks detect \
    --no-banner \
    --no-git \
    --redact \
    --source "$root" >/dev/null
  then
    fail "gitleaks detected a secret candidate"
  fi

  if ((failures > 0)); then
    return 1
  fi

  printf 'PUBLICATION_AUDIT_PASS root=%s\n' "$root"
}

cleanup_self_test() {
  if [[ -n "$self_test_fixture" ]]; then
    rm -rf "$self_test_fixture"
  fi
}

self_test() {
  local fixture
  fixture="$(mktemp -d -t contextgauge-publication-audit.XXXXXX)"
  self_test_fixture="$fixture"
  trap cleanup_self_test EXIT

  printf '# Synthetic publication fixture\n' >"$fixture/README.md"
  scan_publication_tree "$fixture"

  printf '%s\n' \
    '/Users/wonhyo/private/session.jsonl' \
    '-----BEGIN PRIVATE KEY-----' \
    >"$fixture/privacy-probe.txt"
  if scan_publication_tree "$fixture" >/dev/null 2>&1; then
    printf 'PUBLICATION_AUDIT_SELF_TEST_FAIL mutation accepted\n' >&2
    return 1
  fi
  printf 'PUBLICATION_AUDIT_SELF_TEST_MUTATION_REJECTED\n'

  rm "$fixture/privacy-probe.txt"
  scan_publication_tree "$fixture"
  printf 'PUBLICATION_AUDIT_SELF_TEST_PASS\n'
  rm -rf "$fixture"
  self_test_fixture=""
  trap - EXIT
  printf 'cleanup: rm -rf %s\n' "$fixture"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

target="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
scan_publication_tree "$target"
