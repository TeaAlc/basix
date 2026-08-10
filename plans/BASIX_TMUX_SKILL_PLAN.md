# Plan: Basix Codex Skill for tmux Setup and Mouse/Clipboard Troubleshooting

## 1. Objective

Create an installable Codex skill named `configure-tmux` that can:

- install or safely update a user's tmux configuration;
- preserve normal Up/Down key behavior;
- diagnose whether wheel and paste failures originate in tmux or in the outer terminal client;
- configure either pane-aware tmux mouse handling or native terminal scrolling/paste;
- handle MobaXterm-over-SSH and Android Termux explicitly;
- validate both configuration syntax and the effective state of a real tmux server/client;
- avoid destroying sessions or overwriting unrelated user configuration.

The skill must not assume that `set -g mouse on` is always the correct fix. The correct mode depends on whether the terminal emits mouse reports and whether the user wants tmux pane scrollback or the terminal's native scrollback.

## 2. Proposed Skill Layout

```text
configure-tmux/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── scripts/
│   ├── diagnose-tmux.sh
│   ├── configure-tmux.sh
│   └── verify-tmux.sh
└── references/
    ├── client-behavior.md
    └── troubleshooting.md
```

Do not add a README, changelog, or separate installation guide. Keep essential routing and execution instructions in `SKILL.md`; put client-specific details and the longer decision table in references.

## 3. Skill Metadata

Suggested frontmatter:

```yaml
---
name: configure-tmux
description: Safely install, update, diagnose, and validate tmux configuration, including mouse-wheel scrollback, command-history interference, copy/paste, right-click behavior, arrow keys, terminal capability mismatches, MobaXterm SSH sessions, and Android Termux clients. Use when Codex needs to configure tmux or troubleshoot input and scrolling behavior inside tmux.
---
```

Suggested UI metadata:

- `display_name`: `Configure tmux`
- `short_description`: `Set up and troubleshoot tmux input and scrolling`
- `default_prompt`: `Configure tmux safely for this terminal and verify scrolling, paste, and key behavior.`

Generate `agents/openai.yaml` with the Skill Creator helper rather than writing it manually.

## 4. Core Technical Model

The skill must teach these distinctions before changing configuration:

1. **Native terminal scrollback** is owned by MobaXterm, Termux, or another outer terminal. It behaves like a plain SSH terminal but is not pane-aware.
2. **tmux copy-mode scrollback** is owned by tmux. It is pane-aware and requires the outer terminal to send mouse reports when the wheel is used.
3. A wheel that changes shell or TUI command history is usually arriving as the same escape sequence as the Up/Down keys. tmux cannot distinguish these synthesized arrow sequences from physical arrow-key presses.
4. tmux mouse handling is effectively all-or-nothing. When enabled, tmux receives mouse events; when disabled, the outer terminal owns them.
5. Right-click paste is also client-dependent. With tmux mouse handling enabled, a client may send the click to tmux instead of performing its native paste action. Modifier bypasses and client settings vary.
6. The outer alternate screen matters. A client such as MobaXterm may translate wheel motion into Up/Down while tmux occupies the alternate screen but does not receive usable mouse reports.
7. A syntactically correct config is insufficient evidence. The skill must inspect the actual server, client, socket, terminfo capabilities, and active bindings.

## 5. Required Discovery Workflow

Run read-only discovery before proposing or applying a mode:

```sh
tmux -V
printf 'USER=%s HOME=%s TERM=%s TMUX=%s SSH_TTY=%s\n' \
  "$USER" "$HOME" "$TERM" "${TMUX:-}" "${SSH_TTY:-}"
tmux display-message -p \
  'socket=#{socket_path} client=#{client_name} tty=#{client_tty} term=#{client_termname} features=#{client_termfeatures}'
tmux show-options -g mouse
tmux show-options -g history-limit
tmux list-keys -T root
tmux display-message -p \
  'pane=#{pane_id} mode=#{pane_in_mode} alternate=#{alternate_on} mouse_any=#{mouse_any_flag}'
```

Also inspect, without exposing secrets:

- `~/.tmux.conf` and `~/.config/tmux/tmux.conf`;
- shell aliases/functions that launch tmux with `-f`, `-L`, or `-S`;
- running tmux processes and sockets;
- `infocmp -1 "$TERM"` or the outer client terminfo for `kmous`, `smcup`, and `rmcup`;
- `DISPLAY`, `WAYLAND_DISPLAY`, and the existence of `wl-paste`, `xclip`, or `xsel` when clipboard integration is requested;
- terminal-identification environment variables when available.

If no server is visible but the user claims to be inside tmux, do not keep changing bindings blindly. Ask the user to start Codex inside the failing session or collect the diagnostic output from that exact session. Different users, hosts, containers, and tmux sockets may have different effective configurations.

