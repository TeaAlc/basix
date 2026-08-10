# tmux troubleshooting

Use this reference after the read-only diagnosis identifies a warning or cannot
reach the affected session.

## Decision table

| Finding | Meaning | Safe next step |
|---|---|---|
| No server | There may be no session, or the default socket is wrong | Ask for the exact session/socket; do not create or kill a real server |
| Explicit socket unreachable | Wrong name/path, permissions, or different user | Confirm `-L`, `-S`, user, and `TMUX_TMPDIR`; do not guess another user's socket |
| Two standard configs | `~/.tmux.conf` and XDG config can conflict | Identify the actual entry config and pass `--entry-config` |
| Config not reported live | Server may predate the file or use `tmux -f` | Confirm invocation and config path without executing shell profiles |
| Mouse off | tmux will not request normal mouse events | Choose a mode, dry-run it, and confirm before apply |
| Wheel or mouse binding present | A custom root binding may override defaults | Inspect it; never replace an unknown live definition |
| Pane in a mode | Copy/view mode or a foreground application changes routing | Exit the mode or test the application separately |
| `smcup`/`rmcup` present | Alternate-screen applications may hide native scrollback | Use `native-terminal` only if outer-terminal scrollback is desired |
| Missing `kmous` | TERM/terminfo cannot describe mouse input reliably | Correct TERM/terminfo outside this skill before enabling tmux mouse |
| No clipboard transport | Display variables or helper program are unavailable | Keep helper disabled; use native paste or a tmux buffer |

## Configuration conflicts

The configure script owns one marked source block and one deterministic fragment.
It stops on incomplete or duplicate markers, symlinks, non-regular files, foreign
fragment content, or a different installed helper. Resolve those conditions
manually; do not broaden ownership or overwrite them.

`terminal-overrides[1000]` is reserved only after both file and live-server checks
show that Basix owns it. The script tests the array syntax against an isolated
server instead of guessing support from the tmux version. A foreign value is a
safety failure, not a merge opportunity.

## Live changes

`--reload` sources only the managed fragment into the selected server. It never
sources the whole entry config, detaches clients, or kills a real server. Before
changing a managed mouse binding, it compares the effective live definition with
the known Basix helper. A mismatch requires manual resolution.

Mouse and history options take effect on source. Terminal capability changes do
not fully affect existing clients; detach and reattach them. Re-test after SSH or
terminal-client reconnects because TERM, display access, and socket selection can
change.

## Clipboard failures

The helper selects `wl-paste` only with `WAYLAND_DISPLAY`, and `xclip` or `xsel`
only with `DISPLAY`. It redirects output directly to a private temporary file.
Empty output, command failure, or missing display falls back to the current tmux
buffer. If no tmux buffer exists, it returns warning status `1` without sending
data. It never prints clipboard contents.
