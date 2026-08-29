#!/usr/bin/env bash
set -Eeuo pipefail

readonly LABEL_KEY='io.basix.scrapling-tor.managed' LABEL_VALUE='true'
readonly TRANSACTION_LABEL_KEY='io.basix.scrapling-tor.setup'
readonly INTERNAL_NET='basix-scrapling-internal' EGRESS_NET='basix-tor-egress'
readonly TOR_CONTAINER='basix-scrapling-tor' SCRAPLING_CONTAINER='basix-scrapling-mcp'
readonly BASIX_TOR_HOST='basix-tor-proxy'
readonly PROBE_CONTAINER="basix-scrapling-egress-probe-$$-$RANDOM"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); readonly HERE
readonly CONTAINER_POLICY="$HERE/container_policy.py"
[[ -r $HERE/config ]] || { printf 'Basix Scrapling configuration is missing; rerun the installer.\n' >&2; exit 3; }
# shellcheck source=/dev/null
source "$HERE/config"
: "${RUNTIME:?}" "${SCRAPLING_IMAGE:?}" "${SCRAPLING_ID:?}" "${TOR_IMAGE:?}" "${PORT:?}"
TRANSACTION_ID=${BASIX_SETUP_TRANSACTION_ID:-}
readonly ENDPOINT="http://127.0.0.1:$PORT/mcp"

created_internal=false created_egress=false created_tor=false created_scrapling=false probe_created=false
created_internal_id='' created_egress_id='' created_tor_ref='' created_scrapling_ref=''
migration_old_removed=false migration_original_internal_id='' migration_new_internal_id='' migration_disconnected_ids=() migration_disconnected_names=()
legacy_ids=() legacy_names=()
rollback() {
  local status=$?; trap - ERR
  if $probe_created; then "$RUNTIME" rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true; fi
  if $created_scrapling && [[ -n $created_scrapling_ref ]]; then "$RUNTIME" rm -f "$created_scrapling_ref" >/dev/null 2>&1 || true; fi
  if $created_tor && [[ -n $created_tor_ref ]]; then "$RUNTIME" rm -f "$created_tor_ref" >/dev/null 2>&1 || true; fi
  if $created_internal && network_still_matches "$INTERNAL_NET" "$created_internal_id"; then "$RUNTIME" network rm "$INTERNAL_NET" >/dev/null 2>&1 || true; fi
  if $created_egress && network_still_matches "$EGRESS_NET" "$created_egress_id"; then "$RUNTIME" network rm "$EGRESS_NET" >/dev/null 2>&1 || true; fi
  if $migration_old_removed; then
    local network_ready=false
    if [[ -n $migration_new_internal_id ]] && network_still_matches "$INTERNAL_NET" "$migration_new_internal_id"; then
      "$RUNTIME" network rm "$INTERNAL_NET" >/dev/null 2>&1 || true
    fi
    local inspect_status=0
    if network_json "$INTERNAL_NET" >/dev/null 2>&1; then
      network_ready=false
    else
      inspect_status=$?
    fi
    if ((inspect_status == 1)); then
      if "$RUNTIME" network create --driver bridge --internal --disable-dns --label "$LABEL_KEY=$LABEL_VALUE" "$INTERNAL_NET" >/dev/null 2>&1; then
        network_ready=true
      fi
    fi
    local index id
    if $network_ready; then
      for index in "${!migration_disconnected_ids[@]}"; do
        id=${migration_disconnected_ids[$index]}
        "$RUNTIME" network connect "$INTERNAL_NET" "$id" >/dev/null 2>&1 || true
      done
    fi
  elif [[ -n $migration_original_internal_id ]] && network_still_matches "$INTERNAL_NET" "$migration_original_internal_id"; then
    local index id
    for index in "${!migration_disconnected_ids[@]}"; do
      id=${migration_disconnected_ids[$index]}
      "$RUNTIME" network connect "$INTERNAL_NET" "$id" >/dev/null 2>&1 || true
    done
  fi
  return "$status"
}
trap rollback ERR

