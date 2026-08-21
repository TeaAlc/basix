# Basix

Basix is a collection of reusable Codex skills, native read-only agents, shared
developer instructions, and installation tooling. This repository serves two
purposes: it is the source tree in which Basix is developed, and it is the bundle
from which Basix can be installed globally or into any Codex project.

> Upgrading from Defaultwienix requires a clean transition. Uninstall the old
> Defaultwienix installation with its original installer before installing Basix.
> Basix intentionally provides no legacy aliases or automatic migration.

## 1. Developing and extending Basix in this repository

### Repository layout

All installable Basix sources live below `src/`:

| Path | Purpose |
| --- | --- |
| `src/skills/` | Canonical reusable skills and their scripts, references, assets, and UI metadata |
| `src/agents/native/` | Canonical native Codex agent TOMLs |
| `src/setup/` | Global, project, Lumen, and Tor-only Scrapling installers |
| `src/scripts/` | Launchers shared across skills or agents |
| `src/docs/` | Architecture and component documentation |
| `test/agents/` | One directly executable deterministic suite per native agent |
| `test/skills/` | Directly executable deterministic skill suites; configure-tmux is explicit-only |
| `test/setup/` | Installer and setup-support suites |
| `test/shared/` | Tests for shared scripts without a component owner |
| `test/live/` | Explicit authenticated Codex/model tests, excluded from standard gates |

The source of truth for agent behavior is `src/agents/native/`; setup scripts only
bind those definitions into supported Codex locations. Persistent shared
instructions come from `src/setup/developer_instruction.md`. Installer state is
used to ensure that uninstall operations preserve foreign or locally modified
  files. Copy state inventories every installed file, so uninstall can remove
unchanged Basix files from a mixed tree without deleting changed files, foreign
siblings, symlinks, special files, or nonempty parent directories. Configuration
markers define the Basix-owned spans; content outside them remains byte-for-byte
unchanged.

### Making changes

- Add a focused workflow under `src/skills/<name>/SKILL.md`; keep its supporting
  scripts and references inside that skill directory.
- Change native agents only in `src/agents/native/`. The `basix` router owns the
  runtime communication contract; `basix-agent-authoring` owns the native
  bootstrap, JSON Schema, and validator tooling.
- Put only genuinely shared launchers in `src/scripts/`.
- Keep installers idempotent, preserve user-modified files, and support
  non-mutating `--dry-run` behavior where exposed.
- Update the relevant documentation whenever an installable interface changes.

More detail is available in the [architecture](src/docs/architecture.md),
[agent](src/docs/agents.md), and [skill](src/docs/skills.md) documentation.

### Verification

Select tests from the changed components and their dependents, then run the
selected paths explicitly from the repository root:

```bash
bash test/agents/<agent>/test-<agent>.sh       # agent changes
bash test/skills/<skill>/test-<skill>.sh       # skill changes
bash test/setup/<component>/test-<component>.sh # installer changes
bash test/shared/<suite>.sh                    # shared-code changes
```

Report every selected command together with the change it covers. Use
`./test/verify-basix.sh` only when a change can affect the full agent, skill, or
shared-test aggregation scope, and use `./test/test-setup.sh` only when a change
can affect the full setup aggregation scope. Every started test must finish
successfully.

The configure-tmux suite is excluded from standard gates. Run it only when an
explicit plan changes the configure-tmux skill:

```bash
bash test/skills/configure-tmux/test-configure-tmux-suite.sh
```

Run live tests only when the affected functionality requires a real model turn.
They require Codex authentication, network access, and available usage quota:

```bash
bash test/live/run-live-tests.sh
```

For affected shell files, also run ShellCheck when it is installed. Always check
the resulting diff:

```bash
shellcheck path/to/affected-script.sh
git diff --check
```

Both standard aggregators run every suite after failures and report failed suite
paths and timings; they remain available for genuinely broad changes. Live/model
tests are only run through `test/live/run-live-tests.sh`.

## 2. Installing and using Basix in Codex projects

### Requirements

- Linux or another environment capable of running the Bash installers
- Python 3.11 or newer
- A current Codex CLI
- Git when installing the optional Ory Lumen integration separately
- Podman or Docker only when installing the optional Tor-only Scrapling MCP

Run all commands below from a Basix repository checkout. Both installers always
copy complete skill trees and the complete private native-agent directory. They
never create symlinks. Native agents are registered with managed `[agents.<name>]`
`config_file` entries instead of being written into shared agent directories.
In global plugin mode, generated metadata is copied as well. On reinstall,
recorded copies synchronize with `src`; obsolete unchanged managed files are
removed. Foreign directories, directory symlinks, and physical source aliases
are rejected before mutation. Uninstall is intentionally conservative: it removes only state-
and hash-confirmed Basix content, including unchanged files inside otherwise
mixed copy trees, and keeps locally modified or foreign targets.

### Option A: Install Basix globally

Use global installation when Basix should be available to all Codex projects for
the current user:

```bash
./src/setup/install_as_plugin.sh
```

