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
`src/skills`; installed file links never use `.basix` as an intermediate target.
In a global plugin install, `--mode link` also links the bundle's skill payload
to these canonical Basix skill sources; `--mode copy` materializes that payload.
The generated plugin and marketplace metadata are always real copies in both
modes. Copy mode installs independent copies of every native agent and every
complete project skill tree directly in those target paths. Neither mode creates or manages
`.basix`; that directory is reserved for project-owned `memory.md`,
`credentials.md`, and future user data.

Both installers accept `--install-lumen yes|no` and default to `yes`. If no enabled `lumen` MCP registration exists, they invoke `install_ory_lumen.sh`, which follows Ory's Codex layout: clone `ory/lumen` into `$CODEX_HOME/lumen`, link its skills at `$HOME/.agents/skills/lumen`, and register the MCP server. This is a global Codex integration even when invoked by the project installer. Basix uninstall deliberately leaves it installed because other projects may use it. Both installers also support `--dry-run`; `--force` is passed to the optional Lumen setup, while known Basix manifest targets converge without it.

`install_as_plugin.sh` creates `$CODEX_HOME/basix-plugin-root`, installs
`plugin/plugin.json` and `plugin/marketplace.json` as real metadata copies, and
registers that generated root as marketplace `basix-local`. Its skill payload
follows the selected mode: direct canonical links in `link`, independent files
in `copy`. It also installs `basix`, discovers and binds every native agent TOML
under `$CODEX_HOME/agents`, and merges the marked instruction block into
`$CODEX_HOME/config.toml`. Every generated bundle file is recorded in installer
state: upgrades synchronize it, while uninstall removes only unchanged Basix-
managed files. During upgrades the same rule removes the retired
`basix-luna-researcher.config.toml`; foreign and modified files are preserved.

`install_for_project.sh [TARGET]` installs complete skill trees and every native agent directly into supported project paths and merges the same block into `TARGET/.codex/config.toml`. Project installations never generate or copy marketplace metadata. When `TARGET` is omitted, the current working directory is used. An explicit target may still be supplied to install into another project. Only trusted project configuration should be loaded.

Project installation additionally accepts `--lumen-index ask|yes|no` (default: `ask`). In an interactive terminal it offers `lumen index .` only after an enabled Lumen MCP has been detected. `yes` requests it non-interactively and `no` skips it. Ory's Codex setup does not install a `lumen` command in `PATH`, so the installer validates and invokes the registered canonical Ory launcher with `index .`, which is equivalent. An explicit `yes` is strict: a missing integration, unverifiable launcher, or failed index command produces a red failure and a nonzero exit status. Indexing requires Lumen's embedding backend (normally Ollama) and its configured model to be available.

Reinstallation is declarative: every exact file target in the current Basix
manifest converges to the selected mode regardless of prior installer state.
Links replace identical or changed copies and redirected links; copies replace
links and identical or changed files. This applies to known project targets,
global native-agent targets, and known plugin-bundle skill/metadata targets,
including state-less targets, without requiring `--force`. Files no longer
present in a payload are removed only below managed roots. Foreign siblings,
parents, directory targets, and paths outside the manifest remain protected;
foreign directory links are never followed. `same` entries identify physical
aliases of canonical sources, which are never removed or replaced. Uninstall
remains deliberately conservative and preserves locally changed managed
targets.

Legacy project `bundle-link` and `bundle-copy` state is migrated on install or
uninstall. Obsolete bundle aliases become direct source links or copies, while
reserved and unknown project-owned files already present below `.basix` are
preserved.

Mode changes are state-aware and do not require `--force`. In a self-hosting copy installation,
canonical agent or skill directory links are recorded before being replaced by
real directories; uninstall or a switch back to link restores their exact link
text only when the managed copies are still unchanged and no extra files remain.
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
Codex to remove the plugin and marketplace in global mode, removes the marked
block, and deletes only targets that still match installer state. Changed targets
are reported and preserved.

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
