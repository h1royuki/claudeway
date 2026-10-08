# Contributing

Use macOS 13+ and Swift 5.9+. Start with [AGENTS.md](AGENTS.md) and
[the architecture](docs/architecture.md). Keep changes focused and preserve the
existing compact menu. The app UI is Russian; developer documentation is English.

Before a pull request:

```sh
./test.sh
./build.sh
python3 scripts/test_privacy_audit.py
python3 scripts/privacy_audit.py
python3 scripts/privacy_audit.py --artifacts "dist/Claudeway.app"
```

The custom assertion runner currently covers 53 test groups, including auth-journal
crashes, migrations, local chat transfer, API identity checks, polling, automatic
window starts and notification filtering. Tests must remain offline and synthetic.
Never run a live auth or account-switch test against someone else's data.

Explain the behavior change, relevant tests, compatibility implications and any
manual checks that remain. Do not attach real auth snapshots, transcripts, caches,
profile registries, account screenshots or unsanitized logs to an issue or PR.
Build logs can contain your checkout path; inspect them before sharing.

For a bug report, include app/macOS/Claude versions, expected and actual behavior,
and minimal synthetic steps. Security issues belong in private reporting as
explained in [SECURITY.md](SECURITY.md), not public issues.

By contributing, you agree that your contribution is distributed under the
repository's MIT license. Do not add assets or code whose licensing is incompatible.
