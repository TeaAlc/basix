# Installation

Python 3.11 or newer and the Codex CLI are required.

```bash
./src/setup/install_as_plugin.sh [--dry-run] [--uninstall]
./src/setup/install_for_project.sh [TARGET] [--dry-run] [--local-network|--no-local-network] [--test-socket|--no-test-socket]
./src/setup/install_for_project.sh [TARGET] [--dry-run] --uninstall
```

The global installer remains copy-only. The project installer copies every
complete skill tree and the complete private native-agent tree, never creates
symlinks, and optionally manages purpose-based local access permissions in
`TARGET/.codex/config.toml`. Interactive installs ask separately about
`local-network` and `test-socket`; noninteractive installs must explicitly choose
one enable/disable flag for each capability. The `test-socket` permission allows
tests to use exactly `TARGET/test/test.sock`. Disable options remove only
Basix-owned settings and fail closed on foreign overlapping values or damaged
markers.
The global installer also copies plugin and marketplace metadata and registers
the plugin. The project installer uses the current directory when `TARGET` is
omitted.

Native agents live at `$CODEX_HOME/basix/agents` globally or
`TARGET/.codex/basix/agents` in a project. Managed configuration entries point to
those private copies; shared agent directories are not used. Project installation
does not create or manage `.basix`. Installers never create `.basix/adrs/`, ADR
templates, or an initial ADR; agents create the directory and indexes only when a
project first needs a qualifying ADR.

## Updates and safety

Installer state contains only `copy`, `dircopy`, and `dirfile` records. Target
paths are stored relative to the installer root, so a project or `CODEX_HOME`
can move without invalidating its inventory. A project install also rebases
legacy absolute records when they point to the known Basix trees. A
reinstallation leaves identical copies unchanged, synchronizes recorded managed
copies with the canonical source, and removes obsolete unchanged manifest files.
It rejects foreign directory contents, directory symlinks, unsafe symlinked
parents, special or unreadable source nodes, and targets physically identical to
their source before mutation.

If a project `.codex/config.toml` is deleted, the next install recreates it from
the managed instruction, agent, and selected local-access settings while leaving
foreign sibling files untouched.

Uninstall removes only files whose current hash matches their recorded install
hash. Locally modified files and foreign contents are preserved, and only empty
managed directories are pruned. `--dry-run` applies the same checks without
changing files, configuration, plugin registration, or state.

`local-network` enables a limited network proxy, access to `localhost`,
`127.0.0.1`, and `::1`, and local binding for every local port because Codex has
no port-level allowlist; Playwright is one possible use. `test-socket` permits
only the absolute project path `TARGET/test/test.sock` under
`[permissions.<profile>.network.unix_sockets]`. Both options can be enabled
together; the installer emits one combined effective profile. Permission changes
apply only to newly started Codex sessions, so restart Codex after changing them.

Exact legacy Basix Playwright permission blocks are recognized and migrated to
the purpose-based local-access names before mutation. Modified, partial, or
foreign-overlapping legacy blocks fail closed. Existing Basix, Defaultwienix,
link-mode, or older bundle installations must still be removed with the
installer version that created them; unknown old state records and artifacts are
neither recognized nor changed.

## Optional Lumen installation

Basix installation never installs Lumen and never starts project indexing. Install
Ory Lumen as a separate, explicit step when wanted:

```bash
./src/setup/install_ory_lumen.sh
```

Use that installer's own options and run project indexing separately. A Basix
uninstall does not change an independently installed Lumen integration.

The installer verifies that an existing active `lumen` MCP registration uses the
expected local runner and `stdio` argument. If that matching registration exists
but the local runtime or skill link is missing, the installer restores the
missing component without registering a duplicate server. A registration with a
different command, arguments, or activation state is treated as a conflict and
causes a safe exit before filesystem or MCP changes.

## Reports

Both installers report the target and dry-run state, followed by grouped results.
The Agents group lists every native agent and marks it as installed, updated, or
unchanged. Project reports include the local access transition and its
restart/socket or local-port warning; the global installer has no local access
phase.
