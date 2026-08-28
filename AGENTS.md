# Repository Guidelines

## Project Structure & Module Organization

`sb` is the CLI entry point and loads modules from `lib/`. State, rendering, services, certificates, backups, diagnostics, and tunnels have separate modules. Protocol renderers live in `protocols/`; installation uses `install.sh`/`setup.sh`; architecture notes are in `docs/`. Bash tests are under `tests/` and run directly on the designated remote Debian host (GitHub workflows are not used).

The source of truth is `/etc/sb-manager/state.json` plus protected secret and certificate files. Never edit generated `config.json` as persistent state.

## Build, Test, and Development Commands

- `find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n` — check Bash syntax.
- `shellcheck -x --severity=error sb setup.sh install.sh build-standalone.sh lib/*.sh protocols/*.sh tests/*.sh` — run the shell lint rules when ShellCheck is installed.
- `SBM_TEST_SING_BOX=/path/to/sing-box bash tests/run.sh` — run protocol, rendering, and transaction tests against a real core.
- `SBM_TEST_SING_BOX=/path/to/sing-box bash tests/snell-preview-smoke.sh` — validate Snell v5 with the 1.14+ core.
- `bash tests/firewall-smoke.sh` — exercise isolated protocol-port listing, UFW allow calls, and iptables deny cleanup.
- `bash tests/service-lifecycle.sh`, `bash tests/systemd-exec-smoke.sh`, and `bash tests/subscription-systemd-smoke.sh` — exercise service behavior without changing the host installation.
- `SBM_TEST_SING_BOX_STABLE=/opt/sing-box-1.13.19/sing-box SBM_TEST_SING_BOX_PREVIEW=/opt/sing-box-1.14.0-rc.1/sing-box bash tests/remote-debian13-suite.sh` — run the complete remote acceptance suite.
- `./build-standalone.sh /tmp/sb-manager-install.sh` — build an offline installer; validate it with `bash -n`.

Run installation tests only in a disposable VM or scripts' isolated test modes.

## Coding Style & Naming Conventions

Use Bash with `set -Eeuo pipefail`, two-space indentation, quoted expansions, and `local` variables. Prefer `snake_case` functions and variables; reserve `SBM_*` names for exported configuration paths and runtime settings. Keep protocol logic in `protocols/<name>.sh` and cross-protocol behavior in `lib/`. Use `jq --arg`/`--argjson` to construct JSON instead of string interpolation. Protect mutating operations with `with_lock` and preserve atomic candidate-check-install-rollback behavior.

## Testing Guidelines

Name new tests `tests/<feature>-smoke.sh` or extend `tests/run.sh` for protocol transactions. Cover success, validation failure, rollback, permissions, and both systemd/OpenRC behavior when applicable. Use `mktemp -d`, project-specific `SBM_*` overrides, and cleanup traps; tests must not modify real `/etc` or `/usr/local` state.

## Commit & Pull Request Guidelines

Follow the existing Conventional Commit style: `feat:`, `fix:`, `test:`, or `chore:` followed by an imperative summary. Keep commits scoped and reviewable. Pull requests should explain behavior changes, migration or rollback risk, supported distributions, and commands run. Include terminal output for CLI changes and update `README.md`, `CHANGELOG.md`, `VERSION`, or state documentation when relevant.

## Security & Configuration Tips

Treat backups, exports, API tokens, node credentials, and private keys as secrets. Never commit generated configs or runtime data. Verify downloaded artifacts, retain least-privilege service settings, and do not automatically alter host firewalls.
