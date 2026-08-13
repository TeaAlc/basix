# Architecture

`skills/` is the supported plugin payload. `agents/native/` is the canonical source for native custom-agent configurations. `setup/` bridges those sources into current global or project Codex locations; it is not a second source of agent behavior.

Repository-local `.codex/` and `.agents/` directories are runtime configuration,
not Basix product sources. Agents, tests, and verifiers exclude them from discovery
and evidence, and agents never modify them directly. Only a Basix installer may
write there during an explicitly requested installation; installer tests exercise
that behavior against isolated temporary targets.

The canonical plugin and marketplace metadata are ordinary source files under `plugin/`. Global installation builds a generated plugin root at `$CODEX_HOME/basix-plugin-root/`, copying metadata and complete skill trees into it without symlinks. Codex registers that generated root, whose marketplace `./` source resolves to the generated plugin bundle. Hidden directories are therefore confined to Codex's generated target structure and never occur in `src`.

Persistent instructions come only from `setup/developer_instruction.md`. They retain the collection conventions, explicit delegation authority, cost-aware Root boundary, mandatory role routing, native spawning rules, and the duty to follow the canonical communication contract. The Python helper validates TOML, changes only the top-level `developer_instructions` string, and atomically replaces the target file. Its markers are ownership boundaries: uninstall removes the Basix instruction span and known Basix agent tables while preserving foreign TOML and instruction content byte-for-byte. Installer state records target type and expected link or content identity for agents and every generated plugin-bundle file. Copy-tree records include per-file relative paths and installation hashes, allowing uninstall to remove unchanged managed files selectively while preserving changed and unrecorded content.

The `basix` router owns runtime routing and the sole runtime copy of Contract 1.4
at `skills/basix/references/agent-communication-contract.md`. Basix-maintainer
layout, placement, documentation, and verification guidance is isolated in
`skills/basix/references/developing-basix.md` and loads only for work on the Basix
source repository. Complete skill-tree installation packages both references.
Native agent TOMLs
begin with commented TOML metadata declaring `author` and agent `level`, then
contain the byte-for-byte canonical bootstrap that loads the router,
persistent instructions, and that contract before planning or domain work. The
authoring skill owns the bootstrap template, JSON Schema, and read-only validator;
it rejects missing, duplicate, misplaced, or malformed metadata and bootstraps,
canonical level drift, unauthorized spawn permissions, and embedded contract copies.
Installers discover every canonical `agents/native/*.toml` automatically and copy
complete skill trees, so the router and contract are present before agent
configuration is activated.

Persistent instructions and the router regulate spawning and mandatory contract
loading without duplicating runtime messaging rules. Agent level controls spawn
authority while model and reasoning effort control task complexity. `/root` is
principal, pager and verifier are senior, and explorer and researcher are junior;
generic assignments default to junior unless Root supplies `agent_level`.
Contract 1.4 exclusively owns
the direct-parent hierarchy, parent-authored escalation, message envelope, cycles,
status cadence, permissions, reports, waiting, visible confirmations, and terminal
results. Native definitions retain role behavior and the canonical bootstrap only.

All repository tests live under `test/` and are owned by an agent, skill, setup
script, or shared helper. `test/verify-basix.sh` aggregates standard deterministic
agent, skill, and shared suites; `test/test-setup.sh` aggregates deterministic
installer suites. Both continue after failures. The configure-tmux suite is excluded
from standard gates and runs only when an explicit plan changes that skill.
Authenticated discovery is opt-in through `test/live/run-live-tests.sh` and is never
part of either standard gate.
