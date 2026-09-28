# Basix

Basix equips Codex projects with reusable skills, specialized agents, shared
working rules, and installation tooling. Install it for one project or globally
for your user. This repository contains both the installable bundle and its
canonical development sources.

[Installation](#installation) · [Agents and skills](#agents-and-skills) ·
[Optional integrations](#optional-integrations) · [Development](#development)

## Installation

### Requirements

- Linux or another environment capable of running the Bash installers
- Python 3.11 or newer and a current Codex CLI
- Git for the optional Ory Lumen installer
- Podman or Docker for the optional Scrapling MCP service

Run the following commands from a Basix checkout. Choose the installation scope
that fits your workflow, then restart Codex to load the installed configuration.

### Install into one project

```bash
# Preview a project install with local access disabled
./src/setup/install_for_project.sh /path/to/project --dry-run \
  --no-local-network --no-test-socket

# Install with the same settings
./src/setup/install_for_project.sh /path/to/project \
  --no-local-network --no-test-socket
```

The target defaults to the current directory when omitted. Skills are copied to
`TARGET/.agents/skills/`, agents to `TARGET/.codex/basix/agents/`, and managed
instructions and agent registrations to `TARGET/.codex/config.toml`.

Local access is opt-in and can be enabled independently:

| Option | Access granted |
| --- | --- |
| `--local-network` | Loopback networking and local binding on all local ports, for example for Playwright |
| `--test-socket` | Only the Unix socket at `TARGET/test/test.sock` |
| `--no-local-network`, `--no-test-socket` | Disable the corresponding Basix-managed permission |

Interactive installs ask about both capabilities. Noninteractive installs must
provide one enable/disable flag for each. For a project that needs both:

```bash
./src/setup/install_for_project.sh /path/to/project \
  --local-network --test-socket
```

Permission changes take effect in a new Codex session. Load project configuration
only from projects you trust. See the [installation reference](src/docs/installation.md)
for permission boundaries, managed configuration, and migration behavior.

### Install globally

```bash
./src/setup/install_as_plugin.sh --dry-run
./src/setup/install_as_plugin.sh
```

The installer creates a plugin bundle at `$CODEX_HOME/basix-plugin-root/`,
registers the local marketplace `basix-local`, installs the plugin, and stores
agents under `$CODEX_HOME/basix/agents/`. Managed instructions and absolute agent
`config_file` registrations go into `$CODEX_HOME/config.toml`. Global installation
does not configure project local-access permissions.

### Update or uninstall

Rerun the corresponding installer to synchronize an existing managed installation
with the checkout. Both installers copy complete skill and agent trees without
symlinks. They inventory managed files, reject unsafe or conflicting targets, and
preserve configuration outside Basix-owned blocks.

```bash
./src/setup/install_for_project.sh /path/to/project --uninstall
./src/setup/install_as_plugin.sh --uninstall
```

Uninstall removes only unchanged, inventory-confirmed Basix files and preserves
local modifications and foreign content. Add `--dry-run` to preview removal.
Installer state uses paths relative to the install root so installations can move.

Legacy Defaultwienix, link-mode, or incompatible older bundle installations must
be removed with the installer version that created them before installing Basix.
See [updates and safety](src/docs/installation.md#updates-and-safety) for supported
state and permission migrations.

## Agents and skills

Basix keeps compact tasks with the root agent and delegates broad discovery,
research, specialized work, and larger assignments to dedicated agents.

| Agent | Purpose | Access |
| --- | --- | --- |
| `basix_file_explorer` | Extensive local evidence discovery | Read-only |
| `basix_researcher` | External research, website inspection, and scraping through Scrapling | Read-only |
| `basix_pager` | Bounded web frontend, backend, UI/UX, fullstack, or integration implementation | Workspace write |
| `basix_verifier` | Independent inspection of a frozen result | Read-only |
| `basix_miraculix` | Bounded second opinion, especially under extreme uncertainty | Read-only |

Native agents use `gpt-6-luna`, except Miraculix, which uses `gpt-6-astra`.
Agent level governs delegation separately from model and reasoning effort: Root
is principal; Pager and Verifier are seniors; Explorer, Researcher, and Miraculix
are juniors. See the [agent reference](src/docs/agents.md) for profiles, assignment
requirements, model settings, and spawn authority.

The installed skills provide these entry points:

| Skill | Use it for |
| --- | --- |
| `basix` | Basix routing, standards, and source maintenance |
| `basix-agent-authoring` | Creating and validating native agent definitions |
| `basix-experience` | Session feedback and token-efficiency retrospectives |
| `basix-subagent-efficiency` | Task-level analysis of delegation attempts, retries, and recovery |
| `basix-personality-model` | Evidence-based personality models and agent role specifications |
| `configure-tmux` | tmux mouse, scrollback, clipboard, and extended-key troubleshooting |

Mention the relevant skill or agent naturally in Codex. The
[skill reference](src/docs/skills.md) explains each workflow.

### Working rules installed with Basix

Installing Basix also adds [shared developer instructions](src/setup/developer_instruction.md)
that shape agent behavior:

- Root commits its completed task changes with Conventional Commits in Git
  repositories after all started tests and verification finish successfully.
- Plans, persistent memory, and optional character instructions live under
  project-owned `.basix/`. Agents curate `.basix/memory.toml` autonomously and
  apply useful findings across sessions.
- Basix provides binding ADR governance for durable, hard-to-reverse,
  cross-subsystem decisions. Agents read applicable active decisions and pause
  for explicit user confirmation before conflicting work or lifecycle changes.
- The installers do not create `.basix/adrs/`, ADR templates, or an initial ADR;
  agents create the ADR structure only when the first qualifying decision is recorded.
- External research routes through `basix_researcher`; missing Scrapling
  capability is reported as a blocker.
- Children communicate only with their direct parent. Verification freezes its
  target until review completes; changes require a fresh review.

The [Basix router](src/skills/basix/SKILL.md) and
[communication contract](src/skills/basix/references/agent-communication-contract.md)
are the authoritative runtime references.

## Optional integrations

### Ory Lumen semantic search

Basix installation does not install Lumen or start indexing. Install it explicitly:

```bash
./src/setup/install_ory_lumen.sh --dry-run
./src/setup/install_ory_lumen.sh
```

Run project indexing separately afterward. The configured embedding backend and
model, normally provided by Ollama, must be available. See
[optional Lumen installation](src/docs/installation.md#optional-lumen-installation).

### Tor-only Scrapling MCP

```bash
./src/setup/install-scrapling-codex.sh --dry-run
./src/setup/install-scrapling-codex.sh
```

The installer runs persistent Tor and Scrapling containers and registers the
canonical MCP name `scrapling`. Streamable HTTP is published only at
`http://127.0.0.1:8002/mcp`; use `--port PORT` for another unprivileged port or
`--runtime podman|docker` to select a runtime. Run the installer with `--help`
for all options.

Scrapling is attached only to the internal network and sends application HTTP
traffic through Tor. Installation checks the tool policy, direct-TCP isolation,
MCP handshake, and a real request reporting `IsTor: true` before registration.
External DNS answers are allowed, so DNS metadata can reach host resolvers.
This container boundary does not reproduce Tor Browser's fingerprinting
protections. The loopback service has no TLS or global authentication; remote
access is outside its trust model.

An existing single Scrapling registration requires interactive replacement
approval or `--force`. Multiple registrations, foreign running services, and
unsafe runtime resources cause an abort even with `--force`. Restart Codex after
installation or migration.

Every tool call requires a canonical RFC 4122 UUID v4 `client_id`, generated by
the calling agent from a cryptographically secure system source. Reuse it for
related session calls; share it with a subagent only deliberately. It controls
session ownership, not server authentication, and must never be replaced with
`default`, a `session_id`, or a server-generated placeholder.

Runtime details are defined in the [installer](src/setup/install-scrapling-codex.sh)
and [controller](src/setup/scrapling-tor/launcher.sh). The controller supports
`prepare`, `start`, `stop`, `status`, and `tor-ip`.

## Development

### Repository layout

| Path | Purpose |
| --- | --- |
| `src/skills/` | Canonical skills with their scripts, references, assets, and metadata |
| `src/agents/native/` | Native Codex agent definitions |
| `src/setup/` | Installers and shared developer instructions |
| `src/scripts/` | Shared launchers and quality-gate tooling |
| `src/docs/` | Architecture and component references |
| `test/agents/`, `test/skills/`, `test/setup/`, `test/shared/` | Component-owned deterministic tests |
| `test/live/` | Explicit authenticated Codex/model tests |

Make changes in canonical `src/` sources. Repository-local `.agents/` and
`.codex/` are installed runtime copies, excluded from development evidence and
direct edits. Keep workflow-specific supporting files inside their skill
directory, and update documentation when an installable interface changes.

Start with the [development guidance](src/skills/basix/references/developing-basix.md)
and [architecture](src/docs/architecture.md).

### Verification

Choose gates by changed scope and impact. Preview the selection before running it:

```bash
./src/scripts/run-quality-gates.sh --base HEAD --dry-run
./src/scripts/run-quality-gates.sh --base HEAD
```

The selector reports its chosen checks and stores complete output in a log
directory. Normative and communication-contract changes additionally require
frozen independent review evidence. See the
[quality-gate runner](src/scripts/run-quality-gates.sh) for explicit scope,
impact, and review-evidence options.

Run focused component tests when their coverage matches the change. Use
`./test/verify-basix.sh` only for changes affecting the full agent, skill, or shared
aggregation scope, and `./test/test-setup.sh` only for changes affecting the full
setup scope. Report each selected command and the change it covers. For affected
shell files, run ShellCheck when installed; also run `git diff --check`.

Two special boundaries apply:

- **configure-tmux:** excluded from standard aggregators; run
  `./src/scripts/run-quality-gates.sh --impact configure-tmux` only when an
  explicit plan changes that skill.
- **Scrapling runtime:** changes to its installer, launcher, or runtime policy
  require `./test/test-setup.sh`, followed by
  `./test/setup/install-scrapling-codex/release-gate-podman.sh`. The release gate
  uses isolated temporary Podman storage and real Tor/HTTP-MCP checks.

Live model tests are explicit and require Codex authentication, network access,
and available usage quota:

```bash
bash test/live/run-live-tests.sh
```

Every started test must finish successfully before task completion or commit.