network_json() { "$RUNTIME" network inspect "$1"; }
container_json() { "$RUNTIME" inspect "$1"; }
container_id() { "$RUNTIME" inspect --format '{{.Id}}' "$1"; }
network_id() {
  "$RUNTIME" network inspect "$1" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
value=n.get("Id",n.get("ID",n.get("id")))
if not isinstance(value,str) or not value: raise SystemExit(1)
print(value)
'
}
network_still_matches() {
  local name=$1 expected=$2 actual
  [[ -n $expected ]] || return 1
  actual=$(network_id "$name" 2>/dev/null) || return 1
  [[ $actual == "$expected" ]]
}
container_has_network() {
  local id=$1 network=$2
  container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
networks=(n.get("NetworkSettings") or {}).get("Networks") or {}
raise SystemExit(0 if sys.argv[1] in networks else 1)
' "$network"
}
disconnect_if_connected() {
  local network=$1 id=$2 status
  if container_has_network "$id" "$network" >/dev/null 2>&1; then
    "$RUNTIME" network disconnect --force "$network" "$id" >/dev/null 2>&1
    return $?
  fi
  status=$?
  ((status == 1)) || return 7
}
container_still_matches() {
  local name=$1 expected=$2 actual
  actual=$(container_id "$name" 2>/dev/null) || return 1
  [[ -n $expected && $actual == "$expected" ]]
}

validate_network() {
  local name=$1 wanted_internal=$2 status=0
  network_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]; want=sys.argv[1]=="true"
