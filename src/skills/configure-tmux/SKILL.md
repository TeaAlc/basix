---
name: configure-tmux
description: "Basix-Skill: Safely diagnose, configure, and verify tmux mouse control, scrollback, copy mode, clipboard paste, and extended-key transport on Linux or Termux, including sessions reached from MobaXterm. Use for broken wheel scrolling, selection, right-click paste, modified keys such as Ctrl+Enter, alternate-screen behavior, tmux configuration conflicts, MobaXterm terminals, or Termux terminals."
---

# Configure tmux

Use the bundled scripts to make terminal behavior predictable without replacing
unrelated configuration, bindings, or sessions. Support Linux and Termux hosts in
v1. Treat MobaXterm as an external Windows client that requires manual checks.

Resolve all paths relative to this `SKILL.md`:

```bash
skill_dir=$(cd "$(dirname <path-to-this-SKILL.md>)" && pwd)
```

## Safety workflow

Follow these steps in order.

1. Run `scripts/diagnose-tmux.sh` before proposing any change. Use
   `--target-home`, `--entry-config`, and `--socket-name` or `--socket-path` when
   the active user, config, or server is not unambiguous. Do not execute shell
   profiles to discover tmux arguments.
2. Read the diagnosis and choose one mode. Do not recommend a change when the
   affected session is not clearly reachable. Read
   [references/troubleshooting.md](references/troubleshooting.md) for ambiguous
   sockets, configs, bindings, terminal capabilities, or clipboard transport.
3. Run `scripts/configure-tmux.sh --mode <mode>` without `--apply`. Present its
   zero-context diff, backups that will be created, and planned live actions.
4. Obtain explicit user confirmation for that exact apply operation. A request to
   diagnose, explain, or recommend does not authorize file changes.
5. Rerun the same command with `--apply`. Add `--reload` only when the user wants
   the selected live server updated and the socket is unambiguous. Never detach a
   client, kill a real server, or reload the user's whole entry config.
6. Run `scripts/verify-tmux.sh` for an isolated test. Use `--live` with the same
   target and socket only for a read-only check of an applied live configuration.
7. Report manual client checks. Do not claim MobaXterm wheel/right-click behavior
   or Termux touch/long-press behavior succeeded without testing that client.

Exit status `0` means healthy or successful, `1` means warning/manual action or a
limited diagnosis, `2` means a technical or safety failure, and `64` means invalid
CLI usage. A diagnosis returning `1` may still contain useful evidence; inspect
its `overall_status` and individual checks.

## Choose a mode

- `tmux-mouse`: Let tmux handle mouse reporting and copy mode. Set `mouse on` and
  a default history limit of `50000`; do not add wheel bindings. Use
  `--clipboard-helper` only after diagnosis and only when the user opts in.
- `native-terminal`: Let the outer terminal own selection and scrollback. Set
  `mouse off` and disable `smcup`/`rmcup` for `xterm*` through the reserved
  `terminal-overrides[1000]` element. Explain that source reload is insufficient:
  clients must detach and reattach for capability changes.
- `keyboard-only`: Set `mouse off`, keep normal alternate-screen behavior, and use
  standard tmux copy-mode keys. With default prefix `C-b`, enter copy mode with
  `[`, navigate with the active tmux key table, start/select text, and confirm to
  copy; paste the current tmux buffer with `C-b ]`.

Every mode enables negotiated tmux extended-key transport with `extended-keys on`
and the reserved `terminal-features[1000]` value `xterm*:extkeys`. Do not use
`extended-keys always`: it may rewrite traditional control keys for applications
that did not request extended input. Clients must detach and
reattach after this capability changes. Never create root bindings for physical
`Up` or `Down`, `Ctrl+C`, `Ctrl+Enter`, `Ctrl+J`, or `Shift+Enter`. Diagnose
existing relevant root bindings instead of overwriting them. The configure script
refuses foreign use of either reserved array slot, unsafe symlinks, incomplete
markers, or foreign managed-file contents.

## Transparent key transport

tmux transports key sequences; it cannot recover a distinction the outer client
did not encode. Preserve traditional Linux control bytes such as `Ctrl+C` and do
not add root bindings or force extended encoding. `Ctrl+Enter` works only when
the outer terminal emits a distinct extended sequence and the foreground
application negotiates that protocol. Diagnose and report either missing layer
instead of claiming tmux alone can fix it.

Codex reserves `Ctrl+C` to close the session. Never bind it to
`chat.interrupt_turn` or any other action. Do not recommend or change Codex or
other application keymaps as part of this skill; all applied fixes must remain in
tmux and its managed configuration.

This skill writes only the tmux files listed below. It never changes global or
project-local Codex configuration.

See [references/client-behavior.md](references/client-behavior.md) before advising
about Shift bypass, MobaXterm, SSH reconnects, alternate screens, or Termux touch.

## Clipboard helper

Keep `--clipboard-helper disabled` unless the user explicitly chooses clipboard
integration. Allowed values are `auto`, `wl-paste`, `xclip`, and `xsel`; `auto`
prefers Wayland, then X11 `xclip`, then `xsel`. Do not install packages or change
native client paste settings.

The managed `MouseDown3Pane` binding exists only in `tmux-mouse` mode. The helper
streams clipboard bytes through a private temporary file into a uniquely named
tmux buffer, pastes it into the clicked pane, and deletes the buffer. It never
places clipboard contents in arguments, variables, logs, or diagnostic JSON. If
the external clipboard is empty or unavailable, it falls back to an existing tmux
buffer and returns a warning; it never invents clipboard data.

## Managed files

Write only these user files:

- `${XDG_CONFIG_HOME:-~/.config}/tmux/conf.d/basix-terminal.conf`
- `${XDG_CONFIG_HOME:-~/.config}/tmux/bin/basix-clipboard-paste`
- one marked `source-file` block in the selected entry config

Prefer an existing `~/.tmux.conf`; otherwise create `~/.config/tmux/tmux.conf`.
If both exist, an explicit `--entry-config` is required. Never infer a target user
from `sudo`, assume `/home/codex`, delete timestamped backups, or remove these
files merely because Basix itself is uninstalled.
