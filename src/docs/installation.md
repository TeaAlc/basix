# Installation

## Upgrade from Defaultwienix

Before installing Basix, uninstall the old Defaultwienix installation with its
previous installer. Then install Basix normally. There is no automatic migration
and no compatibility alias for old plugin, skill, agent, state, or bundle names.

Python 3.11 or newer and the Codex CLI are required. Without `--mode`, an
interactive installer asks whether to use `link` or `copy`. Global installs and
ordinary project targets dynamically default to `link`; when the project target
is the canonical parent of this checkout's runtime `src` directory (a
self-hosting checkout), the default is `copy`. The same computed default is
used for interactive prompts and non-TTY invocations. `--mode link|copy` is the
explicit noninteractive override, and uninstall never asks for a mode.

Link mode keeps agents and skills connected directly to `src/agents/native` and
`src/skills` through complete directory links. `SKILL.md` and agent TOMLs are
ordinary entries reached through those directory links, not individual symlink
nodes. In a global plugin install, `--mode link` links each complete bundle skill
directory to its canonical source; `--mode copy` materializes the complete tree.
The generated plugin and marketplace metadata are always real copies in both
modes. Copy mode installs independent copies of every native agent and every
complete project skill tree directly in those target paths. Neither mode creates or manages
`.basix`; that directory is reserved for project-owned `memory.md`,
`credentials.md`, and future user data.

Both installers accept `--install-lumen yes|no` and default to `yes`. If no enabled `lumen` MCP registration exists, they invoke `install_ory_lumen.sh`, which follows Ory's Codex layout: clone `ory/lumen` into `$CODEX_HOME/lumen`, link its skills at `$HOME/.agents/skills/lumen`, and register the MCP server. This is a global Codex integration even when invoked by the project installer. Basix uninstall deliberately leaves it installed because other projects may use it. Both installers also support `--dry-run`; `--force` is passed to the optional Lumen setup, while known Basix manifest targets converge without it.

`install_as_plugin.sh` creates `$CODEX_HOME/basix-plugin-root`, installs
`plugin/plugin.json` and `plugin/marketplace.json` as real metadata copies, and
registers that generated root as marketplace `basix-local`. Its skill payload
follows the selected mode: canonical directory links in `link`, independent
complete trees in `copy`. Native agents are kept privately under
`$CODEX_HOME/basix/agents` and registered through a managed
`basix:agent-config:start/end` block containing one absolute
`[agents.<name>].config_file` entry per agent. No Basix TOML is written under the
shared `$CODEX_HOME/agents` directory. The developer-instruction block is merged
separately into `$CODEX_HOME/config.toml`. Every generated bundle file is recorded in installer
state: upgrades synchronize it, while uninstall removes only unchanged Basix-
managed files. During upgrades the same rule removes the retired
`basix-luna-researcher.config.toml`; foreign and modified files are preserved.

`install_for_project.sh [TARGET]` installs complete skill directory links or
copies under `TARGET/.agents/skills`, keeps every native agent privately under
`TARGET/.codex/basix/agents`, and registers absolute paths in the same managed
agent-config block in `TARGET/.codex/config.toml`. It never writes Basix agents
under the shared `TARGET/.codex/agents` directory. Project installations never
generate or copy marketplace metadata. When `TARGET` is omitted, the current
working directory is used. An explicit target may still be supplied to install
into another project. Only trusted project configuration should be loaded.

Project installation additionally accepts `--lumen-index ask|yes|no` (default: `ask`). In an interactive terminal it offers `lumen index .` only after an enabled Lumen MCP has been detected. `yes` requests it non-interactively and `no` skips it. Ory's Codex setup does not install a `lumen` command in `PATH`, so the installer validates and invokes the registered canonical Ory launcher with `index .`, which is equivalent. An explicit `yes` is strict: a missing integration, unverifiable launcher, or failed index command produces a red failure and a nonzero exit status. Indexing requires Lumen's embedding backend (normally Ollama) and its configured model to be available.

Reinstallation is declarative: every managed directory target in the current
Basix manifest converges to the selected mode regardless of prior installer
state. Backward-compatible three-column `dirlink` records store the target and
expected canonical source; `dircopy` records store a complete-tree hash. New
copy states additionally contain one `dirfile` inventory record per installed
file, with the directory target, relative path, and installation hash. Links
replace managed copies and redirected or cyclic managed links; copies replace
managed links and known payload trees. State-less exact canonical links are
adopted. Files or skill directories no longer present in a payload are removed
only below managed roots. Foreign siblings, extra directory contents, parents,
unmarked directory links, and paths outside the manifest remain protected;
foreign directory links are never followed. `same` entries identify physical
aliases of canonical sources, which are never removed or replaced. Uninstall
remains deliberately conservative. It removes unchanged inventoried files from
mixed copy trees, preserves unrecorded and locally changed files, never follows
directory symlinks or special files, and removes only empty managed directories.
Legacy `dircopy` states still remove an exact regular tree; if that tree differs,
only files that also match the current Basix source are removed.

Legacy project `bundle-link` and `bundle-copy` state is migrated on install or
uninstall. Obsolete bundle aliases become direct source links or copies, while
reserved and unknown project-owned files already present below `.basix` are
preserved.

Mode changes are state-aware and do not require `--force`. `link` to `copy`
replaces only managed directory links with complete copies. `copy` to `link`
first rejects foreign extra content, then replaces the complete managed tree.
Foreign directory links, unrecorded foreign directories or parents, targets
outside the current manifest, unreadable sources, and source symlink loops abort
or are preserved rather than overwritten. Exact current-manifest file targets
still converge without prior state. Managed redirected or cyclic links are
detached without resolution and recreated. A target that is
physically identical to its canonical source is never replaced, even with
`--force`.

`--dry-run` reports without mutation. `--force` is only forwarded to optional
Lumen setup; it does not permit overwriting foreign Basix parents, directories,
or canonical sources. `--uninstall` asks
Codex to remove the plugin and marketplace in global mode, removes managed
configuration, and deletes only targets whose ownership and unchanged content
can be proved. Marker pairs are the configuration ownership boundary: the Basix
developer-instruction span and known Basix agent tables inside the agent marker
are removed, while keys, comments, instructions, and foreign agent tables outside
that ownership remain byte-for-byte unchanged. A foreign agent table accidentally
placed inside the agent markers is preserved as well. `config.toml`, installer
state, and parent directories are removed only when the corresponding cleanup
leaves no foreign content. Redirected directory links and manipulated or
out-of-scope state targets are preserved. Dry-run uses the same link, inventory,
and hash checks without modifying payload or state.

Both installers print an English checklist grouped by installable area. Its header
identifies target, mode, and dry-run state. Every skill and native agent has its own
item; skills include internal file counts. A green `✓` means changed (or a validated
planned change in dry-run), a yellow `-` means current, skipped, or safely preserved,
and a red `✗` means failed. The final Result group counts changed, unchanged, and
failed items. ANSI color is used only on a terminal and is disabled for redirected
output, CI, and `NO_COLOR`; the symbols remain. Dry-runs are mutation-free and use
`Would …` details for planned changes. The instruction helper reports add, update,
already-current, remove, and not-present outcomes without printing instruction
contents or configuration values; installers consume its optional JSON status.