labels=n.get("Labels") or n.get("labels") or {}; driver=(n.get("Driver") or n.get("driver") or "").lower()
internal=bool(n.get("Internal",n.get("internal",False))); ipv6=bool(n.get("EnableIPv6",n.get("IPv6Enabled",n.get("ipv6_enabled",False))))
dns=n.get("DNSEnabled",n.get("dns_enabled",not bool(n.get("DNSEnabled") is False)))
upstream=n.get("NetworkDNSServers",n.get("DNSServers",n.get("dns_servers",[]))) or []
if labels.get("io.basix.scrapling-tor.managed")!="true" or driver!="bridge" or internal!=want or ipv6 or upstream: raise SystemExit(1)
if want and not bool(dns): raise SystemExit(10)
  ' "$wanted_internal" || status=$?
  if ((status == 0 || status == 10)) && [[ $wanted_internal == true ]]; then
    validate_tor_alias_owner "$name" || return 7
  fi
  ((status == 0)) && return 0
  ((status == 10)) && return 10
  printf 'Refusing foreign or unsafe network named %s.\n' "$name" >&2
  return 7
}
validate_tor_alias_owner() {
  local name=$1 id container aliases connected classification=0
  connected=$(network_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
for ident,value in (n.get("Containers",n.get("containers",{})) or {}).items():
    if not isinstance(value,dict): raise SystemExit(2)
    name=value.get("Name",value.get("name",""))
    if not isinstance(name,str) or not name: raise SystemExit(2)
    print(ident, name)
') || return 7
  while read -r id container; do
    [[ -z $id && -z $container ]] && continue
    [[ -n $id && -n $container ]] || return 7
    aliases=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
network=sys.argv[1]
value=((n.get("NetworkSettings") or {}).get("Networks") or {}).get(network,{}) or {}
for alias in value.get("Aliases",value.get("aliases",[])) or []:
    print(alias)
' "$name") || return 7
    if grep -Fxq "$BASIX_TOR_HOST" <<<"$aliases"; then
      if [[ $container != "$TOR_CONTAINER" ]] || ! container_still_matches "$TOR_CONTAINER" "$id"; then
        printf 'Refusing network %s: foreign container %s claims alias %s.\n' "$name" "$container" "$BASIX_TOR_HOST" >&2
        return 7
      fi
      classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE" || classification=$?
      ((classification == 0 || classification == 10)) || {
        printf 'Refusing network %s: canonical Tor alias owner is unsafe.\n' "$name" >&2
        return 7
      }
      classification=0
    fi
  done <<<"$connected"
}

# Replace an owned DNS-disabled network; name is the validated internal network.
migrate_internal_network() {
  local name=$1 connected classification=0 id container result tor_id='' scrapling_id=''
  migration_disconnected_ids=(); migration_disconnected_names=()
  migration_original_internal_id=$(network_id "$name") || {
    printf 'Could not pin the managed network identity before migration.\n' >&2
    return 7
  }
  connected=$(network_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
for ident,value in (n.get("Containers") or n.get("containers") or {}).items():
    if not isinstance(value,dict): raise SystemExit(2)
    name=value.get("Name") or value.get("name") or ""
    if not isinstance(name,str) or not name: raise SystemExit(2)
    print(ident, name)
')
  while read -r id container; do
    [[ -z $id || $container == "$TOR_CONTAINER" || $container == "$SCRAPLING_CONTAINER" ]] && continue
    classification=0
    result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || classification=$?
    if [[ $classification == 0 && $result == managed-legacy ]]; then
      migration_disconnected_ids+=("$id"); migration_disconnected_names+=("$container")
      legacy_ids+=("$id"); legacy_names+=("$container")
      disconnect_if_connected "$name" "$id" || return 7
      printf 'Deferred removal of validated legacy Scrapling container %s until migration commit.\n' "$container" >&2
      continue
    fi
    printf 'Refusing DNS migration while foreign container %s uses %s.\n' "$container" "$name" >&2
    return 7
  done <<<"$connected"
  if container_json "$TOR_CONTAINER" >/dev/null 2>&1; then
    tor_id=$(container_id "$TOR_CONTAINER" 2>/dev/null || true)
    [[ -n $tor_id ]] || { printf 'Could not pin Tor container identity during network migration.\n' >&2; return 7; }
    classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE" || classification=$?
    ((classification == 0 || classification == 10)) || { printf 'Refusing DNS migration with unsafe Tor container.\n' >&2; return 7; }
  fi
  classification=0
  if container_json "$SCRAPLING_CONTAINER" >/dev/null 2>&1; then
    scrapling_id=$(container_id "$SCRAPLING_CONTAINER" 2>/dev/null || true)
    [[ -n $scrapling_id ]] || { printf 'Could not pin Scrapling container identity during network migration.\n' >&2; return 7; }
    classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py" || classification=$?
    if ((classification == 0 || classification == 10)); then
      container_still_matches "$SCRAPLING_CONTAINER" "$scrapling_id" || { printf 'Scrapling container changed during network migration; refusing removal.\n' >&2; return 7; }
      migration_disconnected_ids+=("$scrapling_id"); migration_disconnected_names+=("$SCRAPLING_CONTAINER")
      disconnect_if_connected "$name" "$scrapling_id" || return 7
    else
      classification=0
      result=$(container_json "$SCRAPLING_CONTAINER" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$scrapling_id" --policy "$HERE/policy_mcp.py") || classification=$?
      [[ $classification == 0 && $result == managed-legacy ]] || { printf 'Refusing DNS migration with unsafe Scrapling container.\n' >&2; return 7; }
      container_still_matches "$SCRAPLING_CONTAINER" "$scrapling_id" || { printf 'Scrapling container changed during legacy migration; refusing removal.\n' >&2; return 7; }
      migration_disconnected_ids+=("$scrapling_id"); migration_disconnected_names+=("$SCRAPLING_CONTAINER")
      legacy_ids+=("$scrapling_id"); legacy_names+=("$SCRAPLING_CONTAINER")
      disconnect_if_connected "$name" "$scrapling_id" || return 7
      printf 'Deferred removal of validated legacy Scrapling container until migration commit.\n' >&2
    fi
  fi
  if [[ -n $tor_id ]]; then
    container_still_matches "$TOR_CONTAINER" "$tor_id" || { printf 'Tor container changed during network migration; refusing network replacement.\n' >&2; return 7; }
    migration_disconnected_ids+=("$tor_id"); migration_disconnected_names+=("$TOR_CONTAINER")
    disconnect_if_connected "$name" "$tor_id" || return 7
  fi
  network_still_matches "$name" "$migration_original_internal_id" || {
    printf 'Refusing DNS migration after the managed network identity changed.\n' >&2
    return 7
  }
  "$RUNTIME" network rm "$name" >/dev/null
  migration_old_removed=true
  local create_args=(network create --driver bridge --internal --label "$LABEL_KEY=$LABEL_VALUE")
  [[ -n $TRANSACTION_ID ]] && create_args+=(--label "$TRANSACTION_LABEL_KEY=$TRANSACTION_ID")
  "$RUNTIME" "${create_args[@]}" "$name" >/dev/null
  created_internal=true
  migration_new_internal_id=$(network_id "$name") || return 7
  if [[ -n $tor_id ]]; then
    "$RUNTIME" network connect --alias "$BASIX_TOR_HOST" "$name" "$tor_id" >/dev/null
  fi
  if [[ -n $scrapling_id ]]; then
    "$RUNTIME" network connect "$name" "$scrapling_id" >/dev/null
  fi
  validate_network "$name" true
  created_internal=false
}

ensure_network() {
  local name=$1 internal=$2 classification=0
  if network_json "$name" >/dev/null 2>&1; then
    validate_network "$name" "$internal" || classification=$?
    if ((classification == 0)); then return; fi
    if ((classification == 10)) && [[ $internal == true ]]; then migrate_internal_network "$name"; return; fi
    return "$classification"
  fi
  local args=(network create --driver bridge --label "$LABEL_KEY=$LABEL_VALUE")
  [[ -n $TRANSACTION_ID ]] && args+=(--label "$TRANSACTION_LABEL_KEY=$TRANSACTION_ID")
  [[ $internal == false ]] || args+=(--internal)
  "$RUNTIME" "${args[@]}" "$name" >/dev/null
  if [[ $internal == true ]]; then
    created_internal=true
    created_internal_id=$(network_id "$name") || return 7
  else
    created_egress=true
    created_egress_id=$(network_id "$name") || return 7
  fi
  validate_network "$name" "$internal"
}

tor_bootstrap_verified() {
  local state
  state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$TOR_CONTAINER" 2>/dev/null || true)
  [[ $state == running ]] || return 1
  # Podman does not run healthchecks by itself unless a healthcheck manager is
  # active.  Check Tor's notice file directly so rootless installs do not wait
  # forever on a perpetually "starting" runtime health state.
  "$RUNTIME" exec "$TOR_CONTAINER" grep -q 'Bootstrapped 100%' /var/log/tor/notices.log
}

runtime_diagnostics() {
  local rootless runroot
  rootless='unknown'; runroot='unknown'
  if rootless=$("$RUNTIME" info --format '{{.Host.Security.Rootless}}' 2>/dev/null); then
    [[ -n $rootless ]] || rootless='unknown'
  else
    rootless='unknown'
  fi
  if runroot=$("$RUNTIME" info --format '{{.Store.RunRoot}}' 2>/dev/null); then
    [[ -n $runroot ]] || runroot='unknown'
  else
    runroot='unknown'
  fi
  printf 'Runtime: %s; Rootless: %s; Store.RunRoot: %s' "$RUNTIME" "$rootless" "$runroot"
}

probe_egress_netns() {
  local probe_status=0 cleanup_status=0
  probe_created=true
  if "$RUNTIME" run --name "$PROBE_CONTAINER" --network "$EGRESS_NET" \
    --cap-drop ALL --security-opt no-new-privileges --entrypoint /bin/true "$TOR_IMAGE" >/dev/null; then
    :
  else
    probe_status=$?
  fi
  if "$RUNTIME" rm -f "$PROBE_CONTAINER" >/dev/null 2>&1; then
    probe_created=false
  else
    cleanup_status=$?
  fi
  if ((probe_status != 0 || cleanup_status != 0)); then
    printf 'Host runtime/network namespace probe failed (probe exit: %s; cleanup exit: %s; %s); no Tor or Scrapling container was started. Check the rootless netns runroot and retry after the host runtime is fixed.\n' "$probe_status" "$cleanup_status" "$(runtime_diagnostics)" >&2
    return 4
  fi
}

run_created_container() {
  local ref_name=$1 output='' status=0 cidfile='' id='' run_args=()
  shift
  run_args=("$@")
  cidfile=$(mktemp "${TMPDIR:-/tmp}/basix-scrapling-container.XXXXXX")
  rm -f "$cidfile"
  if output=$("$RUNTIME" run "${run_args[0]}" "${run_args[1]}" "${run_args[2]}" --cidfile "$cidfile" "${run_args[@]:3}"); then
    status=0
  else
    status=$?
  fi
  [[ -r $cidfile ]] && id=$(<"$cidfile")
  rm -f "$cidfile"
  if [[ $output =~ ^[[:alnum:]_.-]+$ ]]; then
    printf -v "$ref_name" '%s' "$output"
  elif [[ $id =~ ^[[:alnum:]_.-]+$ ]]; then
    printf -v "$ref_name" '%s' "$id"
  else
    printf -v "$ref_name" '%s' ''
  fi
  return "$status"
}

classify_container() {
  local name=$1 kind=$2 configured_image=$3 actual_image=$4 policy_path=${6-}
  local policy_args=(managed "$kind" --configured "$configured_image" --actual "$actual_image" --port "$PORT" --policy "$policy_path")
  [[ $kind == scrapling ]] && policy_args+=(--tor-host "$BASIX_TOR_HOST")
  container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" "${policy_args[@]}"
}

ensure_tor() {
  ensure_network "$EGRESS_NET" false
  probe_egress_netns
  ensure_network "$INTERNAL_NET" true
  local create=true classification=0 tor_id=''
  if container_json "$TOR_CONTAINER" >/dev/null 2>&1; then
    tor_id=$(container_id "$TOR_CONTAINER" 2>/dev/null || true)
    [[ -n $tor_id ]] || { printf 'Could not pin Tor container identity; refusing replacement.\n' >&2; return 7; }
    classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE" || classification=$?
    case $classification in
      0) container_still_matches "$TOR_CONTAINER" "$tor_id" || { printf 'Tor container changed before start; refusing action.\n' >&2; return 7; }; "$RUNTIME" start "$tor_id" >/dev/null; create=false ;;
      10) printf 'Replacing safely managed Tor sidecar with canonical immutable image %s.\n' "$TOR_IMAGE" >&2; container_still_matches "$TOR_CONTAINER" "$tor_id" || { printf 'Tor container changed before replacement; refusing action.\n' >&2; return 7; }; "$RUNTIME" rm -f "$tor_id" >/dev/null ;;
      *) printf 'Refusing foreign or unsafe Tor container named %s.\n' "$TOR_CONTAINER" >&2; return 7 ;;
    esac
  fi
  if $create; then
    created_tor=true
    run_created_container created_tor_ref -d --name "$TOR_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$EGRESS_NET" --cap-drop ALL --security-opt no-new-privileges \
      --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
      --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 "$TOR_IMAGE" >/dev/null
    "$RUNTIME" network connect --alias "$BASIX_TOR_HOST" "$INTERNAL_NET" "$TOR_CONTAINER" >/dev/null
    classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE"
  fi
  local health state verified=false
  for attempt in $(seq 1 120); do
    if tor_bootstrap_verified; then verified=true; break; fi
    state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$TOR_CONTAINER" 2>/dev/null || true)
    [[ $state == exited || $state == stopped || $state == dead ]] && break
    sleep 2
  done
  if ! $verified; then
    health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || true)
    state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$TOR_CONTAINER" 2>/dev/null || true)
    printf 'Tor sidecar did not reach 100%% bootstrap (state: %s; runtime health: %s; direct notice check: failed).\n' "${state:-unknown}" "${health:-unknown}" >&2
    return 9
  fi
}

