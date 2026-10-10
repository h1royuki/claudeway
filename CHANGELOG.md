# Changelog

## 2.9.0 — 2026-10-10

- Chat transfer settings: all projects, selected projects only, or completely disabled.
- Searchable project list with folder paths, deduplicated local chat counts and saved selections.
- Filters apply to new imports and metadata updates in both directions; existing chats are never removed.
- Worktrees use their recorded origin folder. Unknown future projects require opt-in in selected mode.
- Invalid settings fail closed; selections are stored atomically with private permissions.
- English, Russian and Belarusian UI; synthetic tests for filtering, persistence and project boundaries.

## 2.8.1 — 2026-10-08

- Check Claude Safe Storage access at startup, independently of usage polling and network access.
- Prompt once only when permission is needed; a refusal does not trigger repeated prompts.
- Usage refreshes and CLI preparations are always noninteractive. Access can be retried
  explicitly through the Keychain access menu action.
- Synthetic permission-flow tests cover granted access, refusal, missing items and concurrent requests.

## 2.8.0 — 2026-10-08

- Dedicated Accounts window for adding, renaming, switching and removing accounts.
- Rename inactive accounts without switching; drafts survive background refreshes.
- Empty lists show an entry point to add the first account and stay empty after restart.
- Removal preserves Desktop login, shared chats and recovery backups.
- First-account sign-in and cancellation, plus recoverable switching after removing
  the active account; all new UI translated into English, Russian and Belarusian.

## 2.7.0 — 2026-10-08

- English, Russian and Belarusian interface, including errors, notifications,
  accessibility labels, usage durations and reset dates.
- Settings → Language: System default plus explicit choices, saved between launches
  and applied immediately without restarting Claude.
- Legacy Russian journal messages and cached usage titles follow the selected
  language without changing account names or recovery/duplicate-request state.
- Complete localization catalogs, regression coverage and a packaged-resource check.

## 2.6.0 — 2026-10-08

First publication-ready source and community binary release.

- New Claudeway name throughout the app, executable and release assets; existing
  storage and bundle identity are preserved for upgrades.
- Removed the built-in instruction page and its menu item.
- Menu actions named «Запустить окно лимитов» and «Автозапуск окон».
- Compact usage rows and an active-account side marker.
- Shared Desktop data with recoverable account switching.
- Local Code history reconciliation, including unfinished saved conversations.
- Fresh-usage-driven automatic window starts without a schedule or daily cap.
- Native notifications for actual added/updated conversations only.
- MIT license, contributor/agent guides, privacy audit and release automation.
- Universal build packaging with stripped symbols and mapped source paths.

## Development milestones

- 2.5.2: legacy automation settings migrate without reviving removed schedules.
- 2.5.1: transfer notifications replace the persistent transfer-count menu item.
- 2.5.0: usage-driven window starts replace the morning schedule.
- 2.4.1: unfinished local chats can transfer using transcript evidence.
- 2.4.0: manual and automatic window-start engine with a durable send barrier.
- 2.3.x: compact menu layout and shared application/menu-bar icon identity.
- 2.2.x: live usage and server reset times.
- 2.x: shared local workspace with authentication-only account switching.

These milestones describe development history; older releases are not published
or reconstructed by this repository.
