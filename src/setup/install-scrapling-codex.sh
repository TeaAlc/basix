#!/usr/bin/env bash
set -u

readonly SERVER_NAME="scrapling"
readonly DEFAULT_IMAGE="docker.io/pyd4vinci/scrapling:latest"
readonly EXIT_USAGE=2 EXIT_PREREQUISITE=3 EXIT_RUNTIME=4 EXIT_PULL=5
readonly EXIT_IMAGE_CHECK=6 EXIT_CONFLICT=7 EXIT_CODEX=8 EXIT_VERIFY=9

image="$DEFAULT_IMAGE"
runtime_choice=auto
runtime=''
force=false
dry_run=false

usage() {
  cat <<'EOF'
Usage: ./install-scrapling-codex.sh [--runtime auto|podman|docker] [--image IMAGE] [--force] [--dry-run] [--help]

Installs Scrapling through Podman or Docker and registers it as the local Codex
stdio MCP server named "scrapling". Podman is preferred in automatic mode. The
container runtime itself is not installed by this script.

Options:
  --runtime NAME  Runtime: auto, podman, or docker (default: auto; prefers Podman)
  --image IMAGE  OCI image to use (default: docker.io/pyd4vinci/scrapling:latest)
  --force        Replace a different existing "scrapling" configuration
  --dry-run      Print planned actions without pulling or changing configuration
  --help         Show this help
EOF
}

