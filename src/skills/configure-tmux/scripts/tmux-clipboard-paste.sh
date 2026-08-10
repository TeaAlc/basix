#!/usr/bin/env bash
set -u

warn() { printf 'configure-tmux clipboard: %s\n' "$*" >&2; }
die() { warn "$1"; exit "${2:-2}"; }

if (( $# != 2 )); then
  die "internal usage: tmux-clipboard-paste.sh PANE TRANSPORT" 64
fi

pane=$1
transport=$2
case $pane in
  %*[!0-9]*|%) die "invalid pane target" 64 ;;
esac
case $transport in
  auto|wl-paste|xclip|xsel) ;;
  *) die "invalid clipboard transport" 64 ;;
esac

tmux_bin=${TMUX_BIN:-tmux}
command -v "$tmux_bin" >/dev/null 2>&1 || die "tmux is unavailable"

choose_transport() {
  if [[ $transport != auto ]]; then
    printf '%s\n' "$transport"
    return
  fi
  if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-paste >/dev/null 2>&1; then
    printf '%s\n' wl-paste
  elif [[ -n ${DISPLAY:-} ]] && command -v xclip >/dev/null 2>&1; then
    printf '%s\n' xclip
  elif [[ -n ${DISPLAY:-} ]] && command -v xsel >/dev/null 2>&1; then
    printf '%s\n' xsel
  else
    return 1
  fi
}

paste_existing_buffer() {
  if "$tmux_bin" list-buffers -F '#{buffer_name}' 2>/dev/null | grep -q .; then
    "$tmux_bin" paste-buffer -t "$pane" || return 2
    warn "clipboard unavailable; pasted the current tmux buffer"
    return 1
  fi
  warn "clipboard unavailable and tmux has no buffer"
  return 1
}

selected=$(choose_transport) || {
  paste_existing_buffer
  exit $?
}

case $selected in
  wl-paste)
    [[ -n ${WAYLAND_DISPLAY:-} ]] || { paste_existing_buffer; exit $?; }
    command -v wl-paste >/dev/null 2>&1 || { paste_existing_buffer; exit $?; }
    clipboard_command=(wl-paste)
    ;;
  xclip)
    [[ -n ${DISPLAY:-} ]] || { paste_existing_buffer; exit $?; }
    command -v xclip >/dev/null 2>&1 || { paste_existing_buffer; exit $?; }
    clipboard_command=(xclip -selection clipboard -out)
    ;;
  xsel)
    [[ -n ${DISPLAY:-} ]] || { paste_existing_buffer; exit $?; }
    command -v xsel >/dev/null 2>&1 || { paste_existing_buffer; exit $?; }
    clipboard_command=(xsel --clipboard --output)
    ;;
esac

umask 077
temp_file=$(mktemp "${TMPDIR:-/tmp}/basix-tmux-clipboard.XXXXXX") || die "cannot create private temporary file"
buffer_name=basix-clipboard-${temp_file##*.}
cleanup() {
  rm -f -- "$temp_file"
  "$tmux_bin" delete-buffer -b "$buffer_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

if ! "${clipboard_command[@]}" >"$temp_file" 2>/dev/null || [[ ! -s $temp_file ]]; then
  paste_existing_buffer
  exit $?
fi

if ! "$tmux_bin" load-buffer -b "$buffer_name" -- "$temp_file"; then
  die "tmux could not load clipboard data"
fi
if ! "$tmux_bin" paste-buffer -d -b "$buffer_name" -t "$pane"; then
  die "tmux could not paste clipboard data"
fi
exit 0