tor_ip() { "$RUNTIME" inspect --format "{{with index .NetworkSettings.Networks \"$INTERNAL_NET\"}}{{.IPAddress}}{{end}}" "$TOR_CONTAINER"; }

port_available() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$PORT" <<'PY'
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try: s.bind(("127.0.0.1",int(sys.argv[1])))
except OSError: raise SystemExit(1)
finally: s.close()
PY
}

container_diagnostics() {
  local listing name state health bootstrap ip
  printf 'MCP verification failed; collecting container diagnostics before rollback.\n' >&2
  printf '%s\n' "$(runtime_diagnostics)" >&2
  if listing=$("$RUNTIME" ps -a --no-trunc 2>&1); then
    printf '%s\n' 'Container status (all containers):' >&2
    printf '%s\n' "$listing" >&2
  else
    printf 'Could not collect container status: %s\n' "$listing" >&2
  fi
  for name in "$TOR_CONTAINER" "$SCRAPLING_CONTAINER"; do
    state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || printf 'absent')
    health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || printf 'unavailable')
    bootstrap='n/a'
    [[ $name != "$TOR_CONTAINER" ]] || { tor_bootstrap_verified && bootstrap=verified || bootstrap=failed; }
    printf 'Container %s: state=%s health=%s bootstrap=%s\n' "$name" "$state" "$health" "$bootstrap" >&2
    printf 'Logs for %s (last 200 lines):\n' "$name" >&2
    if ! "$RUNTIME" logs --tail 200 "$name" >&2; then
      printf 'Could not collect logs for %s.\n' "$name" >&2
    fi
  done
  ip=$(tor_ip 2>/dev/null || true)
  printf 'Tor gateway IP on %s: %s\n' "$INTERNAL_NET" "${ip:-unavailable}" >&2
}

