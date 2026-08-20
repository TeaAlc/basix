#!/usr/bin/env bash
set -euo pipefail

readonly SERVER_NAME=scrapling DEFAULT_IMAGE='docker.io/pyd4vinci/scrapling:latest'
readonly DEFAULT_PORT=8002
readonly TOR_BUILD_TAG='localhost/basix-scrapling-tor:bookworm'
readonly EXIT_USAGE=2 EXIT_PREREQUISITE=3 EXIT_RUNTIME=4 EXIT_PULL=5 EXIT_IMAGE_CHECK=6
readonly EXIT_CONFLICT=7 EXIT_CODEX=8 EXIT_VERIFY=9
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/scrapling-tor" && pwd); readonly SOURCE_DIR
SCAN=$SOURCE_DIR/codex_scan.py
image=$DEFAULT_IMAGE runtime_choice=auto runtime='' port=$DEFAULT_PORT force=false dry_run=false
codex_home=${CODEX_HOME:-${HOME:?HOME is required}/.codex}
install_dir=$codex_home/basix/scrapling-tor launcher=$install_dir/launcher.sh

usage() { cat <<EOF
Usage: ./install-scrapling-codex.sh [--runtime auto|podman|docker] [--image IMAGE] [--port PORT] [--force] [--dry-run] [--help]

Installs exactly one canonical Codex MCP named "scrapling" behind a managed,
fail-closed Tor sidecar. This guarantees Tor-only container egress; it does not
give Chromium the fingerprinting properties of Tor Browser.

  --runtime NAME  auto, podman, or docker (auto prefers Podman)
  --image IMAGE   Scrapling image (default: $DEFAULT_IMAGE)
  --port PORT     Unprivileged loopback service port (default: $DEFAULT_PORT)
  --force         Confirm noninteractive replacement of exactly one registration
  --dry-run       Detect conflicts and print actions without changing anything
  --help          Show this help
EOF
}
fail() { local code=$1; shift; printf 'Error: %s\n' "$*" >&2; exit "$code"; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }
validate_image() {
  local ref=$1 component
  [[ -n $ref && ${#ref} -le 255 && $ref != *[[:space:]]* && $ref != -* ]] || return 1
  [[ $ref =~ ^([a-zA-Z0-9.-]+(:[0-9]+)?/)?[a-z0-9._/-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-fA-F0-9]{64})?$ ]] || return 1
  [[ $ref != */ && $ref != *//* ]] || return 1
  IFS=/ read -r -a components <<<"${ref%%@*}"
  for component in "${components[@]}"; do [[ -n $component && $component != . && $component != .. ]] || return 1; done
}
normalize_image_reference() {
  local ref=$1
  if { [[ $ref =~ @sha256:[a-fA-F0-9]{64}$ ]] && validate_image "$ref"; } ||
     [[ $ref =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
    printf '%s\n' "$ref"
  elif [[ $ref =~ ^[a-fA-F0-9]{64}$ ]]; then
    printf 'sha256:%s\n' "$ref"
  else
    return 1
  fi
}

while (($#)); do case $1 in
  --runtime) (($# >= 2)) || fail "$EXIT_USAGE" '--runtime requires a value'; runtime_choice=$2; shift 2 ;;
  --image) (($# >= 2)) || fail "$EXIT_USAGE" '--image requires a value'; image=$2; shift 2 ;;
  --port) (($# >= 2)) || fail "$EXIT_USAGE" '--port requires a value'; port=$2; shift 2 ;;
  --force) force=true; shift ;; --dry-run) dry_run=true; shift ;; --help|-h) usage; exit 0 ;;
  *) fail "$EXIT_USAGE" "Unknown option: $1" ;;
esac; done
validate_image "$image" || fail "$EXIT_USAGE" "Invalid OCI image reference: $image"
if [[ ! $port =~ ^[0-9]+$ ]]; then
  fail "$EXIT_USAGE" 'Port must be an integer from 1024 through 65535'
fi
port=$((10#$port))
if ((port < 1024 || port > 65535)); then
  fail "$EXIT_USAGE" 'Port must be an integer from 1024 through 65535'
fi
endpoint="http://127.0.0.1:$port/mcp"
command -v python3 >/dev/null || fail "$EXIT_PREREQUISITE" 'python3 is required'
command -v codex >/dev/null || fail "$EXIT_PREREQUISITE" 'Codex CLI not found'
case $runtime_choice in
  auto) if command -v podman >/dev/null; then runtime=podman; elif command -v docker >/dev/null; then runtime=docker; else fail "$EXIT_PREREQUISITE" 'Neither Podman nor Docker CLI was found'; fi ;;
  podman|docker) runtime=$runtime_choice; command -v "$runtime" >/dev/null || fail "$EXIT_PREREQUISITE" "Requested runtime '$runtime' was not found" ;;
  *) fail "$EXIT_USAGE" "Invalid runtime: $runtime_choice" ;;
esac

codex_help=$(codex mcp --help 2>&1) || fail "$EXIT_CODEX" 'Codex MCP command is unusable'
[[ $codex_help == *add* && $codex_help == *list* && $codex_help == *remove* ]] || fail "$EXIT_CODEX" 'Codex lacks required MCP add/list/remove commands'
list_help=$(codex mcp list --help 2>&1) || fail "$EXIT_CODEX" 'Codex MCP list is unavailable'
[[ $list_help == *--json* ]] || fail "$EXIT_CODEX" 'Codex MCP list lacks --json support'

work=$(mktemp -d "${TMPDIR:-/tmp}/basix-scrapling-install.XXXXXX")
list_file=$work/list.json backup_config=$work/config.toml backup_support=$work/support
support_installed=false old_support_saved=false codex_changed=false config_existed=false
cleanup() {
  local status=$?; trap - EXIT
  if ((status != 0)); then
    if $codex_changed; then
      if $config_existed; then mkdir -p "$codex_home"; cp -p "$backup_config" "$codex_home/config.toml" || status=$EXIT_CODEX
      else rm -f "$codex_home/config.toml" || status=$EXIT_CODEX; fi
    fi
    if $support_installed; then rm -rf "$install_dir"; fi
    if $old_support_saved && [[ -e $backup_support ]]; then mv "$backup_support" "$install_dir" || status=$EXIT_CODEX; fi
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

scan_codex() {
  codex mcp list --json >"$list_file" 2>"$work/list.err" || fail "$EXIT_CODEX" 'codex mcp list --json failed'
  PYTHONDONTWRITEBYTECODE=1 python3 "$SCAN" fingerprint <"$list_file" || fail "$EXIT_CODEX" 'Codex returned invalid MCP JSON'
}
initial_scan=$(scan_codex); read -r match_count initial_fingerprint <<<"$initial_scan"
printf 'Detected Scrapling MCP registrations: %s\n' "$match_count"
PYTHONDONTWRITEBYTECODE=1 python3 "$SCAN" report <"$list_file" || fail "$EXIT_CODEX" 'Could not report Codex registrations'
((match_count < 2)) || fail "$EXIT_CONFLICT" 'Multiple Scrapling MCP registrations found; no changes were made'

expected_existing=false old_name=''
if ((match_count == 1)); then
  old_name=$(PYTHONDONTWRITEBYTECODE=1 python3 "$SCAN" names <"$list_file")
  if PYTHONDONTWRITEBYTECODE=1 python3 "$SCAN" verify --endpoint "$endpoint" <"$list_file" 2>/dev/null; then expected_existing=true; fi
  if ! $expected_existing; then
    if $force; then printf 'Replacement of registration %q confirmed by --force.\n' "$old_name"
    elif $dry_run; then printf 'Would prompt to remove %q and replace it with canonical "scrapling".\n' "$old_name"
    elif [[ -t 0 ]]; then
      printf 'Remove %q and replace it with canonical Tor-only "scrapling"? [y/N] ' "$old_name" >/dev/tty
      IFS= read -r answer </dev/tty || answer=''
      [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]] || fail "$EXIT_CONFLICT" 'Replacement was not approved'
    else fail "$EXIT_CONFLICT" 'One Scrapling registration exists; rerun with --force to confirm replacement'; fi
  fi
fi

"$runtime" info >/dev/null 2>&1 || fail "$EXIT_RUNTIME" "Cannot use $runtime"
if $dry_run; then
  printf 'Dry run (no changes): pull %q; pin its digest; verify exact tool policy; build/pin Tor; validate networks and sidecar; test Tor egress.\n' "$image"
  ((match_count == 0)) || $expected_existing || printf 'Would run: codex mcp remove %q\n' "$old_name"
  printf 'Would run: codex mcp add scrapling --url %q\n' "$endpoint"
  exit 0
fi

run "$runtime" pull "$image" || fail "$EXIT_PULL" "Could not pull $image"
scrapling_inspected=$("$runtime" image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$image") || fail "$EXIT_IMAGE_CHECK" 'Could not pin pulled Scrapling image'
scrapling_pinned=$(normalize_image_reference "$scrapling_inspected") || fail "$EXIT_IMAGE_CHECK" 'Runtime did not return an immutable Scrapling digest or image ID'
scrapling_id_inspected=$("$runtime" image inspect --format '{{.Id}}' "$scrapling_pinned") || fail "$EXIT_IMAGE_CHECK" 'Could not resolve pinned Scrapling image ID'
scrapling_id=$(normalize_image_reference "$scrapling_id_inspected") || fail "$EXIT_IMAGE_CHECK" 'Runtime did not return Scrapling immutable image ID'
run "$runtime" run --rm --network none --entrypoint /app/.venv/bin/python "$scrapling_pinned" -c '
import asyncio,inspect
from scrapling.core.ai import ScraplingMCPServer as S
s=S(); expected={"open_session","close_session","list_sessions","get","bulk_get","fetch","bulk_fetch","stealthy_fetch","bulk_stealthy_fetch","screenshot"}
actual={t.name for t in asyncio.run(s._build_server("127.0.0.1",8000).list_tools())}
assert actual==expected
required={"open_session":{"proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"get":{"proxy","proxy_auth","http3"},"bulk_get":{"proxy","proxy_auth","http3"},"fetch":{"proxy","cdp_url","real_chrome","executable_path","session_id"},"bulk_fetch":{"proxy","cdp_url","real_chrome","executable_path","session_id"},"stealthy_fetch":{"proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc","session_id"},"bulk_stealthy_fetch":{"proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc","session_id"}}
assert all(v <= set(inspect.signature(getattr(s,k)).parameters) for k,v in required.items())
assert "allowed_hosts" in inspect.signature(s.serve).parameters
' || fail "$EXIT_IMAGE_CHECK" 'Scrapling MCP tools or schemas are incompatible with the Basix policy'
run "$runtime" build --label 'io.basix.scrapling-tor.managed=true' -t "$TOR_BUILD_TAG" "$SOURCE_DIR" || fail "$EXIT_PULL" 'Could not build Tor sidecar'
tor_inspected=$("$runtime" image inspect --format '{{.Id}}' "$TOR_BUILD_TAG") || fail "$EXIT_IMAGE_CHECK" 'Could not pin Tor image'
tor_pinned=$(normalize_image_reference "$tor_inspected") || fail "$EXIT_IMAGE_CHECK" 'Runtime did not return an immutable Tor image ID'

mkdir -p "$work/support"
cp "$SOURCE_DIR/launcher.sh" "$SOURCE_DIR/policy_mcp.py" "$SOURCE_DIR/codex_scan.py" "$SOURCE_DIR/health_check.py" "$work/support/"
printf 'RUNTIME=%q\nSCRAPLING_IMAGE=%q\nSCRAPLING_ID=%q\nTOR_IMAGE=%q\nPORT=%q\n' "$runtime" "$scrapling_pinned" "$scrapling_id" "$tor_pinned" "$port" >"$work/support/config"
chmod 755 "$work/support/launcher.sh" "$work/support/codex_scan.py" "$work/support/health_check.py"
mkdir -p "$(dirname "$install_dir")"
if [[ -e $install_dir ]]; then mv "$install_dir" "$backup_support"; old_support_saved=true; fi
if ! mv "$work/support" "$install_dir"; then
  if $old_support_saved && mv "$backup_support" "$install_dir"; then old_support_saved=false; fi
  fail "$EXIT_VERIFY" 'Could not install Scrapling support files'
fi
support_installed=true
run "$launcher" prepare || {
  launcher_status=$?
  ((launcher_status == EXIT_CONFLICT)) && fail "$EXIT_CONFLICT" 'Managed runtime resource conflict; Codex was not changed'
  fail "$EXIT_VERIFY" 'Managed Tor failed validation or bootstrap; Codex was not changed'
}
if [[ $runtime == podman ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user enable podman-restart.service >/dev/null 2>&1; then
    printf 'Enabled Podman user restart service for managed containers.\n'
  else
    printf 'Warning: Podman user-systemd autostart is unavailable; run %q start after reboot.\n' "$launcher" >&2
  fi
fi
# The only non-rollbackable phase starts here. Re-scan immediately around every
# Codex mutation and restore config.toml byte-for-byte if any operation fails.
current_scan=$(scan_codex); read -r current_count current_fingerprint <<<"$current_scan"
[[ $current_count == "$match_count" && $current_fingerprint == "$initial_fingerprint" ]] || fail "$EXIT_CONFLICT" 'Codex MCP configuration changed concurrently'
if [[ -e $codex_home/config.toml ]]; then cp -p "$codex_home/config.toml" "$backup_config"; config_existed=true; fi
if ((match_count == 1)) && ! $expected_existing; then
  codex_changed=true
  run codex mcp remove "$old_name" || fail "$EXIT_CODEX" 'Could not remove old Scrapling registration'
  empty_scan=$(scan_codex); read -r empty_count _ <<<"$empty_scan"
  ((empty_count == 0)) || fail "$EXIT_CODEX" 'Scrapling registration remained after removal'
fi
if ! $expected_existing; then
  codex_changed=true
  run codex mcp add "$SERVER_NAME" --url "$endpoint" || fail "$EXIT_CODEX" 'Could not add canonical Scrapling registration'
fi
final_scan=$(scan_codex); read -r final_count _ <<<"$final_scan"
if ((final_count != 1)) || ! PYTHONDONTWRITEBYTECODE=1 python3 "$SCAN" verify --endpoint "$endpoint" <"$list_file"; then
  fail "$EXIT_CODEX" 'Final Codex registration is not exactly canonical Scrapling'
fi

rm -rf "$backup_support"; support_installed=false; old_support_saved=false; codex_changed=false
printf '\nScrapling MCP installation verified with immutable image %s.\n' "$scrapling_pinned"
printf 'Endpoint: %s\nRunning clients may keep an older MCP connection; restart them to use the canonical saved configuration. Tor-only egress is enforced at the container network boundary.\n' "$endpoint"
