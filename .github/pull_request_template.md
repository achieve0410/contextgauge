## Outcome

Describe the user-visible behavior and why this is the smallest correct change.

## Verification

List exact commands and observable results.

```text
scripts/verify.sh
```

## Privacy and security

- [ ] I used only synthetic fixtures.
- [ ] No credential, real log, database, export, screenshot, account/device
      name, email, or absolute home path entered the diff or Git history.
- [ ] I documented any new data, permission, network, storage, signing, or
      CloudKit behavior.
- [ ] `scripts/audit-publication.sh --self-test` passes.

## Compatibility

- [ ] macOS behavior is covered.
- [ ] iOS behavior is covered or unaffected.
- [ ] Any retained `TokenHub` identifier is internal or persisted-data
      compatibility and is explained.