## 6. Mode Selection

### Mode A: tmux-managed, pane-aware mouse scrolling

Choose this only when the client sends usable mouse reports and the user wants per-pane tmux scrollback.

Minimum configuration:

```tmux
set -g mouse on
set -g history-limit 50000
```

Normally prefer tmux's default wheel bindings. Add explicit bindings only when diagnostics prove the defaults are being overridden. Never bind ordinary `Up` and `Down` in the root table as a workaround for wheel events; that would break physical arrow keys.

For right-click paste, prefer documented client behavior or a client bypass modifier. Only add a remote clipboard helper when the clipboard transport is confirmed and the user wants tmux to own right-click. A helper should:

- support Wayland (`wl-paste`) and X11/X forwarding (`xclip` or `xsel`);
- suppress clipboard contents in logs and tests;
- quote arbitrary clipboard text safely;
- define behavior for empty clipboard content and trailing newlines;
- fall back to the tmux paste buffer;
- be shell-syntax tested.

### Mode B: native terminal scrolling and paste

Choose this for MobaXterm or Termux when the client does not deliver usable mouse reports, or when the user explicitly wants the same behavior as plain SSH.

For an outer client advertised as `xterm` or `xterm-*`:

```tmux
set -g mouse off
set -g history-limit 50000
set -g terminal-overrides 'xterm*:smcup@:rmcup@'
```

This keeps the outer terminal on its normal screen so that it owns scrollback and paste. Document the tradeoff: scrolling is the outer terminal's combined display history, not tmux's pane-specific copy-mode history.

Do not append the override on every reload with `set -as`; repeated sourcing would duplicate it. Use an idempotent assignment or a stable array element while preserving any user-defined overrides.

If a previous version of the managed configuration installed custom mouse bindings, explicitly remove only those known managed bindings on migration:

```tmux
unbind-key -n WheelUpPane
unbind-key -n WheelDownPane
unbind-key -n MouseDown3Pane
```

Do not indiscriminately delete user bindings. Track managed lines with clearly delimited comments or a sourced managed fragment.

### Mode C: keyboard-only tmux copy mode

Offer this when native mouse/touch behavior cannot provide pane-aware history:

- `Prefix` + `[` enters copy mode;
- PageUp/PageDown or configured copy-mode keys navigate;
- `q` exits copy mode;
- physical Up/Down remain available to the shell or foreground application outside copy mode.

## 7. Client-Specific Guidance

### MobaXterm

- Plain SSH success does not prove that behavior will remain the same after tmux enters the alternate screen.
- Confirm `Settings > Configuration > Terminal > Paste using right-click`, including any per-session override.
- Document Ctrl+Right-click or Shift+Right-click as context-menu/bypass alternatives supported by MobaXterm documentation.
- Treat any setting named similar to `Disable xterm-style mouse reporting` as version-dependent until verified in the installed MobaXterm version; do not claim it is universally present.
- If tmux reports `mouse on`, `mouse_any=0`, correct bindings, and valid `kmous`, but wheel input still behaves as Up/Down and right-click never reaches tmux, classify the problem as client-side mouse reporting. Prefer Mode B unless the user agrees to change the local MobaXterm profile.

### Android Termux

- Finger scrolling is handled locally by Termux's terminal view, not emitted as tmux SGR wheel reports.
- Normal phone paste is long-press followed by Paste, or a configured `PASTE` extra key.
- A physical secondary mouse button opens Termux's context behavior; do not describe phone long-press as literal right-click.
- Prefer Mode B for touch-first use. Offer keyboard copy mode when pane-specific history is required.

### Other clients

- Detect rather than guess.
- Explain the difference between a terminal bypass modifier and tmux mouse handling.
- Do not hard-code MobaXterm workarounds for unrelated terminal types.

## 8. Safe Configuration Strategy

The implementation must:

1. Resolve the actual user's home directory without assuming `/home/codex`.
2. Prefer `~/.config/tmux/tmux.conf` for the managed configuration.
3. Support `~/.tmux.conf` as a compatibility entry point that sources the XDG path when appropriate.
4. Inspect both files before editing.
5. Preserve existing user configuration and unrelated changes.
6. Use a clearly marked managed block or a separate sourced file such as `~/.config/tmux/conf.d/codex-terminal.conf`.
7. Produce a diff and request confirmation before replacing ambiguous or conflicting settings.
8. Create a recoverable backup before modifying an existing file.
9. Never run `tmux kill-server` merely to activate settings; it destroys sessions.
10. Reload with `tmux source-file` when safe, but explain that terminal capability changes such as `smcup@`/`rmcup@` require detach and reattach.
11. Warn that removing a line from a tmux config does not remove an already loaded binding. Use explicit `unbind-key` migration commands for bindings previously owned by the skill.

## 9. Script Responsibilities