classify_running_scrapling() {
  local id name extra result classification listing
  legacy_ids=(); legacy_names=()
  if ! listing=$("$RUNTIME" ps -a --no-trunc --format '{{.ID}} {{.Names}}'); then
    printf 'Could not enumerate running containers; refusing Scrapling migration.\n' >&2
    return 7
  fi
  while read -r id name extra; do
    [[ -z $id && -z $name && -z $extra ]] && continue
    [[ -n $id && -n $name && -z $extra ]] || { printf 'Runtime returned malformed container listing; refusing Scrapling migration.\n' >&2; return 7; }
    [[ $name != "$TOR_CONTAINER" && $name != "$SCRAPLING_CONTAINER" && $name != *.basix-rollback-* ]] || continue
    classification=0
    result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || classification=$?
    case $classification:$result in
      0:unrelated) ;;
      0:managed-legacy)
        if ! printf '%s\n' "${legacy_ids[@]}" | grep -Fxq "$id"; then
          legacy_ids+=("$id"); legacy_names+=("$name")
        fi
        printf 'Validated managed legacy Scrapling container %s for deferred migration.\n' "$name" >&2 ;;
      *)
        printf 'Refusing foreign or unsafe running Scrapling container named %s.\n' "$name" >&2
        return 7 ;;
    esac
  done <<<"$listing"
}

