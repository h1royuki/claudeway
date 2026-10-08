# Security policy and data handling

## Reporting

Use GitHub's private **Report a vulnerability** feature in this repository's
Security tab when enabled. If it is unavailable, open an issue asking the
maintainer for a private contact **without including the vulnerability details or
any private account data**. Maintainers should enable private vulnerability reporting
before making the repository public. There is no promised response-time SLA.

Only the latest release is intended to receive fixes. Older builds may be
incompatible with newer Claude Desktop storage.

## Sensitive data

The app reads Claude Desktop's existing encrypted authentication and, for usage
and optional CLI requests, the `Claude Safe Storage` Keychain item. It decrypts
credentials in memory and verifies the account/organization against Anthropic.
Saved auth snapshots preserve the original encrypted data; no new plaintext token
store is introduced. The app does not rotate refresh tokens.

Usage requests use an ephemeral URLSession without cookies/disk cache and refuse
redirects. Optional inference uses the signed official native Claude Code binary,
an isolated config directory, a clean environment, no tools/customizations and no
session persistence. A token is passed only in that child process's environment.
This is not protection against another process already able to inspect the user's
memory or Keychain.

Do not upload runtime data from `~/Library/Application Support/ClaudeSwitcher` or
`~/Library/Application Support/Claude`, `~/.claude/projects`, Keychain exports,
Cookies, LevelDB/SQLite stores, or real account screenshots. Runtime files are
excluded by repository rules but a `.gitignore` is not a security boundary.

## Boundaries

- One macOS user owns the shared files. Account switching does not sandbox files
  or enforce a corporate separation between accounts.
- Cloud Chat, Cowork ownership, grants, connectors and organization policy are not
  transferred by local history reconciliation.
- The utility depends on undocumented formats/endpoints and legacy Keychain APIs.
  Keep recovery backups and review changes after Desktop updates.
- Release ZIPs are ad-hoc signed, not notarized. SHA-256 checksums check integrity,
  not publisher identity. No signing certificates, private keys or live credentials
  are included in this repository.

The offline publication guard finds common leak patterns; it is not a complete
secret detector or an independent security assessment. See
[the audit scope](docs/privacy-audit.md).
