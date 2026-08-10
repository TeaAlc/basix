# tmux client behavior

Consult this reference when selecting a mode or defining manual acceptance checks.

## Behavior matrix

| Situation | `tmux-mouse` | `native-terminal` | `keyboard-only` |
|---|---|---|---|
| Wheel over normal pane | tmux scrolls history or enters copy mode | outer terminal scrolls its history | outer terminal behavior; use keys for tmux history |
| Selection | tmux owns normal mouse reports; client bypass modifiers may help | outer terminal owns selection | select in tmux copy mode with keys |
| Alternate-screen program | application may own mouse reports | `xterm*` alternate-screen switching is suppressed after reattach | normal alternate-screen behavior |
| Clipboard paste | native client paste, tmux buffer, or opt-in helper | native client paste | native client paste or tmux buffer |
| Remote reconnect | verify TERM, socket, config, and client again | detach/reattach after capability changes | verify key table after reconnect |
| Modified keys | tmux transports negotiated extended-key sequences | tmux transports negotiated extended-key sequences | tmux transports negotiated extended-key sequences |

tmux mouse support routes events according to the pane, status line, and active
mode. Do not add generic wheel bindings: modern tmux already has context-aware
mouse behavior, and custom root bindings often hide application or copy-mode
state. See the [tmux mouse support section](https://man7.org/linux/man-pages/man1/tmux.1.html#MOUSE_SUPPORT).

## Extended keys and Codex

All three modes enable negotiated tmux extended-key transport for `xterm*`
clients. Keep `extended-keys on`: `always` can rewrite traditional control keys
for applications that did not request extended input. Detach
and reattach every client after applying or reloading so the terminal capabilities
are negotiated again. Then test the actual terminal: support remains dependent on
the outer client and the complete connection path. In particular, tmux cannot
distinguish `Ctrl+Enter` from `Enter` if MobaXterm, Termux, or another outer
terminal sends the same bytes for both.

tmux only transports the key sequence. Codex reserves `Ctrl+C` to close the
session, so never add it to `chat.interrupt_turn` or any other application
keymap. This skill neither recommends nor changes Codex or other application
configuration and creates no tmux root bindings for these keys. Applied fixes
belong exclusively to tmux and its managed configuration.

## Shift and client bypass

Many terminal clients use Shift as a local bypass for selection or wheel input,
but this is not a tmux guarantee. Describe it as a client-specific experiment,
not as the configured behavior. A foreground program can enable mouse reporting
and receive events that tmux or the outer terminal would otherwise handle.

## MobaXterm

MobaXterm runs outside the Linux or Termux host. The skill does not edit its
Windows settings. Use its current terminal and mouse settings as manual evidence,
and test selection, wheel direction, alternate-screen applications, right-click,
and reconnect on the real client. Consult the
[official MobaXterm documentation](https://mobaxterm.mobatek.net/documentation.html)
for client controls; do not claim a host-side tmux change reconfigured MobaXterm.

## Termux

Termux is a supported v1 host, but Android gestures belong to the client. Test
touch scrolling, selection handles, extra keys, long-press, and the software
keyboard on the actual device. Long-press is not a universal or stable paste
contract. The current implementation context lives in the
[Termux terminal client](https://github.com/termux/termux-app/blob/master/app/src/main/java/com/termux/app/terminal/TermuxTerminalViewClient.java).

## Manual acceptance

After automated verification, ask the user to test only relevant items:

1. Wheel up and down in a shell pane with enough history.
2. Selection and copy with the intended owner: tmux or outer terminal.
3. An alternate-screen program such as an editor or pager.
4. A mouse-aware foreground application if one caused the problem.
5. Native paste and, when enabled, the managed right-click helper.
6. Detach/reattach and SSH reconnect behavior.
7. `Ctrl+Enter`, `Ctrl+J`, and `Shift+Enter` after reconnecting the client.