remove_validated_legacy() {
  local index id name result classification
  for index in "${!legacy_ids[@]}"; do
    id=${legacy_ids[$index]}; name=${legacy_names[$index]}; classification=0
    result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || classification=$?
    [[ $classification == 0 && $result == managed-legacy ]] || {
      printf 'Validated legacy Scrapling container %s disappeared or changed; refusing removal.\n' "$name" >&2
      return 7
    }
    "$RUNTIME" rm -f "$id" >/dev/null || return 7
    printf 'Removed validated legacy Scrapling container %s after HTTP verification.\n' "$name" >&2
  done
}

classify_named_scrapling() {
  local classification=0
  if ! container_json "$SCRAPLING_CONTAINER" >/dev/null 2>&1; then
    return 0
  fi
  classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py" || classification=$?
  case $classification in
    0|10) return 0 ;;
    *)
      printf 'Refusing foreign or unsafe Scrapling container named %s before Tor reconciliation.\n' "$SCRAPLING_CONTAINER" >&2
      return 7
      ;;
  esac
}

ensure_scrapling() {
  classify_running_scrapling
  classify_named_scrapling
  ensure_tor
  classify_running_scrapling
  local create=true classification=0 scrapling_id='' replace_requested=${BASIX_SETUP_REPLACE_SCRAPLING:-false}
  if container_json "$SCRAPLING_CONTAINER" >/dev/null 2>&1; then
    scrapling_id=$(container_id "$SCRAPLING_CONTAINER" 2>/dev/null || true)
    [[ -n $scrapling_id ]] || { printf 'Could not pin Scrapling container identity; refusing replacement.\n' >&2; return 7; }
    classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py" || classification=$?
    case $classification in
      0)
        container_still_matches "$SCRAPLING_CONTAINER" "$scrapling_id" || { printf 'Scrapling container changed before start; refusing action.\n' >&2; return 7; }
        if [[ $replace_requested == true ]]; then
          printf 'Replacing the existing managed Scrapling service with the latest installer setup.\n' >&2
          "$RUNTIME" rm -f "$scrapling_id" >/dev/null
        else
          "$RUNTIME" start "$scrapling_id" >/dev/null
          create=false
        fi
        ;;
      10) printf 'Replacing safely managed Scrapling service with canonical immutable image %s.\n' "$SCRAPLING_IMAGE" >&2; container_still_matches "$SCRAPLING_CONTAINER" "$scrapling_id" || { printf 'Scrapling container changed before replacement; refusing action.\n' >&2; return 7; }; "$RUNTIME" rm -f "$scrapling_id" >/dev/null ;;
      *) printf 'Refusing foreign or unsafe Scrapling container named %s.\n' "$SCRAPLING_CONTAINER" >&2; return 7 ;;
    esac
  fi
  if $create; then
    port_available || { printf 'Loopback port %s is already in use; no resource was replaced.\n' "$PORT" >&2; return 7; }
    created_scrapling=true
    run_created_container created_scrapling_ref -d --name "$SCRAPLING_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$INTERNAL_NET" --cap-drop ALL --security-opt no-new-privileges -p "127.0.0.1:$PORT:$PORT" \
      -e "BASIX_TOR_HOST=$BASIX_TOR_HOST" -e "BASIX_PORT=$PORT" -e "HTTP_PROXY=socks5h://$BASIX_TOR_HOST:9050" -e "HTTPS_PROXY=socks5h://$BASIX_TOR_HOST:9050" -e "ALL_PROXY=socks5h://$BASIX_TOR_HOST:9050" \
      -e "http_proxy=socks5h://$BASIX_TOR_HOST:9050" -e "https_proxy=socks5h://$BASIX_TOR_HOST:9050" -e "all_proxy=socks5h://$BASIX_TOR_HOST:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
      -v "$HERE/policy_mcp.py:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$SCRAPLING_IMAGE" /opt/basix/policy_mcp.py >/dev/null
    classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py"
  fi
}

