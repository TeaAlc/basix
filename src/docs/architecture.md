# Architecture

`skills/` is the supported plugin payload. `agents/native/` is the canonical source for native custom-agent configurations. `setup/` bridges those sources into current global or project Codex locations; it is not a second source of agent behavior.

Repository-local `.codex/` and `.agents/` directories are runtime configuration,
not Basix product sources. Agents, tests, and verifiers exclude them from discovery
and evidence, and agents never modify them directly. Only a Basix installer may
write there during an explicitly requested installation; installer tests exercise
that behavior against isolated temporary targets.

The canonical plugin and marketplace metadata are ordinary source files under `plugin/`. Global installation builds a generated plugin root at `$CODEX_HOME/basix-plugin-root/`, copying metadata and complete skill trees into it without symlinks. Codex registers that generated root, whose marketplace `./` source resolves to the generated plugin bundle. Hidden directories are therefore confined to Codex's generated target structure and never occur in `src`.

Persistent instructions come only from `setup/developer_instruction.md`. They retain the collection conventions, explicit delegation authority, cost-aware Root boundary, mandatory role routing, native spawning rules, ADR governance, and the duty to follow the canonical communication contract. The persistent instructions and the Basix router jointly require every Basix-managed plan to maximize input-token efficiency: early insights should shrink later context and prevent redundant file, skill, or tool input, while correctness, safety, and mandatory dependencies remain authoritative. Before planning or implementation, agents read the project-owned active ADR index and load only relevant active records. Durable, difficult-to-reverse, cross-subsystem architecture, security, data, and workflow decisions use binding numbered ADRs; lifecycle changes and conflicts require explicit user confirmation. Agents create `.basix/adrs/` on first use. Installers never create that directory, an ADR template, or an initial ADR. The Python helper validates TOML, changes only managed developer-instruction, agent, and project local-access regions, and atomically replaces the target file. Its markers are ownership boundaries: uninstall removes those managed spans while preserving foreign TOML and instruction content byte-for-byte. Local-access settings are never written by the global/plugin installer. Installer state records target type and expected link or content identity for agents and every generated plugin-bundle file. Copy-tree records include per-file relative paths and installation hashes, allowing uninstall to remove unchanged managed files selectively while preserving changed and unrecorded content.

The `basix` router owns the sole agent-level table and spawn authority. The
`basix-subagent-management` skill owns orchestration and the sole runtime copy of Contract 2.0
at `skills/basix-subagent-management/references/agent-communication-contract.md`. Basix-maintainer
layout, placement, documentation, and verification guidance is isolated in
`skills/basix/references/developing-basix.md` and loads only for work on the Basix
source repository. Complete skill-tree installation packages both references.
Native agent TOMLs
begin with commented TOML metadata declaring `author` and agent `level`, then
contain the byte-for-byte canonical bootstrap that loads the router,
persistent instructions, the management skill, and that contract before planning or domain work. The
authoring skill owns the bootstrap template, JSON Schema, and read-only validator;
it rejects missing, duplicate, misplaced, or malformed metadata and bootstraps,
canonical level drift, unauthorized spawn permissions, and embedded contract copies.
Installers discover every canonical `agents/native/*.toml` automatically and copy
complete skill trees, so the router, management skill, and contract are present before agent
configuration is activated.

Persistent instructions, the router, and management skill regulate spawning and mandatory contract
loading without duplicating runtime messaging rules. Agent level controls spawn
authority while model and reasoning effort control task complexity. `/root` is
principal, pager and verifier are senior, and explorer and researcher are junior;
generic assignments default to junior unless Root supplies `agent_level`.
Contract 2.0 exclusively owns
the direct-parent hierarchy, parent-authored escalation, message envelope, cycles,
silent work, permissions, waiting, delivered acceptance, and terminal
results. Native definitions retain role behavior and the canonical bootstrap only.

All repository tests live under `test/` and are owned by an agent, skill, setup
script, or shared helper. `test/verify-basix.sh` aggregates standard deterministic
agent, skill, and shared suites; `test/test-setup.sh` aggregates deterministic
installer suites. Both continue after failures. The configure-tmux suite is excluded
from standard gates and runs only when an explicit plan changes that skill.
Authenticated discovery is opt-in through `test/live/run-live-tests.sh` and is never
part of either standard gate.

Saved plan workflow belongs to `skills/basix-planning/SKILL.md`, loaded on demand through the router and mandatory management link. It preserves bounded phases, direct-file-only suffix allocation, legacy files, and exact-basename archival.

ADR workflow belongs to `skills/basix-adr/SKILL.md`, loaded before planning or implementation without loading the saved-plan workflow recursively. Missing storage is created only for the first required ADR; installers seed no ADR artifacts.

Memory curation belongs to `skills/basix-agent-memory/SKILL.md`, loaded for updates and parent retention decisions. Startup/post-compaction reads remain in persistent instructions and alone do not load curation. Planning learns through this skill; management preserves direct-parent insight evaluation and contract proposal boundaries.

Contract 2.0 has only blocker/permission/terminal messages, implicit cycle starts
and idempotent identical terminal retransmission. Schema and stream validation
check protocol structure; parent lifecycle evidence establishes actual delivery,
authorization, three-slot allocation, resource independence and acceptance.