This creates an independent plugin bundle at `$CODEX_HOME/basix-plugin-root/`,
registers it as the local Codex marketplace `basix-local`, installs the Basix
plugin, stores native agents under `$CODEX_HOME/basix/agents/`, registers their
absolute `config_file` paths, and merges the marked Basix instruction block into
`$CODEX_HOME/config.toml`. It never writes Basix agents into the shared
`$CODEX_HOME/agents/` directory.

Common variants:

```bash
# Preview without changing files or Codex configuration
./src/setup/install_as_plugin.sh --dry-run

# Remove installer-managed Basix state, preserving local changes
./src/setup/install_as_plugin.sh --uninstall
```

### Option B: Install Basix into one Codex project

Use project installation when Basix should be committed to or isolated within a
specific project:

```bash
cd /path/to/project
/path/to/basix/src/setup/install_for_project.sh
```

The installer copies complete skill directories under
`.agents/skills/`, stores native agents privately under `.codex/basix/agents/`,
and registers them with managed `[agents.<name>].config_file` entries in
`.codex/config.toml`. It never writes Basix TOMLs into the shared
`.codex/agents/` directory and never creates or manages project `.basix`; that
directory is reserved for project-owned memory and credential files. Only load
project-level Codex configuration from projects you trust.

Useful variants:

```bash
# Preview changes to the current project
/path/to/basix/src/setup/install_for_project.sh --dry-run

# Remove installer-managed project files, preserving local changes
/path/to/basix/src/setup/install_for_project.sh --uninstall

# Alternatively, target a project explicitly from any directory
./src/setup/install_for_project.sh /path/to/project
```

Foreign parents, directories, symlinks, and canonical sources remain protected.
See the full [installation reference](src/docs/installation.md).

### Optional: Ory Lumen semantic search

The Basix installers never install or invoke Lumen. Install it explicitly when
semantic search is wanted:

```bash
./src/setup/install_ory_lumen.sh
```

Run indexing separately afterward. The configured embedding backend and
model—normally provided by Ollama—must be available.

### Optional: Tor-only Scrapling MCP

Install the managed Scrapling MCP when Basix agents should have web-fetching tools
whose container egress is restricted to Tor:

```bash
./src/setup/install-scrapling-codex.sh --dry-run
./src/setup/install-scrapling-codex.sh
```

This starts two persistent, separately networked containers: Tor has the egress
network, while `basix-scrapling-mcp` is attached only to the internal network and
publishes Streamable HTTP exclusively on `http://127.0.0.1:8002/mcp`. Choose a
different unprivileged loopback port with `--port PORT`.

The installer permits exactly one detected Scrapling registration and always uses
the canonical MCP name `scrapling`. If one older or third-party registration is
found, approve its replacement interactively or use `--force` for the same
noninteractive confirmation:

```bash
./src/setup/install-scrapling-codex.sh --force
```

Two or more registrations, foreign running Scrapling MCP processes, or unsafe
runtime resources always cause an abort; `--force` cannot bypass those checks.
The installer pulls the configured Scrapling image, pins the verified digest,
validates the exact MCP tool policy, and registers the HTTP URL only after an MCP
initialize handshake, schema inspection, and a real `get` tool call report
`IsTor: true`. Restart running Codex sessions after a successful migration. The
installed controller supports `prepare`, `start`, `stop`, `status`, and `tor-ip`.
An older Basix-managed stdio container is migrated only when its complete runtime
and security signature is intact. It remains running until the replacement HTTP
service passes those checks, is revalidated by immutable container ID, and is then
removed. Partially matching or foreign containers are never adopted or removed,
including with `--force`.
Before starting Tor, the controller runs a temporary named probe in the existing
egress network. If the host cannot create the rootless network namespace, it
aborts before creating either service and reports the runtime, rootless status,
and `Store.RunRoot`; it never repairs the host runtime or falls back to another
network backend.

Every change to this installer, its launcher, or the runtime policy must pass the
real isolated Podman release gate after deterministic setup tests:

```bash
./test/test-setup.sh
./test/setup/install-scrapling-codex/release-gate-podman.sh
```

The release gate uses temporary Podman graph and run roots, constructs the legacy
stdio/Tor topology, performs the live Tor and HTTP-MCP migration, checks the exact
runtime boundary, reruns the installer for idempotency, and removes all temporary
resources.

Every tool call requires a canonical UUID v4 `client_id`. Generate it from a
cryptographically secure system source, reuse it for related session calls, and
share it with a subagent only deliberately. It is a session capability, not
general server authentication: sessions opened with one UUID are invisible and
unusable with another, and all mappings disappear when the service restarts. The
installer never creates or stores this UUID.

Hermes and other local clients can share the service:

```yaml
mcp_servers:
  scrapling:
    url: "http://127.0.0.1:8002/mcp"
    enabled: true
```

This provides a Tor-only guarantee at the container network boundary. It does
**not** turn Chromium into Tor Browser or reproduce Tor Browser's fingerprinting
protections. Administrators controlling the container daemon, host networking, or
root access remain outside this security boundary.
There is intentionally no TLS or global authentication because the published
socket is loopback-only. Remote access is outside this version's trust model.