fail() {
  local code="$1"
  shift
  printf 'Error: %s\n' "$*" >&2
  exit "$code"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

validate_image() {
  local ref="$1" component
  [[ -n "$ref" && ${#ref} -le 255 ]] || return 1
  [[ "$ref" != *[[:space:]]* && "$ref" != -* ]] || return 1
  [[ "$ref" =~ ^([a-zA-Z0-9.-]+(:[0-9]+)?/)?[a-z0-9._/-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-fA-F0-9]{64})?$ ]] || return 1
  [[ "$ref" != */ && "$ref" != *//* ]] || return 1
  IFS='/' read -r -a components <<< "${ref%%@*}"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != '.' && "$component" != '..' ]] || return 1
  done
}

is_expected_config() {
  local json="$1" compact expected_args
  compact=${json//$'\n'/}
  compact=${compact//$'\r'/}
  compact=${compact//$'\t'/}
  compact=${compact// /}
  expected_args="\"args\":[\"run\",\"-i\",\"--rm\",\"$image\",\"mcp\"]"
  [[ "$compact" == *'"name":"scrapling"'* &&
     "$compact" == *'"type":"stdio"'* &&
     "$compact" == *"\"command\":\"$runtime\""* &&
     "$compact" == *"$expected_args"* &&
     "$compact" == *'"env":null'* &&
     "$compact" == *'"cwd":null'* ]]
}

while (($#)); do
  case "$1" in
    --runtime)
      (($# >= 2)) || fail "$EXIT_USAGE" '--runtime requires a value.'
      runtime_choice="$2"
      shift 2
      ;;
    --image)
      (($# >= 2)) || fail "$EXIT_USAGE" '--image requires a value.'
      image="$2"
      shift 2
      ;;
    --force) force=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "$EXIT_USAGE" "Unknown option: $1. Run with --help for usage." ;;
  esac
done

case "$runtime_choice" in
  auto)
    if command -v podman >/dev/null 2>&1; then
      runtime=podman
    elif command -v docker >/dev/null 2>&1; then
      runtime=docker
    else
      fail "$EXIT_PREREQUISITE" 'Neither Podman nor Docker CLI was found. Install Podman (preferred) or Docker Engine for Linux, then retry.'
    fi
    ;;
  podman|docker)
    runtime="$runtime_choice"
    command -v "$runtime" >/dev/null 2>&1 || fail "$EXIT_PREREQUISITE" "Requested container runtime '$runtime' was not found. Install it or use --runtime auto."
    ;;
  *) fail "$EXIT_USAGE" "Invalid runtime: $runtime_choice. Expected auto, podman, or docker." ;;
esac

validate_image "$image" || fail "$EXIT_USAGE" "Invalid OCI image reference: $image"
command -v bash >/dev/null 2>&1 || fail "$EXIT_PREREQUISITE" 'Bash is required.'
command -v codex >/dev/null 2>&1 || fail "$EXIT_PREREQUISITE" 'Codex CLI not found. Install or update Codex CLI, then retry.'

codex_mcp_help=$(codex mcp --help 2>&1) || fail "$EXIT_CODEX" 'Codex CLI does not provide a usable MCP command. Update Codex CLI.'
[[ "$codex_mcp_help" == *add* && "$codex_mcp_help" == *get* ]] || fail "$EXIT_CODEX" 'Codex CLI lacks required MCP add/get commands. Update Codex CLI.'
codex_get_help=$(codex mcp get --help 2>&1) || fail "$EXIT_CODEX" 'Codex MCP get command is unavailable.'
[[ "$codex_get_help" == *--json* ]] || fail "$EXIT_CODEX" 'Codex MCP get lacks --json support. Update Codex CLI.'

existing_config=''
get_error_file=$(mktemp)
trap 'rm -f "$get_error_file"' EXIT
if existing_config=$(codex mcp get "$SERVER_NAME" --json 2>"$get_error_file"); then
  if is_expected_config "$existing_config"; then
    printf 'Codex MCP server "%s" is already configured correctly.\n' "$SERVER_NAME"
    "$dry_run" && printf 'Dry run: no image was pulled and no configuration was changed.\n'
    exit 0
  elif ! "$force"; then
    fail "$EXIT_CONFLICT" 'Codex MCP server "scrapling" already exists with a different configuration. Inspect it with `codex mcp get scrapling --json`, or rerun with --force.'
  else
    printf 'Codex MCP server "%s" will be replaced because --force was specified.\n' "$SERVER_NAME"
  fi
elif ! grep -qiE 'no MCP server|not found|does not exist' "$get_error_file"; then
  fail "$EXIT_CODEX" "Codex could not inspect the existing MCP configuration: $(tr '\n' ' ' < "$get_error_file")"
fi

if "$dry_run"; then
  printf 'Dry run; planned commands:\n'
  printf 'Selected container runtime: %s\n' "$runtime"
  printf '+ %s info\n' "$runtime"
  printf '+ %s pull %q\n' "$runtime" "$image"
  printf '+ %s run --rm %q mcp --help\n' "$runtime" "$image"
  printf '+ codex mcp add %q -- %s run -i --rm %q mcp\n' "$SERVER_NAME" "$runtime" "$image"
  printf '+ %s image inspect %q\n' "$runtime" "$image"
  printf '+ codex mcp get %q --json\n' "$SERVER_NAME"
  printf 'No image was pulled and no configuration was changed.\n'
  exit 0
fi

"$runtime" info >/dev/null 2>&1 || fail "$EXIT_RUNTIME" "Cannot use $runtime. Ensure the runtime is configured and your user can run '$runtime info'."
run "$runtime" pull "$image" || fail "$EXIT_PULL" "Could not pull OCI image $image with $runtime. Check the image name, registry access, and network connection."
run "$runtime" run --rm "$image" mcp --help || fail "$EXIT_IMAGE_CHECK" 'The image did not start the expected `mcp` entry point.'

run codex mcp add "$SERVER_NAME" -- "$runtime" run -i --rm "$image" mcp || fail "$EXIT_CODEX" 'Codex could not register the Scrapling MCP server.'

"$runtime" image inspect "$image" >/dev/null 2>&1 || fail "$EXIT_VERIFY" "Final validation failed: OCI image $image is not available locally through $runtime."
final_config=$(codex mcp get "$SERVER_NAME" --json 2>/dev/null) || fail "$EXIT_VERIFY" 'Final validation failed: Codex cannot read the Scrapling MCP configuration.'
is_expected_config "$final_config" || fail "$EXIT_VERIFY" "Final validation failed: Codex MCP configuration does not match the safe $runtime stdio command."

printf '\nScrapling MCP installation verified. No ports, volumes, secrets, privileged mode, or host networking are configured.\n'
if [[ -r SCRAPLING_INFO.md ]]; then
  printf '\nTest prompt (from SCRAPLING_INFO.md):\n'
  sed -n '/^```text$/,/^```$/p' SCRAPLING_INFO.md | sed '1d;$d'
else
  printf 'Test prompt: Use Scrapling to fetch https://example.com and return the page title.\n'
fi
