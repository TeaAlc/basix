# Basix

Basix is a small Codex plugin and agent collection. The plugin installs the reusable meta-skill and native-agent authoring skill through Codex's supported plugin mechanism. Setup scripts additionally discover and bind native custom agents and a marked block of persistent developer instructions.

Upgrading from Defaultwienix requires a manual clean transition: uninstall the old
Defaultwienix installation with its previous installer first, then install Basix.
Basix does not provide migration logic or legacy aliases.

Global installation:

```bash
./setup/install_as_plugin.sh [--mode link|copy] [--install-lumen yes|no] [--dry-run] [--force]
```

Project installation:

```bash
./setup/install_for_project.sh TARGET [--mode link|copy] [--install-lumen yes|no] [--lumen-index ask|yes|no] [--dry-run] [--force]
```

Append `--uninstall` to either command to remove only managed, unchanged targets and the marked instruction block. Run `./tests/verify-basix.sh` and `./tests/test-setup.sh` before publishing changes.

See [installation](docs/installation.md), [architecture](docs/architecture.md), [agents](docs/agents.md), and [skills](docs/skills.md).

Ory Lumen installation is enabled by default when its Codex MCP is missing. Project setup can then offer or explicitly run `lumen index .`.
