# Installation

Python 3.11 or newer and the Codex CLI are required.

```bash
./src/setup/install_as_plugin.sh [--dry-run] [--uninstall]
./src/setup/install_for_project.sh [TARGET] [--dry-run] [--playwright|--no-playwright]
./src/setup/install_for_project.sh [TARGET] [--dry-run] --uninstall
```

The global installer remains copy-only. The project installer copies every
complete skill tree and the complete private native-agent tree, never creates
symlinks, and optionally manages Playwright sandbox permissions in
`TARGET/.codex/config.toml`. Interactive installs ask `Enable Playwright sandbox
permissions? [y/N]`; noninteractive installs must explicitly choose
`--playwright` or `--no-playwright`. `--no-playwright` removes only Basix-owned
settings and fails closed on foreign overlapping values or damaged markers.
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

Installer state contains only `copy`, `dircopy`, and `dirfile` records. A
reinstallation leaves identical copies unchanged, synchronizes recorded managed
copies with the canonical source, and removes obsolete unchanged manifest files.
It rejects foreign directory contents, directory symlinks, unsafe symlinked
parents, special or unreadable source nodes, and targets physically identical to
their source before mutation.

Uninstall removes only files whose current hash matches their recorded install
hash. Locally modified files and foreign contents are preserved, and only empty
managed directories are pruned. `--dry-run` applies the same checks without
changing files, configuration, plugin registration, or state.

Playwright permissions enable the `playwright` profile, limited network proxy
support, and access to `localhost`, `127.0.0.1`, and `::1`. Local port binding is
allowed for every local port because Codex has no port-level allowlist; the
installer never promises per-port restriction. Permission changes apply only to
newly started Codex sessions, so restart Codex after enabling or disabling them.

There is deliberately no legacy detection or migration. Existing Basix,
Defaultwienix, link-mode, or older bundle installations must be removed with the
installer version that created them before this version is installed. Unknown old
state records and artifacts are neither recognized nor changed.

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
unchanged. Project reports include the Playwright permission transition and its
restart/local-port warning; the global installer has no Playwright phase.