### Using Basix after installation

Restart Codex after installation so newly installed skills, agents, MCP servers,
and persistent instructions are loaded. Basix then supplies:

- mandatory routing of all external research, website inspection, and scraping to
  `basix_researcher`, which uses Scrapling for web tasks and reports a blocker if
  that capability is unavailable;
- cost-aware routing that keeps tightly bounded, compact work with Root and sends
  broad evidence ingestion, multi-step work, specialized work, or assignments
  expected to need more than two substantive domain-tool calls to a Basix agent;
- automatic Conventional Commits for Root's task changes in Git repositories, but
  only after every running verification and test completes successfully;
- agent-owned persistent memory in `.basix/memory.toml`, read once at session start
  and after each context compaction, actively applied to reduce work and prevent
  repeated mistakes, and autonomously curated without user approval at natural
  work checkpoints; concise dated insights use fixed English categories and are
  committed with task changes unless `.basix` is ignored, while useful, strongly
  evidenced subagent proposals retain their originating role;
- mandatory routing of extensive local evidence discovery to
  `basix_file_explorer`, preferably before discovery begins, while implementation
  and final code analysis remain with Root;
- the `basix-agent-authoring` skill for creating and validating native agents;
- the writable `basix_pager` for one Root-authorized nontrivial web assignment, selected
  with exactly one profile (`ui_ux`, `frontend`, `backend_web`, `fullstack`, or
  `integration`), while explorer and researcher agents remain read-only;
- the read-only `basix_verifier` for one fresh-context, immutable-result review;
  the parent first makes overlapping writers inactive, holds the write freeze
  through completion, and starts a fresh verifier after remediation or scope changes;
- Lumen semantic project search when the optional integration is installed and
  the project has been indexed.

Agent hierarchy is separate from model complexity. `/root` is principal;
`basix_pager` and `basix_verifier` are senior; `basix_file_explorer` and
`basix_researcher` are junior. Juniors cannot spawn children, seniors may spawn
only those two native juniors, and non-root principals cannot spawn principals.
Generic agents default to `agent_level: junior`; Root may explicitly assign any
level and must give a generic principal a principal-free spawn framework.

### Agent communication contract

```mermaid
sequenceDiagram
    participant Root as /root
    participant Parent as Native parent
    participant Child as Native child

    Root->>Parent: fresh spawn, fork_turns="none"
    Parent->>Parent: read router, persistent instructions, contract
    Parent->>Child: permitted fresh spawn, fork_turns="none"
    Child->>Child: read router and referenced contract
    Note over Root,Child: Contract 1.4 · each child communicates only with its direct parent
    Child->>Parent: plan, status, result, issue, or permission request
    alt Parent resolves or instructs
        Parent-->>Child: followup_task
    else Parent must escalate
        Parent->>Root: new parent-authored issue or permission request
    end
```

The router-owned Contract 1.4 is the sole source for message envelopes, cycles,
status cadence, issues, permissions, reports, continuations, waiting, and visible
confirmations. Every child sends only to its direct spawning parent. That parent
resolves the report, instructs the child, or authors a new escalation in its own
task cycle to its own parent; child messages are never forwarded automatically.
Developer instructions and the router define only role selection, fresh spawning,
assignment boundaries, and mandatory contract loading. Native TOMLs contain only
the validated bootstrap plus role-specific behavior.

### Coordinating pager work

Root starts every pager with `fork_turns="none"`, a unique never-reused task
name, one profile, concrete file/module ownership, acceptance gates, and exact
verification commands. The full assignment also states user impact,
authoritative requirements, allowed ownership extensions, non-goals, known
worktree changes, required skills, allowed delegations, and any contract
revision. A pager reports scope or ownership changes before editing shared
files and follows the communication contract for review, fixes, and terminal results.

For dependent frontend/backend chains, Root owns the target project's
`.basix/contracts/<chain-id>.md`; pagers update only their assigned sections,
ledger entries, and proposals. Use sequential fresh pagers by default. Safe
parallel work requires a frozen interface, disjoint ownership, separate
contract sections, no shared generated outputs, and a planned Root integration
step. Review handoffs, fixes, terminal results, and continuations follow Contract 1.4.

### Coordinating verification

Start `basix_verifier` with `fork_turns="none"`, a unique task name, a complete
assignment, and a mutation-free verification window. Before spawning it, make all
agents with overlapping or unclear write ownership inactive; clearly disjoint
writers may continue. Include the original requirements, worker report,
`owned_targets`, known pre-existing changes, allowed checks, constraints, and a
`mutation_window` confirmation that relevant writers are inactive and the freeze
lasts through completion. Do not mutate the scope or reactivate an overlapping
writer during the run. If another relevant write is necessary, stop the verifier,
discard its result, complete the change, and start a fresh verifier. Contract 1.4
governs its messages and continuation cycle; remediation validation, changed
acceptance criteria, or a new result always gets a fresh verifier.

Invoke the relevant skill or agent naturally in Codex, or mention Basix when the
task concerns maintaining its installable standards and structure.
