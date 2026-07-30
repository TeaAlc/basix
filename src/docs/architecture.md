# Architecture

`skills/` is the supported plugin payload. `agents/native/` is the canonical source for native custom-agent configurations. `setup/` bridges those sources into current global or project Codex locations; it is not a second source of agent behavior.

The local marketplace metadata lives at `.agents/plugins/marketplace.json` in the plugin root. This differs from an earlier nested layout because Codex requires local plugin paths to remain inside the registered marketplace root. Its `./` source therefore resolves to this plugin directory without duplicating the bundle.

Persistent instructions come only from `setup/developer_instruction.md`. The Python helper validates TOML, changes only the top-level `developer_instructions` string, and atomically replaces the target file. Installer state records target type and expected link or content identity so uninstall preserves changed files.

Native agent TOMLs contain the complete canonical, versioned `basix-agent-authoring` contract block. The authoring skill owns that byte-for-byte template and its read-only validator; it does not launch or orchestrate agents. Installers discover every canonical `agents/native/*.toml` automatically, while project installation copies or links complete skill trees.
