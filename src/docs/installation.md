# Installation

Python 3.11 or newer and the Codex CLI are required.

```bash
./src/setup/install_as_plugin.sh [--dry-run] [--uninstall]
./src/setup/install_for_project.sh [TARGET] [--dry-run] [--uninstall]
```

Both installers are copy-only. They copy every complete skill tree and the
complete private native-agent tree, never create symlinks, and never prompt for
an installation mode. The global installer also copies plugin and marketplace
metadata and registers the plugin. The project installer uses the current
directory when `TARGET` is omitted.

Native agents live at `$CODEX_HOME/basix/agents` globally or
`TARGET/.codex/basix/agents` in a project. Managed configuration entries point to
those private copies; shared agent directories are not used. Project installation
does not create or manage `.basix`.

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

## Reports

Both installers report the target and dry-run state, followed by grouped results.
They do not report a mode or a Lumen phase.
