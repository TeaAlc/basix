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

created_internal=false created_egress=false created_tor=false created_scrapling=false probe_created=false diagnostics_collected=false
created_internal_id='' created_egress_id='' created_tor_ref='' created_scrapling_ref=''
rollback() {
  local status=$? failed_line=${1:-unknown}; trap - ERR
  printf 'Managed service preparation failed at launcher line %s (exit %s).\n' "$failed_line" "$status" >&2
  if ! $diagnostics_collected; then container_diagnostics || true; fi
  if $probe_created; then "$RUNTIME" rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true; fi
  if $created_scrapling && [[ -n $created_scrapling_ref ]]; then "$RUNTIME" rm -f "$created_scrapling_ref" >/dev/null 2>&1 || true; fi
  if $created_tor && [[ -n $created_tor_ref ]]; then "$RUNTIME" rm -f "$created_tor_ref" >/dev/null 2>&1 || true; fi
  if $created_internal && network_still_matches "$INTERNAL_NET" "$created_internal_id"; then "$RUNTIME" network rm "$created_internal_id" >/dev/null 2>&1 || true; fi
  if $created_egress && network_still_matches "$EGRESS_NET" "$created_egress_id"; then "$RUNTIME" network rm "$created_egress_id" >/dev/null 2>&1 || true; fi
  return "$status"
}
trap 'rollback "$LINENO"' ERR

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

# Retired owned networks are replaced empty; no retired resource is restored.
replace_internal_network() {
  local name=$1 pinned connected
  pinned=$(network_id "$name") || return 7
  connected=$(network_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c 'import json,sys; n=json.load(sys.stdin)[0]; print(len(n.get("Containers",n.get("containers",{})) or {}))') || return 7
  [[ $connected == 0 ]] || { printf 'Refusing replacement of nonempty retired network %s.\n' "$name" >&2; return 7; }
  network_still_matches "$name" "$pinned" || return 7
  "$RUNTIME" network rm "$pinned" >/dev/null
  ensure_network "$name" true
}

ensure_network() {
  local name=$1 internal=$2 classification=0
  if network_json "$name" >/dev/null 2>&1; then
    validate_network "$name" "$internal" || classification=$?
    if ((classification == 0)); then return; fi
    if ((classification == 10)) && [[ $internal == true ]]; then replace_internal_network "$name"; return; fi
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
  # Explicit current readiness works even without a host healthcheck manager.
  "$RUNTIME" exec "$TOR_CONTAINER" python3 /opt/basix/service_supervisor.py --probe tor
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
      --health-cmd 'python3 /opt/basix/service_supervisor.py --probe tor' \
      --health-interval 15s --health-timeout 8s --health-start-period 120s --health-retries 3 "$TOR_IMAGE" >/dev/null
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
    printf 'Tor sidecar did not reach current readiness (state: %s; runtime health: %s; local control/SOCKS/circuit check: failed).\n' "${state:-unknown}" "${health:-unknown}" >&2
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
  diagnostics_collected=true
  printf 'Managed service preparation failed; collecting container diagnostics before rollback.\n' >&2
  printf '%s\n' "$(runtime_diagnostics)" >&2
  if listing=$("$RUNTIME" ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.Status}}' 2>&1); then
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
    if [[ $name == "$TOR_CONTAINER" ]]; then
      printf 'Current Tor notices (last 100 lines):\n' >&2
      "$RUNTIME" exec "$name" tail -n 100 /var/log/tor/notices.log >&2 || true
    fi
  done
  ip=$(tor_ip 2>/dev/null || true)
  printf 'Tor gateway IP on %s: %s\n' "$INTERNAL_NET" "${ip:-unavailable}" >&2
}

