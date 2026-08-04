# Architecture

`skills/` is the supported plugin payload. `agents/native/` is the canonical source for native custom-agent configurations. `setup/` bridges those sources into current global or project Codex locations; it is not a second source of agent behavior.

The canonical plugin and marketplace metadata are ordinary source files under `plugin/`. Global installation builds a generated plugin root at `$CODEX_HOME/basix-plugin-root/`, placing those files at `.codex-plugin/plugin.json` and `.agents/plugins/marketplace.json` as real copies. Its `skills/` payload follows the selected install mode: direct links to canonical `src/skills` in `link`, or independent files in `copy`. Codex registers that generated root, whose marketplace `./` source resolves to the generated plugin bundle. Hidden directories are therefore confined to Codex's generated target structure and never occur in `src`.

Persistent instructions come only from `setup/developer_instruction.md`. They retain the collection conventions, explicit delegation authority, cost-aware Root boundary, mandatory role routing, fallback configuration, and compact agent-management rules. The Python helper validates TOML, changes only the top-level `developer_instructions` string, and atomically replaces the target file. Its markers are ownership boundaries: uninstall removes the Basix instruction span and known Basix agent tables while preserving foreign TOML and instruction content byte-for-byte. Installer state records target type and expected link or content identity for agents and every generated plugin-bundle file. Copy-tree records include per-file relative paths and installation hashes, allowing uninstall to remove unchanged managed files selectively while preserving changed and unrecorded content.

The `basix` router owns the sole runtime copy of Contract 1.3 at
`skills/basix/references/agent-communication-contract.md`. Native agent TOMLs
contain only the byte-for-byte canonical bootstrap that loads the router,
persistent instructions, and that contract before planning or domain work. The
authoring skill owns the bootstrap template, JSON Schema, and read-only validator;
it rejects missing, duplicate, modified bootstraps and embedded contract copies.
Installers discover every canonical `agents/native/*.toml` automatically and copy
or link complete skill trees, so the router and contract are present before agent
configuration is activated. The verifier's immutable-target lifecycle is coordinated
by Root rather than by installer state.

Detailed Root lifecycle mechanics are specified in the `basix` skill rather than duplicated in
persistent instructions. The router covers fresh task identities, visible confirmations, exact Root
wait timing, failure boundaries, reuse, complete handoffs, generic-agent bootstrap
sentence, and inline-contract fallback. Native agent definitions retain their role
behavior and load the unchanged 120-second heartbeat and communication contract from
the router.
