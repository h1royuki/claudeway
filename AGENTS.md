# Contributor and coding-agent instructions

## Project
Native macOS menu-bar utility, Swift 5.9+, AppKit, macOS 13+. The interface is
localized in English, Russian and Belarusian. `SwitcherCore` contains storage, authentication, history and
usage logic; `Claudeway` contains the UI and process lifecycle. There are
no third-party Swift dependencies. Keep the app small and the account rows compact.

## Commands
- `./test.sh` — standalone test runner; full Xcode/XCTest is not required.
- `./build.sh` — native app in `dist/Claudeway.app`.
- `ARCHS="arm64 x86_64" ./build.sh` — universal build.
- `python3 scripts/privacy_audit.py` — inspect publishable repository files.
- `./scripts/release.sh` — package a clean, tagged commit; see `docs/releasing.md`.

## Data boundaries
- Tests must use temporary directories, synthetic identities and fake credentials.
- Never read the developer's live Keychain, Claude profiles, conversations or
  account data as part of a test, CI run, screenshot or release build.
- Never launch or switch the developer's real Claude Desktop without an explicit
  request for a live check. `--demo` uses disposable data and a simulated lifecycle.
- Do not commit credentials, runtime files, local paths, live transcripts, account
  identifiers, screenshots of real accounts, or detailed personal test reports.
- OAuth client IDs in `UsageClient.swift` are public application identifiers, not
  account IDs or secrets. Test fixture IDs are intentionally synthetic.

## Invariants
- Close Claude gracefully before touching live auth/history files; stop after
  30 seconds without force-killing Desktop or its tasks.
- Account removal forgets the list entry only; preserve Desktop login, chats and
  recovery snapshots. Empty lists and untracked active logins must survive restart.
- Keep the shared Desktop root stable. Switch only validated encrypted auth state;
  preserve original permissions, the exclusive store lock, recovery and rollback.
- Never log tokens or place them in argv/files. Keychain reads and decryption stay
  in memory. Background work must not cause repeated permission prompts.
- Verify account and organization before querying usage or triggering inference.
  No redirects of authorization; no refresh-token rotation or authentication fallback.
- CLI triggers use the signed official binary, isolated config, a clean environment,
  no tools/plugins/MCP/hooks, no transcript persistence, and a durable send barrier.
- Auto-triggering uses fresh successful server samples. Missing/failed/stale data
  must not be treated as an idle window. Keep retry/backoff and duplicate protection.
- Share only whitelisted local chat fields. Preserve target grants. Deleted, remote,
  malformed and conflicting records remain excluded. Never edit transcript contents.
- Apply the saved project filter to imports and updates alike. Never delete existing
  chats when a project is excluded; invalid transfer settings must fail closed.
- Show transfer notifications only after successful completion and positive changes.

## Changes and validation
Keep interface strings in `Sources/SwitcherCore/Resources/{en,ru,be}.lproj/Localizable.strings`.
Use English source keys with `L10n.text`; translate all catalogs together and keep
format placeholders identical. Never translate user-defined account names or server
model names. Stored trigger messages use canonical English keys; legacy Russian
labels translate only at display time without changing recovery/send-barrier state.
Use a temporary UserDefaults suite in tests, never the user's real preferences.

Use focused tests for changed behavior. Run the suite for core/storage changes
and compile AppKit changes. Do not add tests that only duplicate a literal UI label.
Keep release docs truthful about tests actually run; Intel cross-compilation is
not an Intel runtime test. Update the plist version/build, changelog and release
notes together for a new release. Do not overwrite an existing release tag.
Use `AGENTS.md` (canonical spelling) for agent instructions.
