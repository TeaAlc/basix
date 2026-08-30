#!/usr/bin/env bash
set -euo pipefail

readonly SERVER_NAME=scrapling DEFAULT_IMAGE='docker.io/pyd4vinci/scrapling:latest'
readonly DEFAULT_PORT=8002
readonly TOR_BUILD_TAG='localhost/basix-scrapling-tor:bookworm'
readonly EXIT_USAGE=2 EXIT_PREREQUISITE=3 EXIT_RUNTIME=4 EXIT_PULL=5 EXIT_IMAGE_CHECK=6
readonly EXIT_CONFLICT=7 EXIT_CODEX=8 EXIT_VERIFY=9
readonly TRANSACTION_LABEL_KEY='io.basix.scrapling-tor.setup'
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/scrapling-tor" && pwd); readonly SOURCE_DIR
SCAN=$SOURCE_DIR/codex_scan.py
CONTAINER_POLICY=$SOURCE_DIR/container_policy.py
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

prepare_rootless_netns_mount() {
  # A reused rootless netns may lack the bind target Podman mounts XDG_RUNTIME_DIR onto.
  [[ $runtime == podman ]] || return 0
  local rootless runtime_dir tmp_dir netns_root target resolv_conf
  rootless=$("$runtime" info --format '{{.Host.Security.Rootless}}' 2>/dev/null) || {
    printf 'Could not inspect Podman rootless mode; refusing the capability preflight.\n' >&2
    return "$EXIT_RUNTIME"
  }
  [[ $rootless == true ]] || return 0
  runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [[ $runtime_dir == /* && -d $runtime_dir && -w $runtime_dir ]] || {
    printf 'Podman rootless XDG_RUNTIME_DIR is missing or not writable: %s\n' "$runtime_dir" >&2
    return "$EXIT_RUNTIME"
  }
  if ! tmp_dir=$("$runtime" --log-level=debug info 2>&1 |
    sed -n 's/.*Using tmp dir //p' | sed -e 's/^"//' -e 's/"[[:space:]]*$//' | tail -n 1); then
    printf 'Could not inspect Podman temporary directory; refusing the capability preflight.\n' >&2
    return "$EXIT_RUNTIME"
  fi
  [[ $tmp_dir == /* && -d $tmp_dir && -w $tmp_dir ]] || {
    printf 'Podman rootless temporary directory is missing or not writable: %s\n' "${tmp_dir:-unknown}" >&2
    return "$EXIT_RUNTIME"
  }
  netns_root="$tmp_dir/rootless-netns"
  [[ ! -L $netns_root ]] || {
    printf 'Podman rootless netns root is a symlink: %s\n' "$netns_root" >&2
    return "$EXIT_RUNTIME"
  }
  target="$netns_root$runtime_dir"
  mkdir -p "$netns_root/run/systemd/resolve" "$netns_root/var/lib" "$target" || {
    printf 'Could not prepare the Podman rootless netns mount targets under: %s\n' "$netns_root" >&2
    return "$EXIT_RUNTIME"
  }
  chmod 700 "$target" || {
    printf 'Could not secure the Podman rootless netns mount target: %s\n' "$target" >&2
    return "$EXIT_RUNTIME"
  }
  resolv_conf="$netns_root/resolv.conf"
  if [[ -L $resolv_conf || -d $resolv_conf || ( -e $resolv_conf && ! -f $resolv_conf ) ]]; then
    printf 'Podman rootless netns resolv.conf is not a regular file: %s\n' "$resolv_conf" >&2
    return "$EXIT_RUNTIME"
  fi
  if [[ ! -e $resolv_conf ]]; then
    [[ -f /etc/resolv.conf && -r /etc/resolv.conf ]] || {
      printf 'Host resolv.conf is not readable; refusing the rootless network preflight.\n' >&2
      return "$EXIT_RUNTIME"
    }
    cp --preserve=mode -- /etc/resolv.conf "$resolv_conf" || {
      printf 'Could not prepare the Podman rootless netns resolv.conf: %s\n' "$resolv_conf" >&2
      return "$EXIT_RUNTIME"
    }
  fi
  [[ -f $resolv_conf && ! -L $resolv_conf ]] || {
    printf 'Podman rootless netns resolv.conf could not be secured: %s\n' "$resolv_conf" >&2
    return "$EXIT_RUNTIME"
  }
}

work=$(mktemp -d "${TMPDIR:-/tmp}/basix-scrapling-install.XXXXXX")
list_file=$work/list.json backup_config=$work/config.toml backup_support=$work/old-support
capability_net="basix-scrapling-capability-$$-$RANDOM"
capability_alias_container="basix-scrapling-capability-alias-$$-$RANDOM"
setup_transaction_id="basix-scrapling-setup-$$-$RANDOM"
export BASIX_SETUP_TRANSACTION_ID=$setup_transaction_id
capability_net_created=false capability_alias_created=false
runtime_snapshot_active=false runtime_snapshot_restored=false
snapshot_tor_backup='' snapshot_tor_id='' snapshot_tor_running=false snapshot_tor_internal=false
snapshot_scrapling_backup='' snapshot_scrapling_id='' snapshot_scrapling_running=false snapshot_scrapling_internal=false
snapshot_internal_exists=false snapshot_internal_dns_disabled=false snapshot_egress_exists=false
snapshot_internal_id='' snapshot_egress_id=''
snapshot_internal_file=$work/internal-network.json snapshot_egress_file=$work/egress-network.json
snapshot_legacy_ids=() snapshot_legacy_names=()
new_internal_id='' new_egress_id=''
new_tor_id='' new_scrapling_id=''
support_installed=false old_support_saved=false codex_changed=false config_existed=false

runtime_container_json() { "$runtime" inspect "$1"; }
runtime_container_id() { "$runtime" inspect --format '{{.Id}}' "$1"; }
runtime_network_snapshot() {
  local name=$1 path=$2 output status
  if output=$("$runtime" network inspect "$name" 2>/dev/null); then
    printf '%s\n' "$output" >"$path"
    PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
value=json.load(open(sys.argv[1]))
if not isinstance(value,list) or len(value)!=1 or not isinstance(value[0],dict): raise SystemExit(2)
network=value[0]
if not isinstance(network.get("Id",network.get("ID",network.get("id"))),str): raise SystemExit(2)
' "$path" || return 7
    return 0
  else
    status=$?
  fi
  ((status == 1)) && return 1
  return 7
}
network_snapshot_id() {
  local path=$1
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(open(sys.argv[1]))[0]
value=n.get("Id",n.get("ID",n.get("id")))
print(value if isinstance(value,str) else "")
' "$path"
}
network_snapshot_dns_disabled() {
  local path=$1
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(open(sys.argv[1]))[0]
value=n.get("DNSEnabled",n.get("dns_enabled",True))
raise SystemExit(0 if value is False else 1)
' "$path"
}
current_network_id() {
  local name=$1 path=$work/current-network.json status
  if runtime_network_snapshot "$name" "$path"; then
    network_snapshot_id "$path"
    return 0
  else
    status=$?
  fi
  return "$status"
}
transaction_network_id() {
  local name=$1 path=$work/transaction-network.json status
  runtime_network_snapshot "$name" "$path" || { status=$?; return "$status"; }
  PYTHONDONTWRITEBYTECODE=1 python3 - "$path" "$TRANSACTION_LABEL_KEY" "$setup_transaction_id" <<'PY'
import json,sys
n=json.load(open(sys.argv[1]))[0]
labels=n.get("Labels",n.get("labels",{})) or {}
if labels.get(sys.argv[2]) != sys.argv[3]: raise SystemExit(1)
value=n.get("Id",n.get("ID",n.get("id")))
if not isinstance(value,str) or not value: raise SystemExit(1)
print(value)
PY
}
remove_network_if_identity() {
  local name=$1 expected=$2 current status
  [[ -n $expected ]] || return 7
  current=$(current_network_id "$name" 2>/dev/null) || { status=$?; ((status == 1)) && return 0; return 7; }
  [[ $current == "$expected" ]] || {
    printf 'Refusing to remove network %s after its immutable identity changed.\n' "$name" >&2
    return 7
  }
  "$runtime" network rm "$name" >/dev/null 2>&1
}
recreate_network_from_snapshot() {
  local name=$1 path=$2 internal=$3 args=()
  [[ -r $path ]] || return 7
  mapfile -t args < <(PYTHONDONTWRITEBYTECODE=1 python3 - "$path" "$internal" <<'PY'
import json,sys
n=json.load(open(sys.argv[1]))[0]
internal=sys.argv[2] == "true"
def emit(*values):
    for value in values:
        print(value)
driver=str(n.get("Driver",n.get("driver","bridge")))
if driver and driver != "bridge": emit("--driver",driver)
interface=n.get("NetworkInterface",n.get("network_interface"))
if interface: emit("--interface-name",str(interface))
if internal: emit("--internal")
dns=n.get("DNSEnabled",n.get("dns_enabled",True))
if dns is False: emit("--disable-dns")
labels=n.get("Labels",n.get("labels",{})) or {}
for key,value in sorted(labels.items()): emit("--label",f"{key}={value}")
options=n.get("Options",n.get("options",{})) or {}
for key,value in sorted(options.items()): emit("--opt",f"{key}={value}")
ipam=n.get("IPAMOptions",n.get("ipam_options",{})) or {}
if isinstance(ipam,dict):
    ipam_driver=ipam.get("driver",ipam.get("Driver"))
    if ipam_driver: emit("--ipam-driver",str(ipam_driver))
    for key,value in sorted((ipam.get("options",ipam.get("Options",{})) or {}).items()):
        emit("--ipam-opt",f"{key}={value}")
subnets=n.get("Subnets",n.get("subnets",[])) or []
for item in subnets:
    if not isinstance(item,dict): continue
    subnet=item.get("Subnet",item.get("subnet"))
    gateway=item.get("Gateway",item.get("gateway"))
    if subnet: emit("--subnet",str(subnet))
    if gateway: emit("--gateway",str(gateway))
PY
)
  "$runtime" network create "${args[@]}" "$name" >/dev/null 2>&1
}
runtime_container_has_network() {
  local id=$1 network=$2
  runtime_container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
obj=json.load(sys.stdin)[0]
nets=(obj.get("NetworkSettings") or {}).get("Networks") or {}
raise SystemExit(0 if sys.argv[1] in nets else 1)
' "$network"
}
runtime_container_autoremove() {
  local id=$1
  runtime_container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
h=n.get("HostConfig") or {}
annotations=(n.get("Config") or {}).get("Annotations") or {}
value=h.get("AutoRemove")
if value is None: value=str(annotations.get("io.podman.annotations.autoremove","")).upper()=="TRUE"
raise SystemExit(0 if value is True else 1)
'
}
classify_runtime_container() {
  local name=$1 kind=$2 configured=$3 actual=$4 status=0
  local args=(managed "$kind" --configured "$configured" --actual "$actual" --port "$port" --policy "$install_dir/policy_mcp.py")
  [[ $kind == scrapling ]] && args+=(--tor-host basix-tor-proxy)
  runtime_container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" "${args[@]}" || status=$?
  return "$status"
}
snapshot_legacy_containers() {
  local id name result classification connected
  snapshot_legacy_ids=(); snapshot_legacy_names=()
  [[ -r $snapshot_internal_file ]] || return 7
  connected=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$snapshot_internal_file" <<'PY'
import json,sys
n=json.load(open(sys.argv[1]))[0]
for ident,value in (n.get("Containers",n.get("containers",{})) or {}).items():
    if not isinstance(value,dict): raise SystemExit(2)
    name=value.get("Name",value.get("name",""))
    if not isinstance(name,str) or not name: raise SystemExit(2)
    print(ident, name)
PY
) || return 7
  while read -r id name; do
    [[ -z $id && -z $name ]] && continue
    [[ -n $id && -n $name ]] || {
      printf 'Malformed internal-network container entry; refusing migration.\n' >&2
      return 7
    }
    [[ $name == basix-scrapling-tor || $name == basix-scrapling-mcp ]] && continue
    classification=0
    result=$(runtime_container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$install_dir/policy_mcp.py") || classification=$?
    if [[ $classification == 0 && $result == managed-legacy ]]; then
      snapshot_legacy_ids+=("$id"); snapshot_legacy_names+=("$name")
    else
      printf 'Refusing DNS migration while foreign or unsafe container %s uses basix-scrapling-internal.\n' "$name" >&2
      return 7
    fi
  done <<<"$connected"
}
validate_snapshot_container() {
  local name=$1 kind=$2 configured=$3 actual=$4 classification=0 result
  runtime_container_json "$name" >/dev/null 2>&1 || return 0
  classify_runtime_container "$name" "$kind" "$configured" "$actual" || classification=$?
  if [[ $kind == scrapling && $classification == 1 ]]; then
    classification=0
    result=$(runtime_container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$(runtime_container_id "$name")" --policy "$install_dir/policy_mcp.py") || classification=$?
    [[ $classification == 0 && $result == managed-legacy ]] && return 0
    classification=1
  fi
  case $classification in
    0|10) return 0 ;;
    *)
      [[ $kind == tor ]] && kind=Tor || kind=Scrapling
      printf 'Refusing foreign or unsafe %s container named %s before replacement.\n' "$kind" "$name" >&2
      return 7
      ;;
  esac
}
snapshot_one_runtime_container() {
  local name=$1 kind=$2 configured=$3 actual=$4 backup id state has_network autoremove=false
  runtime_container_json "$name" >/dev/null 2>&1 || return 0
  id=$(runtime_container_id "$name" 2>/dev/null) || return 7
  [[ -n $id ]] || return 7
  state=$("$runtime" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
  case $state in
    running|created|configured|exited|stopped|paused|dead) ;;
    *) printf 'Could not determine the state of managed %s container %s; refusing replacement.\n' "$kind" "$name" >&2; return 7 ;;
  esac
  has_network=false
  if runtime_container_has_network "$id" basix-scrapling-internal >/dev/null 2>&1; then
    has_network=true
  elif (($? != 1)); then
    printf 'Could not determine the networks of managed %s container %s; refusing replacement.\n' "$kind" "$name" >&2
    return 7
  fi
  if runtime_container_autoremove "$id" >/dev/null 2>&1; then autoremove=true; fi
  backup="${name}.basix-rollback-$$-$RANDOM"
  if [[ $kind == tor ]]; then
    snapshot_tor_backup=$backup
    snapshot_tor_id=$id
    snapshot_tor_running=$([[ $state == running ]] && printf true || printf false)
    snapshot_tor_internal=$has_network
  else
    snapshot_scrapling_backup=$backup
    snapshot_scrapling_id=$id
    snapshot_scrapling_running=$([[ $state == running ]] && printf true || printf false)
    snapshot_scrapling_internal=$has_network
  fi
  runtime_snapshot_active=true
  if $has_network; then
    if ! "$runtime" network disconnect --force basix-scrapling-internal "$id" >/dev/null 2>&1; then
      printf 'Could not detach managed %s container %s for transactional replacement.\n' "$kind" "$name" >&2
      if [[ $kind == tor ]]; then
        "$runtime" network connect --alias basix-tor-proxy basix-scrapling-internal "$id" >/dev/null 2>&1 || true
      else
        "$runtime" network connect basix-scrapling-internal "$id" >/dev/null 2>&1 || true
      fi
      if [[ $kind == tor ]]; then snapshot_tor_backup=''; else snapshot_scrapling_backup=''; fi
      return 7
    fi
  fi
  if [[ $state == running && $autoremove == false ]] && ! "$runtime" stop "$id" >/dev/null; then
    if $has_network; then
      if [[ $kind == tor ]]; then "$runtime" network connect --alias basix-tor-proxy basix-scrapling-internal "$id" >/dev/null 2>&1 || true
      else "$runtime" network connect basix-scrapling-internal "$id" >/dev/null 2>&1 || true; fi
    fi
    if [[ $kind == tor ]]; then snapshot_tor_backup=''; else snapshot_scrapling_backup=''; fi
    return 7
  fi
  "$runtime" rename "$id" "$backup" >/dev/null || {
    printf 'Could not preserve managed %s container %s before replacement.\n' "$kind" "$name" >&2
    if $has_network; then
      if [[ $kind == tor ]]; then "$runtime" network connect --alias basix-tor-proxy basix-scrapling-internal "$id" >/dev/null 2>&1 || true
      else "$runtime" network connect basix-scrapling-internal "$id" >/dev/null 2>&1 || true; fi
    fi
    [[ $state != running ]] || "$runtime" start "$id" >/dev/null 2>&1 || true
    if [[ $kind == tor ]]; then snapshot_tor_backup=''; else snapshot_scrapling_backup=''; fi
    return 7
  }
  if [[ $kind != tor ]]; then
    printf 'Replacing the existing managed Scrapling service with the latest installer setup.\n' >&2
  fi
}
runtime_running_safety() {
  local listing id name extra result classification
  listing=$("$runtime" ps --no-trunc --format '{{.ID}} {{.Names}}') || {
    printf 'Could not enumerate running containers; refusing Scrapling migration.\n' >&2
    return 7
  }
  while read -r id name extra; do
    [[ -z $id && -z $name && -z $extra ]] && continue
    [[ -n $id && -n $name && -z $extra ]] || {
      printf 'Runtime returned malformed container listing; refusing Scrapling migration.\n' >&2
      return 7
    }
    [[ $name != basix-scrapling-tor && $name != basix-scrapling-mcp ]] || continue
    classification=0
    result=$(runtime_container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$install_dir/policy_mcp.py") || classification=$?
    case $classification:$result in
      0:unrelated|0:managed-legacy) ;;
      *) printf 'Refusing foreign or unsafe running Scrapling container named %s before Tor reconciliation.\n' "$name" >&2; return 7 ;;
    esac
  done <<<"$listing"
}
snapshot_runtime() {
  local status
  snapshot_internal_exists=false snapshot_internal_dns_disabled=false snapshot_egress_exists=false
  snapshot_internal_id='' snapshot_egress_id=''
  snapshot_legacy_ids=(); snapshot_legacy_names=()
  if runtime_network_snapshot basix-scrapling-internal "$snapshot_internal_file"; then
    snapshot_internal_exists=true
    snapshot_internal_id=$(network_snapshot_id "$snapshot_internal_file")
    [[ -n $snapshot_internal_id ]] || return 7
    if network_snapshot_dns_disabled "$snapshot_internal_file"; then snapshot_internal_dns_disabled=true; fi
  else
    status=$?
    ((status == 1)) || { printf 'Could not inspect basix-scrapling-internal safely; refusing replacement.\n' >&2; return 7; }
  fi
  if runtime_network_snapshot basix-tor-egress "$snapshot_egress_file"; then
    snapshot_egress_exists=true
    snapshot_egress_id=$(network_snapshot_id "$snapshot_egress_file")
    [[ -n $snapshot_egress_id ]] || return 7
  else
    status=$?
    ((status == 1)) || { printf 'Could not inspect basix-tor-egress safely; refusing replacement.\n' >&2; return 7; }
  fi
  if $snapshot_internal_dns_disabled; then
    snapshot_legacy_containers || return $?
  fi
  validate_snapshot_container basix-scrapling-tor tor "$tor_pinned" "$tor_pinned" || return $?
  validate_snapshot_container basix-scrapling-mcp scrapling "$scrapling_id" "$scrapling_id" || return $?
  runtime_snapshot_active=true
  snapshot_one_runtime_container basix-scrapling-tor tor "$tor_pinned" "$tor_pinned" || return $?
  snapshot_one_runtime_container basix-scrapling-mcp scrapling "$scrapling_id" "$scrapling_id" || return $?
}
restore_network_snapshot() {
  local name=$1 path=$2 existed=$3 original_id=$4 new_id=$5 internal=$6 current status
  if current=$(current_network_id "$name" 2>/dev/null); then
    if [[ $existed == true && $current == "$original_id" ]]; then
      return 0
    fi
    if [[ -n $new_id && $current == "$new_id" ]]; then
      remove_network_if_identity "$name" "$new_id" || return 7
    else
      printf 'Refusing rollback of network %s after its immutable identity changed.\n' "$name" >&2
      return 7
    fi
  else
    status=$?
    ((status == 1)) || {
      printf 'Could not inspect network %s during rollback; leaving it untouched.\n' "$name" >&2
      return 7
    }
    $existed || return 0
  fi
  $existed || return 0
  recreate_network_from_snapshot "$name" "$path" "$internal" || return 7
}
connect_if_missing() {
  local id=$1 network=$2 alias=${3-} status
  if runtime_container_has_network "$id" "$network" >/dev/null 2>&1; then return 0; fi
  status=$?
  ((status == 1)) || return 7
  if [[ -n $alias ]]; then
    "$runtime" network connect --alias "$alias" "$network" "$id" >/dev/null 2>&1
  else
    "$runtime" network connect "$network" "$id" >/dev/null 2>&1
  fi
}
rollback_runtime_snapshot() {
  local status=0 current pair name expected backup
  [[ $runtime_snapshot_active == true ]] || return 0
  # Validate preserved identities before removing or renaming anything.
  for pair in "basix-scrapling-tor:$snapshot_tor_backup:$snapshot_tor_id" "basix-scrapling-mcp:$snapshot_scrapling_backup:$snapshot_scrapling_id"; do
    name=${pair%%:*}; backup=${pair#*:}; backup=${backup%%:*}; expected=${pair##*:}
    [[ -n $backup ]] || continue
    current=$(runtime_container_id "$backup" 2>/dev/null || true)
    [[ $current == "$expected" ]] || {
      printf 'Rollback container %s changed before restoration; leaving it untouched.\n' "$backup" >&2
      return 7
    }
  done
  # Remove only containers created by this invocation. If a name changed after
  # prepare, leave it untouched and report a concurrent runtime conflict.
  for pair in "basix-scrapling-mcp:$new_scrapling_id" "basix-scrapling-tor:$new_tor_id"; do
    name=${pair%%:*}; expected=${pair#*:}
    [[ -n $expected ]] || continue
    if current=$(runtime_container_id "$name" 2>/dev/null); then
      if [[ $current == "$expected" ]]; then
        "$runtime" rm -f "$expected" >/dev/null 2>&1 || status=7
      else
        printf 'Refusing rollback of %s after its identity changed.\n' "$name" >&2
        status=7
      fi
    fi
  done
  restore_network_snapshot basix-scrapling-internal "$snapshot_internal_file" \
    "$snapshot_internal_exists" "$snapshot_internal_id" "$new_internal_id" true || status=7
  restore_network_snapshot basix-tor-egress "$snapshot_egress_file" \
    "$snapshot_egress_exists" "$snapshot_egress_id" "$new_egress_id" false || status=7
  if [[ -n $snapshot_tor_backup ]]; then
    if runtime_container_json basix-scrapling-tor >/dev/null 2>&1; then
      status=7
    elif ! "$runtime" rename "$snapshot_tor_backup" basix-scrapling-tor >/dev/null 2>&1; then
      status=7
    else
      if $snapshot_tor_internal; then
        connect_if_missing basix-scrapling-tor basix-scrapling-internal basix-tor-proxy || status=7
      fi
    fi
  fi
  if [[ -n $snapshot_scrapling_backup ]]; then
    if runtime_container_json basix-scrapling-mcp >/dev/null 2>&1; then
      status=7
    elif ! "$runtime" rename "$snapshot_scrapling_backup" basix-scrapling-mcp >/dev/null 2>&1; then
      status=7
    else
      if $snapshot_scrapling_internal; then
        connect_if_missing basix-scrapling-mcp basix-scrapling-internal || status=7
      fi
    fi
  fi
  local index id
  for index in "${!snapshot_legacy_ids[@]}"; do
    id=${snapshot_legacy_ids[$index]}
    connect_if_missing "$id" basix-scrapling-internal || status=7
  done
  ((status == 0)) && runtime_snapshot_restored=true
  ((status == 0))
}
start_restored_runtime() {
  local status=0 state
  if $snapshot_tor_running && [[ -n $snapshot_tor_backup ]]; then
    state=$("$runtime" inspect --format '{{.State.Status}}' basix-scrapling-tor 2>/dev/null || true)
    [[ $state == running ]] || "$runtime" start basix-scrapling-tor >/dev/null 2>&1 || status=7
  fi
  if $snapshot_scrapling_running && [[ -n $snapshot_scrapling_backup ]]; then
    state=$("$runtime" inspect --format '{{.State.Status}}' basix-scrapling-mcp 2>/dev/null || true)
    [[ $state == running ]] || "$runtime" start basix-scrapling-mcp >/dev/null 2>&1 || status=7
  fi
  return "$status"
}
commit_runtime_snapshot() {
  local current status=0 backup expected
  [[ $runtime_snapshot_active == true ]] || return 0
  current=$(current_network_id basix-scrapling-internal 2>/dev/null) || return 7
  [[ $current == "$new_internal_id" ]] || return 7
  current=$(current_network_id basix-tor-egress 2>/dev/null) || return 7
  [[ $current == "$new_egress_id" ]] || return 7
  for backup in "$snapshot_tor_backup" "$snapshot_scrapling_backup"; do
    [[ -n $backup ]] || continue
    if [[ $backup == "$snapshot_tor_backup" ]]; then expected=$snapshot_tor_id; else expected=$snapshot_scrapling_id; fi
    current=$(runtime_container_id "$backup" 2>/dev/null || true)
    [[ $current == "$expected" ]] || {
      printf 'Rollback container %s changed before commit; refusing cleanup.\n' "$backup" >&2
      return 7
    }
  done
  for backup in "$snapshot_tor_backup" "$snapshot_scrapling_backup"; do
    [[ -n $backup ]] || continue
    current=$(runtime_container_id "$backup" 2>/dev/null || true)
    [[ -n $current ]] || return 7
    "$runtime" rm -f "$current" >/dev/null 2>&1 || status=7
  done
  ((status == 0)) || return "$status"
  runtime_snapshot_active=false
}
cleanup() {
  local status=$? rollback_failed=false; trap - EXIT
  if $capability_alias_created; then "$runtime" rm -f "$capability_alias_container" >/dev/null 2>&1 || status=$EXIT_RUNTIME; fi
  if $capability_net_created; then "$runtime" network rm "$capability_net" >/dev/null 2>&1 || status=$EXIT_RUNTIME; fi
  if ((status != 0)); then
    if $runtime_snapshot_active; then
      [[ -n $new_internal_id ]] || new_internal_id=$(transaction_network_id basix-scrapling-internal 2>/dev/null || true)
      [[ -n $new_egress_id ]] || new_egress_id=$(transaction_network_id basix-tor-egress 2>/dev/null || true)
    fi
    if $runtime_snapshot_active && ! rollback_runtime_snapshot; then status=$EXIT_VERIFY; rollback_failed=true; fi
    if $codex_changed; then
      if $config_existed; then mkdir -p "$codex_home"; cp -p "$backup_config" "$codex_home/config.toml" || status=$EXIT_CODEX
      else rm -f "$codex_home/config.toml" || status=$EXIT_CODEX; fi
    fi
    if ! $rollback_failed; then
      if $support_installed; then rm -rf "$install_dir"; fi
      if $old_support_saved && [[ -e $backup_support ]]; then mv "$backup_support" "$install_dir" || status=$EXIT_CODEX; fi
    else
      printf 'Runtime rollback was incomplete; keeping the newly installed support tree with the new runtime.\n' >&2
    fi
    if $runtime_snapshot_restored && ! start_restored_runtime; then status=$EXIT_VERIFY; fi
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# Prove the relaxed internal-DNS contract before changing any managed resource.
# Peer aliases must resolve, while an internal network must still block direct
# TCP egress. External DNS answers are intentionally not treated as a failure.
capability_proof() {
  local probe_status=0 cleanup_status=0
  if "$runtime" network create --driver bridge --internal --label 'io.basix.scrapling-tor.managed=true' "$capability_net" >/dev/null; then
    capability_net_created=true
  else
    probe_status=$?
  fi
  if ((probe_status == 0)); then
    capability_alias_created=true
    "$runtime" run -d --name "$capability_alias_container" --network "$capability_net" \
      --network-alias basix-tor-proxy --cap-drop ALL --security-opt no-new-privileges \
      --entrypoint /app/.venv/bin/python "$scrapling_pinned" -c 'import time; time.sleep(30)' >/dev/null || probe_status=$?
  fi
  if ((probe_status == 0)); then
    "$runtime" run --rm --network "$capability_net" --cap-drop ALL --security-opt no-new-privileges \
      --entrypoint /app/.venv/bin/python "$scrapling_pinned" -c '
import socket
socket.getaddrinfo("basix-tor-proxy", 9050)
s = socket.socket(); s.settimeout(2)
if s.connect_ex(("1.1.1.1", 443)) == 0:
    raise SystemExit("external TCP unexpectedly connected")
' >/dev/null || probe_status=$?
  fi
  if $capability_alias_created; then
    "$runtime" rm -f "$capability_alias_container" >/dev/null 2>&1 || cleanup_status=$?
    capability_alias_created=false
  fi
  if $capability_net_created; then
    "$runtime" network rm "$capability_net" >/dev/null 2>&1 || cleanup_status=$?
    capability_net_created=false
  fi
  if ((probe_status != 0 || cleanup_status != 0)); then
    printf 'Internal alias and direct-egress capability proof failed (probe exit: %s; cleanup exit: %s); no managed resource was mutated.\n' \
      "$probe_status" "$cleanup_status" >&2
    return "$EXIT_RUNTIME"
  fi
}

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
if ! $dry_run; then
  prepare_rootless_netns_mount || fail "$EXIT_RUNTIME" 'Podman rootless network runtime is unavailable; no managed resource was mutated'
fi
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
s=S(); expected={"bulk_fetch","bulk_get","bulk_stealthy_fetch","close_session","fetch","list_sessions","make_request","open_request_session","open_session","screenshot","session_fetch","session_make_request","stealthy_fetch"}
actual={t.name for t in asyncio.run(s._build_server("127.0.0.1",8000).list_tools())}
assert actual==expected
required={"open_session":{"session_id","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"open_request_session":{"session_id","proxy"},"make_request":{"url","proxy","proxy_auth","auth","http3"},"bulk_get":{"urls","proxy","proxy_auth","auth","http3"},"session_make_request":{"url","session_id","auth","http3"},"fetch":{"url","proxy","cdp_url","real_chrome","executable_path"},"bulk_fetch":{"urls","proxy","cdp_url","real_chrome","executable_path"},"session_fetch":{"url","session_id"},"stealthy_fetch":{"url","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"bulk_stealthy_fetch":{"urls","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"screenshot":{"url","session_id"},"close_session":{"session_id"}}
assert all(v <= set(inspect.signature(getattr(s,k)).parameters) for k,v in required.items())
assert {"allowed_hosts","allow_unauthenticated"} <= set(inspect.signature(s.serve).parameters)
' || fail "$EXIT_IMAGE_CHECK" 'Scrapling MCP tools or schemas are incompatible with the Basix policy'
capability_proof || fail "$EXIT_RUNTIME" 'Podman/Docker cannot provide the managed internal alias and direct-egress boundary'
run "$runtime" build --label 'io.basix.scrapling-tor.managed=true' -t "$TOR_BUILD_TAG" "$SOURCE_DIR" || fail "$EXIT_PULL" 'Could not build Tor sidecar'
tor_inspected=$("$runtime" image inspect --format '{{.Id}}' "$TOR_BUILD_TAG") || fail "$EXIT_IMAGE_CHECK" 'Could not pin Tor image'
tor_pinned=$(normalize_image_reference "$tor_inspected") || fail "$EXIT_IMAGE_CHECK" 'Runtime did not return an immutable Tor image ID'

mkdir -p "$work/support"
cp "$SOURCE_DIR/launcher.sh" "$SOURCE_DIR/policy_mcp.py" "$SOURCE_DIR/codex_scan.py" \
  "$SOURCE_DIR/container_policy.py" "$SOURCE_DIR/health_check.py" "$work/support/"
printf 'RUNTIME=%q\nSCRAPLING_IMAGE=%q\nSCRAPLING_ID=%q\nTOR_IMAGE=%q\nPORT=%q\n' "$runtime" "$scrapling_pinned" "$scrapling_id" "$tor_pinned" "$port" >"$work/support/config"
chmod 755 "$work/support/launcher.sh" "$work/support/codex_scan.py" \
  "$work/support/container_policy.py" "$work/support/health_check.py"
mkdir -p "$(dirname "$install_dir")"
if [[ -e $install_dir ]]; then mv "$install_dir" "$backup_support"; old_support_saved=true; fi
if ! mv "$work/support" "$install_dir"; then
  if $old_support_saved && mv "$backup_support" "$install_dir"; then old_support_saved=false; fi
  fail "$EXIT_VERIFY" 'Could not install Scrapling support files'
fi
support_installed=true
runtime_running_safety || fail "$EXIT_CONFLICT" 'Foreign or unsafe running Scrapling resource blocks replacement'
snapshot_runtime || fail "$EXIT_CONFLICT" 'Managed runtime resources could not be safely preserved for replacement'
BASIX_SETUP_REPLACE_SCRAPLING=true run "$launcher" prepare || {
  launcher_status=$?
  ((launcher_status == EXIT_CONFLICT)) && fail "$EXIT_CONFLICT" 'Managed runtime resource conflict; Codex was restored'
  ((launcher_status == EXIT_RUNTIME)) && fail "$EXIT_RUNTIME" 'Host runtime/network namespace unavailable; Codex was restored'
  fail "$EXIT_VERIFY" 'Status 9: Managed Tor failed validation or bootstrap, or the MCP HTTP/Tor verification failed. Check the container logs and Tor gateway diagnostics above; status 4 is reserved for an unavailable rootless runtime/network namespace. Codex was restored'
}
new_tor_id=$(runtime_container_id basix-scrapling-tor 2>/dev/null || true)
new_scrapling_id=$(runtime_container_id basix-scrapling-mcp 2>/dev/null || true)
new_internal_id=$(current_network_id basix-scrapling-internal 2>/dev/null || true)
new_egress_id=$(current_network_id basix-tor-egress 2>/dev/null || true)
[[ -n $new_internal_id && -n $new_egress_id ]] || fail "$EXIT_VERIFY" 'Managed network identities could not be pinned after preparation'

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

commit_runtime_snapshot || fail "$EXIT_VERIFY" 'Managed runtime replacement could not be committed safely'
run "$launcher" migrate-legacy || fail "$EXIT_VERIFY" 'Validated legacy Scrapling migration failed after runtime commit'

rm -rf "$backup_support"; support_installed=false; old_support_saved=false; codex_changed=false
printf '\nScrapling MCP installation verified with immutable image %s.\n' "$scrapling_pinned"
printf 'Endpoint: %s\nRunning clients may keep an older MCP connection; restart them to use the canonical saved configuration. Tor-only egress is enforced at the container network boundary.\n' "$endpoint"