verify_mcp() {
  local status=0 output attempt
  for attempt in $(seq 1 6); do
    if output=$(PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/health_check.py" "$ENDPOINT" 2>&1); then
      [[ -z $output ]] || printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi
    printf '%s\n' "$output" >&2
    case $output in
      *'Connection reset by peer'*|*'Connection refused'*|*'timed out'*|*'Remote end closed connection without response'*)
        if ((attempt < 6)); then
          printf 'MCP endpoint is still starting; retrying health check (%s/6).\n' "$((attempt + 1))" >&2
          sleep 2
          continue
        fi
        ;;
    esac
    break
  done
  container_diagnostics
  return "$status"
}

prepare() { ensure_scrapling; verify_mcp; }
migrate_legacy() { ensure_scrapling; verify_mcp; remove_validated_legacy; }
start() { ensure_scrapling; verify_mcp; remove_validated_legacy; }
stop() { "$RUNTIME" stop "$SCRAPLING_CONTAINER" "$TOR_CONTAINER" >/dev/null; }
status() {
  local tor_health tor_bootstrap scrapling_state alias_resolution tor_reachability scrapling_readiness registration
  tor_health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || printf absent)
  if tor_bootstrap_verified; then tor_bootstrap=verified; else tor_bootstrap=not-verified; fi
  scrapling_state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$SCRAPLING_CONTAINER" 2>/dev/null || printf absent)
  if "$RUNTIME" exec "$SCRAPLING_CONTAINER" /app/.venv/bin/python -c 'import socket; socket.getaddrinfo("basix-tor-proxy",9050)' >/dev/null 2>&1; then alias_resolution=verified; else alias_resolution=not-verified; fi
  if "$RUNTIME" exec "$SCRAPLING_CONTAINER" /app/.venv/bin/python -c 'import socket; s=socket.create_connection(("basix-tor-proxy",9050),2); s.close()' >/dev/null 2>&1; then tor_reachability=verified; else tor_reachability=not-verified; fi
  if [[ $alias_resolution == verified && $tor_reachability == verified ]] && PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/health_check.py" "$ENDPOINT" --mcp-only >/dev/null 2>&1; then scrapling_readiness=verified; else scrapling_readiness=not-verified; fi
  if command -v codex >/dev/null 2>&1 && codex mcp list --json 2>/dev/null | PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/codex_scan.py" verify --endpoint "$ENDPOINT" >/dev/null 2>&1; then registration=canonical; else registration=missing-or-different; fi
  printf 'Tor health: %s\nTor bootstrap: %s\nTor alias resolution: %s\nLocal Tor reachability: %s\nScrapling state: %s\nScrapling readiness: %s\nEndpoint: %s\nCodex registration: %s\n' \
    "$tor_health" "$tor_bootstrap" "$alias_resolution" "$tor_reachability" "$scrapling_state" "$scrapling_readiness" "$ENDPOINT" "$registration"
}

case "${1:-status}" in
  prepare) prepare ;; migrate-legacy) migrate_legacy ;; start) start ;; stop) stop ;; status) status ;; tor-ip) ensure_tor; tor_ip ;;
  *) printf 'Usage: %s [prepare|migrate-legacy|start|stop|status|tor-ip]\n' "$0" >&2; exit 2 ;;
esac
