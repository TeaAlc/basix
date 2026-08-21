#!/usr/bin/env bash
set -Eeuo pipefail

readonly LABEL_KEY='io.basix.scrapling-tor.managed' LABEL_VALUE='true'
readonly INTERNAL_NET='basix-scrapling-internal' EGRESS_NET='basix-tor-egress'
readonly TOR_CONTAINER='basix-scrapling-tor' SCRAPLING_CONTAINER='basix-scrapling-mcp'
readonly PROBE_CONTAINER="basix-scrapling-egress-probe-$$-$RANDOM"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); readonly HERE
readonly CONTAINER_POLICY="$HERE/container_policy.py"
[[ -r $HERE/config ]] || { printf 'Basix Scrapling configuration is missing; rerun the installer.\n' >&2; exit 3; }
# shellcheck source=/dev/null
source "$HERE/config"
: "${RUNTIME:?}" "${SCRAPLING_IMAGE:?}" "${SCRAPLING_ID:?}" "${TOR_IMAGE:?}" "${PORT:?}"
readonly ENDPOINT="http://127.0.0.1:$PORT/mcp"

created_internal=false created_egress=false created_tor=false created_scrapling=false probe_created=false
created_tor_ref='' created_scrapling_ref=''
legacy_ids=() legacy_names=()
rollback() {
  local status=$?; trap - ERR
  if $probe_created; then "$RUNTIME" rm -f "$PROBE_CONTAINER" >/dev/null 2>&1 || true; fi
  if $created_scrapling && [[ -n $created_scrapling_ref ]]; then "$RUNTIME" rm -f "$created_scrapling_ref" >/dev/null 2>&1 || true; fi
  if $created_tor && [[ -n $created_tor_ref ]]; then "$RUNTIME" rm -f "$created_tor_ref" >/dev/null 2>&1 || true; fi
  if $created_internal; then "$RUNTIME" network rm "$INTERNAL_NET" >/dev/null 2>&1 || true; fi
  if $created_egress; then "$RUNTIME" network rm "$EGRESS_NET" >/dev/null 2>&1 || true; fi
  return "$status"
}
trap rollback ERR

network_json() { "$RUNTIME" network inspect "$1"; }
container_json() { "$RUNTIME" inspect "$1"; }

validate_network() {
  local name=$1 wanted_internal=$2
  network_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]; want=sys.argv[1]=="true"
labels=n.get("Labels") or n.get("labels") or {}; driver=(n.get("Driver") or n.get("driver") or "").lower()
internal=bool(n.get("Internal",n.get("internal",False))); ipv6=bool(n.get("EnableIPv6",n.get("IPv6Enabled",False)))
if labels.get("io.basix.scrapling-tor.managed")!="true" or driver!="bridge" or internal!=want or ipv6: raise SystemExit(1)
' "$wanted_internal" || { printf 'Refusing foreign or unsafe network named %s.\n' "$name" >&2; return 7; }
}

ensure_network() {
  local name=$1 internal=$2
  if network_json "$name" >/dev/null 2>&1; then validate_network "$name" "$internal"; return; fi
  local args=(network create --driver bridge --label "$LABEL_KEY=$LABEL_VALUE")
  [[ $internal == false ]] || args+=(--internal)
  [[ $RUNTIME != podman || $internal == false ]] || args+=(--disable-dns)
  "$RUNTIME" "${args[@]}" "$name" >/dev/null
  if [[ $internal == true ]]; then created_internal=true; else created_egress=true; fi
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
  local name=$1 kind=$2 configured_image=$3 actual_image=$4 tor_address=${5-} policy_path=${6-}
  local policy_args=(managed "$kind" --configured "$configured_image" --actual "$actual_image" --port "$PORT" --policy "$policy_path")
  [[ $kind == scrapling ]] && policy_args+=(--tor-ip "$tor_address")
  container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" "${policy_args[@]}"
}