### `scripts/diagnose-tmux.sh`

- Read-only by default.
- Emit a concise human-readable report, with an optional machine-readable mode.
- Distinguish: no server, wrong socket, config not loaded, mouse disabled, custom binding conflict, foreground application requests mouse, missing client mouse reporting, unavailable clipboard transport, and alternate-screen mismatch.
- Never print clipboard contents or sensitive environment values.
- Return distinct exit codes for healthy, warning, and failed states.

### `scripts/configure-tmux.sh`

- Accept explicit modes such as `--mode tmux-mouse`, `--mode native-terminal`, and `--mode keyboard-only`.
- Support `--dry-run` and `--target-home` for isolated testing.
- Be idempotent.
- Modify only the managed block or managed fragment.
- Preserve permissions and create recoverable backups.
- Never detach clients, kill servers, or install packages without separate authorization.

### `scripts/verify-tmux.sh`

- Run shell syntax checks.
- Start an isolated tmux server with a task-specific `TMUX_TMPDIR` and socket name.
- Load the generated config and assert options/bindings.
- Clean up only its own isolated server and temporary directory.
- When invoked inside the real failing session, report effective client capabilities and whether a detach/reattach is still required.

## 10. Validation Matrix

At minimum, test these cases:

| Case | Expected result |
|---|---|
| Fresh home, tmux-managed mode | `mouse on`; default or intended wheel bindings present |
| Fresh home, native-terminal mode | `mouse off`; `xterm*:smcup@:rmcup@` effective |
| Existing `.tmux.conf` | User content preserved; managed source/block added once |
| Existing XDG config | User content preserved; managed block updated idempotently |
| Config sourced twice | No duplicate overrides, sources, or bindings |
| Migration from tmux-managed to native | Known managed mouse bindings removed from live server |
| Physical Up/Down | Remain unbound in root table and reach foreground application |
| MobaXterm over SSH | After detach/reattach, native wheel and right-click behave as plain SSH |
| Android Termux | Touch scroll remains local; long-press paste documented |
| Wrong socket or user | Diagnosis reports mismatch instead of claiming success |
| Clipboard helper without DISPLAY/Wayland | Clear fallback; no hang and no clipboard content logged |
| Existing live sessions | No `kill-server`; reload and reattach instructions only |

For terminal capability validation after Mode B and reattach, expect:

```text
mouse off
smcup: [missing]
rmcup: [missing]
alternate=0
```

Do not claim end-to-end mouse success based only on these values. Require the user to perform the physical wheel/touch/right-click test because Codex cannot synthesize an event from the user's outer terminal hardware.

## 11. Acceptance Criteria

The implemented skill is complete when:

- `SKILL.md` is concise, imperative, and below 500 lines;
- frontmatter contains only `name` and `description`;
- `agents/openai.yaml` is generated and consistent with the skill;
- all scripts pass `shellcheck` when available and execute successfully in isolated test homes;
- the Skill Creator `quick_validate.py` passes;
- configuration generation is idempotent;
- a real tmux attach/detach test validates effective capabilities;
- the skill never breaks physical Up/Down keys;
- destructive session actions require explicit user authorization;
- forward-testing covers at least one tmux-managed case and one native-terminal case without giving the test agent the expected diagnosis.

## 12. Implementation Sequence for the New Session

1. Read the Basix router skill and the Skill Creator skill completely.
2. Initialize `configure-tmux` using Skill Creator's `init_skill.py` with `scripts,references` resources and the proposed interface metadata.
3. Implement the read-only diagnostic script first and test it against no-server and live-server states.
4. Implement the idempotent managed-config writer with dry-run support.
5. Implement isolated verification and migration tests.
6. Write the client behavior and troubleshooting references with primary-source links.
7. Write the concise `SKILL.md` workflow and route client-specific details to the references.
8. Generate or refresh `agents/openai.yaml`.
9. Run `quick_validate.py`, script tests, and representative real-server checks.
10. Forward-test both configuration modes using fresh agents and raw task prompts.
11. If implementing inside the canonical Basix repository, also run the Basix repository's required verification and setup test suites.

## 13. Primary References to Preserve

- tmux FAQ, mouse behavior and terminal bypass modifiers: <https://github.com/tmux/tmux/wiki/FAQ>
- MobaXterm documentation, terminal and right-click settings: <https://mobaxterm.mobatek.net/documentation.html>
- MobaXterm configuration settings: <https://blog.mobatek.net/post/mobaxterm-configuration-settings/>
- Termux terminal view implementation, touch and mouse handling: <https://github.com/termux/termux-app/blob/master/terminal-view/src/main/java/com/termux/view/TerminalView.java>
- Termux releases, paste and PageUp/PageDown features: <https://github.com/termux/termux-app/releases>
- Local installed tmux man page for the target version; do not assume all options behave identically across versions.
