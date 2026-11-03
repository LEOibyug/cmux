# cmux personal

Personal macOS fork of [cmux](https://github.com/manaflow-ai/cmux), maintained at [LEOibyug/cmux](https://github.com/LEOibyug/cmux).

## Local-only macOS app

- Native Ghostty terminal, workspaces, splits, embedded browser and local automation socket.
- Vault history, including OMP, with live global `vault.enabledAgents` source selection; see [Vault](docs/vault.md).
- User-configured SSH, mosh, tmux and explicitly installed remote helpers.
- Local Computer Use and Simulator support.
- No cmux Cloud, account sign-in, teams, subscriptions, phone pairing, managed VPN, product telemetry, remote feature flags or automatic updater.

Browser sign-in to sites you choose and local socket authentication remain available. Local-only does not prohibit user-requested network operations such as browser navigation, Git or SSH. Server and iOS sources retained from upstream are not part of this macOS app.

This fork targets its current configuration and session formats. Do not add older-version adapters or migration-only regression suites unless the user explicitly asks for them.

## Development and installation

See [CONTRIBUTING.md](CONTRIBUTING.md#getting-started) for the local build prerequisites and tagged command. A compatible local `cmux-tui` executable is required; the build does not download or upgrade it automatically.

Use a tagged app and `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh` for smoke checks. Do not quit or replace a running stable app. Installing a new stable build requires the user to exit it first.

## Updates: explicit requests only

There is no update check, background download, scheduled upstream sync or automatic merge in this app. A change of version starts with an explicit user request:

1. Fetch upstream and inspect the requested fixes; do not merge all of `upstream/main` by default.
2. Apply only agreed commits to a personal branch, reviewing dependencies and conflicts.
3. Keep the local-only boundary, Vault source controls and local security policy. Do not reintroduce service SDKs or an updater.
4. Build only the affected products and run one targeted runtime scenario. Add focused regression coverage only where a consumer-visible edge requires it; do not run the full app/CI matrix by default.
5. Commit and push to the personal fork. Replace the installed app only after the user exits it.

## Local references

- [Appearance](docs/customizing-appearance.md)
- [Configuration schema](web/data/cmux.schema.json)
- [Vault and agent sources](docs/vault.md)
- [Shell integration](docs/shell-integration.md)
- [Local tmux](docs/local-tmux.md)
- [Ghostty keybindings](docs/ghostty-keybindings.md)

Other upstream documentation and translated READMEs are historical references, not a promise that their Cloud, account, installer or update instructions apply to this fork.

## License and attribution

Original cmux authorship and notices remain intact. See [LICENSE](LICENSE): the macOS app is GPL-3.0-or-later; the listed server directories retain their separate Business Source License 1.1 terms. Removing service integration does not change those licenses or third-party rights.
