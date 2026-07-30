# Installation

## Upgrade from Defaultwienix

Before installing Basix, uninstall the old Defaultwienix installation with its
previous installer. Then install Basix normally. There is no automatic migration
and no compatibility alias for old plugin, skill, agent, state, or bundle names.

Python 3.11 or newer and the Codex CLI are required. Link mode is the default and keeps agent bindings connected to this checkout. Copy mode creates independent files.

Both installers accept `--install-lumen yes|no` and default to `yes`. If no enabled `lumen` MCP registration exists, they invoke `install_ory_lumen.sh`, which follows Ory's Codex layout: clone `ory/lumen` into `$CODEX_HOME/lumen`, link its skills at `$HOME/.agents/skills/lumen`, and register the MCP server. This is a global Codex integration even when invoked by the project installer. Basix uninstall deliberately leaves it installed because other projects may use it. The standalone installer also supports `--dry-run` and conflict replacement for a file or symlink via `--force`.

`install_as_plugin.sh` registers this directory as marketplace `basix-local`, installs `basix`, discovers and binds every native agent TOML under `$CODEX_HOME/agents`, and merges the marked instruction block into `$CODEX_HOME/config.toml`. During upgrades it removes the retired `basix-luna-researcher.config.toml` only when the previous installer state identifies that file as managed and its link or content is unchanged; foreign and modified files are preserved.

`install_for_project.sh TARGET` creates `TARGET/.basix`, installs complete skill trees and every native agent into supported project paths, and merges the same block into `TARGET/.codex/config.toml`. Only trusted project configuration should be loaded.

Project installation additionally accepts `--lumen-index ask|yes|no` (default: `ask`). In an interactive terminal it offers `lumen index .` only after an enabled Lumen MCP has been detected. `yes` requests it non-interactively and `no` skips it. Ory's Codex setup does not install a `lumen` command in `PATH`, so the installer validates and invokes the registered canonical Ory launcher with `index .`, which is equivalent. If Lumen is absent, no question or index command is issued and an orange warning is printed. Indexing requires Lumen's embedding backend (normally Ollama) and its configured model to be available.

`--dry-run` reports without mutation. `--force` resolves file or install-target conflicts; it never permits overwriting foreign developer-instruction text. `--uninstall` asks Codex to remove the plugin and marketplace in global mode, removes the marked block, and deletes only targets that still match installer state. Changed targets are reported and preserved.