# Fully validate the removal inventory before deleting any owned container.
retire_owned() {
  local name id kind configured actual classification result listing extra network connected member
  local remove_ids=() remove_names=() remove_kinds=() owned_ids=()
  for name in "$TOR_CONTAINER" "$SCRAPLING_CONTAINER"; do
    container_json "$name" >/dev/null 2>&1 || continue
    id=$(container_id "$name") || return 7
    [[ -n $id ]] || return 7
    kind=tor configured=$TOR_IMAGE actual=$TOR_IMAGE
    if [[ $name == "$SCRAPLING_CONTAINER" ]]; then kind=scrapling; configured=$SCRAPLING_IMAGE; actual=$SCRAPLING_ID; fi
    classification=0
    classify_container "$name" "$kind" "$configured" "$actual" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py" || classification=$?
    if ((classification != 0 && classification != 10)); then
      result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || { printf 'Refusing foreign or unsafe %s container before replacement.\n' "$([[ $kind == tor ]] && printf Tor || printf Scrapling)" >&2; return 7; }
      [[ $kind == scrapling && $result == managed-legacy ]] || return 7
      classification=10
    fi
    owned_ids+=("$id")
    if ((classification == 10)) || [[ ${BASIX_SETUP_REPLACE_SCRAPLING:-false} == true ]]; then
      remove_ids+=("$id"); remove_names+=("$name"); remove_kinds+=("$kind")
    fi
  done
  listing=$("$RUNTIME" ps -a --no-trunc --format '{{.ID}} {{.Names}}') || { printf 'Could not enumerate running containers; refusing replacement.\n' >&2; return 7; }
  while read -r id name extra; do
    [[ -z $id && -z $name && -z $extra ]] && continue
    [[ -n $id && -n $name && -z $extra ]] || { printf 'Runtime returned malformed container listing.\n' >&2; return 7; }
    [[ $name != "$TOR_CONTAINER" && $name != "$SCRAPLING_CONTAINER" ]] || continue
    result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || { printf 'Refusing foreign or unsafe running Scrapling container %s.\n' "$name" >&2; return 7; }
    case $result in
      unrelated) ;;
      managed-legacy) remove_ids+=("$id"); remove_names+=("$name"); remove_kinds+=(stdio); owned_ids+=("$id") ;;
      *) return 7 ;;
    esac
  done <<<"$listing"
  for network in "$INTERNAL_NET" "$EGRESS_NET"; do
    network_json "$network" >/dev/null 2>&1 || continue
    classification=0
    [[ $network == "$INTERNAL_NET" ]] && kind=true || kind=false
    validate_network "$network" "$kind" || classification=$?
    ((classification == 0 || classification == 10)) || return 7
    # A strict network is retained; unrelated attachments are never mutated.
    # A retired network must be replaced empty, so prove every attachment owned.
    ((classification == 10)) || continue
    connected=$(network_json "$network" | PYTHONDONTWRITEBYTECODE=1 python3 -c 'import json,sys; n=json.load(sys.stdin)[0]; print("\n".join((n.get("Containers",n.get("containers",{})) or {}).keys()))') || return 7
    while read -r member; do
      [[ -z $member ]] && continue
      printf '%s\n' "${owned_ids[@]}" | grep -Fxq "$member" || { printf 'Refusing network replacement with foreign attached container.\n' >&2; return 7; }
    done <<<"$connected"
  done
  local index
  for index in "${!remove_ids[@]}"; do
    id=${remove_ids[$index]}; name=${remove_names[$index]}; kind=${remove_kinds[$index]}
    container_still_matches "$name" "$id" || return 7
    if [[ $kind == stdio ]]; then
      result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || return 7
      [[ $result == managed-legacy ]] || return 7
    else
      configured=$TOR_IMAGE actual=$TOR_IMAGE
      if [[ $kind == scrapling ]]; then configured=$SCRAPLING_IMAGE; actual=$SCRAPLING_ID; fi
      classification=0
      classify_container "$name" "$kind" "$configured" "$actual" "$BASIX_TOR_HOST" "$HERE/policy_mcp.py" || classification=$?
      ((classification == 0 || classification == 10)) || return 7
    fi
    "$RUNTIME" rm -f "$id" >/dev/null || return 7
    printf 'Removed positively identified owned retired container %s; no retired restoration.\n' "$name" >&2
  done
}

ensure_scrapling() {
  retire_owned
  ensure_tor
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
    local acquisition_root="$HERE/../scrapling-artifacts"
    [[ ! -L $acquisition_root ]] || { printf "Unsafe acquisition root.\n" >&2; return 7; }
    mkdir -m 700 -p "$acquisition_root"
    [[ $(stat -c %u "$acquisition_root") == $(id -u) && $(stat -c %a "$acquisition_root") == 700 ]] || { printf "Unsafe acquisition root ownership/mode.\n" >&2; return 7; }
    port_available || { printf 'Loopback port %s is already in use; no resource was replaced.\n' "$PORT" >&2; return 7; }
    created_scrapling=true
    run_created_container created_scrapling_ref -d --name "$SCRAPLING_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$INTERNAL_NET" --cap-drop ALL --security-opt no-new-privileges -p "127.0.0.1:$PORT:$PORT" \
      -e "BASIX_TOR_HOST=$BASIX_TOR_HOST" -e "BASIX_PORT=$PORT" -e "HTTP_PROXY=socks5h://$BASIX_TOR_HOST:9050" -e "HTTPS_PROXY=socks5h://$BASIX_TOR_HOST:9050" -e "ALL_PROXY=socks5h://$BASIX_TOR_HOST:9050" \
      -e "http_proxy=socks5h://$BASIX_TOR_HOST:9050" -e "https_proxy=socks5h://$BASIX_TOR_HOST:9050" -e "all_proxy=socks5h://$BASIX_TOR_HOST:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
      -e 'PYTHONDONTWRITEBYTECODE=1' \
      --health-cmd '/app/.venv/bin/python /opt/basix/service_supervisor.py --probe mcp' \
      --health-interval 15s --health-timeout 8s --health-start-period 120s --health-retries 3 \
      -v "$HERE/policy_mcp.py:/opt/basix/policy_mcp.py:ro" \
      -v "$HERE/service_supervisor.py:/opt/basix/service_supervisor.py:ro" \
      -v "$HERE/health_check.py:/opt/basix/health_check.py:ro" \
      -v "$HERE/binary_acquisition.py:/opt/basix/binary_acquisition.py:ro" \
      -v "$acquisition_root:/var/lib/basix-acquisition:rw" \
      --entrypoint /app/.venv/bin/python "$SCRAPLING_IMAGE" /opt/basix/service_supervisor.py mcp >/dev/null
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
start() { ensure_scrapling; verify_mcp; }
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
  prepare) prepare ;; start) start ;; stop) stop ;; status) status ;; tor-ip) retire_owned; ensure_tor; tor_ip ;;
  *) printf 'Usage: %s [prepare|start|stop|status|tor-ip]\n' "$0" >&2; exit 2 ;;
esac
