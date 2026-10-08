# Changelog

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