ensure_tor() {
  ensure_network "$EGRESS_NET" false
  probe_egress_netns
  ensure_network "$INTERNAL_NET" true
  local create=true classification=0
  if container_json "$TOR_CONTAINER" >/dev/null 2>&1; then
    classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE" || classification=$?
    case $classification in
      0) "$RUNTIME" start "$TOR_CONTAINER" >/dev/null; create=false ;;
      10) printf 'Replacing safely managed Tor sidecar with canonical immutable image %s.\n' "$TOR_IMAGE" >&2; "$RUNTIME" rm -f "$TOR_CONTAINER" >/dev/null ;;
      *) printf 'Refusing foreign or unsafe Tor container named %s.\n' "$TOR_CONTAINER" >&2; return 7 ;;
    esac
  fi
  if $create; then
    created_tor=true
    run_created_container created_tor_ref -d --name "$TOR_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$EGRESS_NET" --cap-drop ALL --security-opt no-new-privileges \
      --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
      --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 "$TOR_IMAGE" >/dev/null
    "$RUNTIME" network connect "$INTERNAL_NET" "$TOR_CONTAINER" >/dev/null
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
  if ! listing=$("$RUNTIME" ps --no-trunc --format '{{.ID}} {{.Names}}'); then
    printf 'Could not enumerate running containers; refusing Scrapling migration.\n' >&2
    return 7
  fi
  while read -r id name extra; do
    [[ -z $id && -z $name && -z $extra ]] && continue
    [[ -n $id && -n $name && -z $extra ]] || { printf 'Runtime returned malformed container listing; refusing Scrapling migration.\n' >&2; return 7; }
    [[ $name != "$TOR_CONTAINER" && $name != "$SCRAPLING_CONTAINER" ]] || continue
    classification=0
    result=$(container_json "$id" | PYTHONDONTWRITEBYTECODE=1 python3 "$CONTAINER_POLICY" candidate --id "$id" --policy "$HERE/policy_mcp.py") || classification=$?
    case $classification:$result in
      0:unrelated) ;;
      0:managed-legacy)
        legacy_ids+=("$id"); legacy_names+=("$name")
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

ensure_scrapling() {
  ensure_tor
  local ip create=true classification=0; ip=$(tor_ip)
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Could not determine numeric Tor gateway IP.\n' >&2; return 9; }
  classify_running_scrapling
  if container_json "$SCRAPLING_CONTAINER" >/dev/null 2>&1; then
    classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$ip" "$HERE/policy_mcp.py" || classification=$?
    case $classification in
      0) "$RUNTIME" start "$SCRAPLING_CONTAINER" >/dev/null; create=false ;;
      10) printf 'Replacing safely managed Scrapling service with canonical immutable image %s.\n' "$SCRAPLING_IMAGE" >&2; "$RUNTIME" rm -f "$SCRAPLING_CONTAINER" >/dev/null ;;
      *) printf 'Refusing foreign or unsafe Scrapling container named %s.\n' "$SCRAPLING_CONTAINER" >&2; return 7 ;;
    esac
  fi
  if $create; then
    port_available || { printf 'Loopback port %s is already in use; no resource was replaced.\n' "$PORT" >&2; return 7; }
    local dns=(); [[ $RUNTIME != podman ]] || dns=(--dns 127.0.0.1)
    created_scrapling=true
    run_created_container created_scrapling_ref -d --name "$SCRAPLING_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$INTERNAL_NET" "${dns[@]}" --cap-drop ALL --security-opt no-new-privileges -p "127.0.0.1:$PORT:$PORT" \
      -e "BASIX_TOR_IP=$ip" -e "BASIX_PORT=$PORT" -e "HTTP_PROXY=socks5h://$ip:9050" -e "HTTPS_PROXY=socks5h://$ip:9050" -e "ALL_PROXY=socks5h://$ip:9050" \
      -e "http_proxy=socks5h://$ip:9050" -e "https_proxy=socks5h://$ip:9050" -e "all_proxy=socks5h://$ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
      -v "$HERE/policy_mcp.py:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$SCRAPLING_IMAGE" /opt/basix/policy_mcp.py >/dev/null
    classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$ip" "$HERE/policy_mcp.py"
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
  local tor_health tor_bootstrap scrapling_state registration
  tor_health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || printf absent)
  if tor_bootstrap_verified; then tor_bootstrap=verified; else tor_bootstrap=not-verified; fi
  scrapling_state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$SCRAPLING_CONTAINER" 2>/dev/null || printf absent)
  if command -v codex >/dev/null 2>&1 && codex mcp list --json 2>/dev/null | PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/codex_scan.py" verify --endpoint "$ENDPOINT" >/dev/null 2>&1; then registration=canonical; else registration=missing-or-different; fi
  printf 'Tor health: %s\nTor bootstrap: %s\nScrapling state: %s\nEndpoint: %s\nCodex registration: %s\n' "$tor_health" "$tor_bootstrap" "$scrapling_state" "$ENDPOINT" "$registration"
}

case "${1:-status}" in
  prepare) prepare ;; migrate-legacy) migrate_legacy ;; start) start ;; stop) stop ;; status) status ;; tor-ip) ensure_tor; tor_ip ;;
  *) printf 'Usage: %s [prepare|migrate-legacy|start|stop|status|tor-ip]\n' "$0" >&2; exit 2 ;;
esac
