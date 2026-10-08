# Architecture

## Modules

`SwitcherCore` owns profile state, encrypted snapshots, recovery journals, local
history reconciliation, usage parsing/polling and the CLI trigger engine.
`Claudeway` owns the AppKit menu, account workflows, process lifecycle,
settings window and native transfer notifications.

## Switching

A store lock prevents competing writers. Claude Desktop and its child processes
must stop gracefully within 30 seconds. Normal switching preserves the shared
Desktop root and replaces only validated authentication/browser-state components.
A durable journal records source and destination before changes. Recovery before
commit restores the source; after commit it retains the destination. Snapshots and
metadata backups are retained for recovery. Selecting the current account only
shows Desktop and does not repeat a transfer notification.

Legacy isolated profiles migrate into a shared workspace using the chosen base
profile's settings; backups retain the original data. There are no hardcoded user
profile UUIDs, account names or project paths in the migration logic.

## History

Conversation content remains in `~/.claude/projects`. Per-account Desktop list
records are reconciled using a fixed whitelist, newer activity and deletion markers.
An unfinished record can qualify through a real matching local JSONL message when
`completedTurns` is missing or zero. That read checks session identity, cwd, regular
files and bounded input, and does not modify the transcript.

New imports use manual permissions; existing destination grants/connectors remain
local. Worktree name/path and branch metadata are shared, not git working-tree
contents. Remote, deleted, ambiguous or conflicting records are excluded.

## Usage and window starts

Saved credentials are bound to account, organization, API origin and OAuth scopes.
Public OAuth client IDs and synthetic test IDs are intentional source constants.
Server identity is checked before usage. Local usage history is only a fallback;
it cannot provide a trigger decision. Cached data never becomes an invented reset.

A successful usage-refresh callback feeds fresh samples to the auto-trigger engine.
Selected idle five-hour windows are rechecked before one small CLI request. A
known future reset or a pending durable send barrier blocks duplicate requests.
The CLI result's usage refresh does not recursively enqueue another trigger.
A delayed result is reconciled; an uncertain request is held for five hours before
a fresh idle sample may permit a new attempt. Polling and triggers respect backoff.
There is no calendar schedule or once-per-day restriction.

## Files

Application Support contains profile state, encrypted auth snapshots, recovery
journals, private usage statistics, trigger preferences and metadata backups.
Only runtime code reads those locations. Build, test and publication scripts use
repository files and synthetic temporary data; they never copy runtime data.

## Validation boundaries

Automated tests cover state transitions and failures on synthetic data. They do
not prove UI behavior, every Desktop version, sleep/wake, real account continuation,
notification delivery or Keychain prompts. Those require a separately authorized
manual check on a supported Mac. Do not publish the resulting personal test records.
