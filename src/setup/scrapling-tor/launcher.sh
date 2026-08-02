#!/usr/bin/env bash
set -Eeuo pipefail

readonly LABEL_KEY='io.basix.scrapling-tor.managed' LABEL_VALUE='true'
readonly INTERNAL_NET='basix-scrapling-internal' EGRESS_NET='basix-tor-egress'
readonly TOR_CONTAINER='basix-scrapling-tor'
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); readonly HERE
[[ -r $HERE/config ]] || { printf 'Basix Scrapling configuration is missing; rerun the installer.\n' >&2; exit 3; }
# shellcheck source=/dev/null
source "$HERE/config"
: "${RUNTIME:?}" "${SCRAPLING_IMAGE:?}" "${TOR_IMAGE:?}"

created_internal=false created_egress=false created_container=false
rollback() {
  local status=$?; trap - ERR
  $created_container && "$RUNTIME" rm -f "$TOR_CONTAINER" >/dev/null 2>&1 || true
  $created_internal && "$RUNTIME" network rm "$INTERNAL_NET" >/dev/null 2>&1 || true
  $created_egress && "$RUNTIME" network rm "$EGRESS_NET" >/dev/null 2>&1 || true
  return "$status"
}
trap rollback ERR

network_json() { "$RUNTIME" network inspect "$1"; }
container_json() { "$RUNTIME" inspect "$1"; }

validate_network() {
  local name=$1 wanted_internal=$2
  network_json "$name" | python3 -c '
import json,sys
n=json.load(sys.stdin)[0]; want=sys.argv[1]=="true"
labels=n.get("Labels") or n.get("labels") or {}
driver=(n.get("Driver") or n.get("driver") or "").lower()
internal=bool(n.get("Internal", n.get("internal", False)))
ipv6=bool(n.get("EnableIPv6", n.get("IPv6Enabled", n.get("ipv6_enabled", False))))
if labels.get("io.basix.scrapling-tor.managed")!="true" or driver!="bridge" or internal!=want or ipv6:
 raise SystemExit(1)
' "$wanted_internal" || { printf 'Refusing foreign or unsafe network named %s.\n' "$name" >&2; exit 7; }
}

ensure_network() {
  local name=$1 internal=$2
  if network_json "$name" >/dev/null 2>&1; then validate_network "$name" "$internal"; return; fi
  if [[ $internal == true ]]; then
    if [[ $RUNTIME == podman ]]; then
      "$RUNTIME" network create --driver bridge --internal --disable-dns --label "$LABEL_KEY=$LABEL_VALUE" "$name" >/dev/null
    else
      "$RUNTIME" network create --driver bridge --internal --label "$LABEL_KEY=$LABEL_VALUE" "$name" >/dev/null
    fi
    created_internal=true
  else
    "$RUNTIME" network create --driver bridge --label "$LABEL_KEY=$LABEL_VALUE" "$name" >/dev/null
    created_egress=true
  fi
  validate_network "$name" "$internal"
}

classify_tor() {
  container_json "$TOR_CONTAINER" | python3 -c '
import json,sys
c=json.load(sys.stdin)[0]; cfg=c.get("Config") or {}; host=c.get("HostConfig") or {}
labels=cfg.get("Labels") or {}; wanted=sys.argv[1].lower()
nets=set(((c.get("NetworkSettings") or {}).get("Networks") or {}))
caps=host.get("CapAdd") or []; dropped={str(x).upper().removeprefix("CAP_") for x in (host.get("CapDrop") or [])}
ports=host.get("PortBindings") or {}; exposed=cfg.get("ExposedPorts") or {}
security=host.get("SecurityOpt") or []
health=cfg.get("Healthcheck") or {}
create=cfg.get("CreateCommand") or []
podman_drop=(any(x=="--cap-drop=ALL" for x in create) or
             any(create[i]=="--cap-drop" and create[i+1]=="ALL" for i in range(len(create)-1)))
podman_empty=("EffectiveCaps" in c and "BoundingCaps" in c and
              not (c.get("EffectiveCaps") or []) and not (c.get("BoundingCaps") or []))
drop_all="ALL" in dropped or (podman_drop and podman_empty)
mounts=c.get("Mounts") or []; binds=host.get("Binds") or []; volumes=cfg.get("Volumes") or {}
expected_health=["CMD-SHELL","grep -q '\''Bootstrapped 100%'\'' /var/log/tor/notices.log"]
if labels.get("io.basix.scrapling-tor.managed")!="true":
 raise SystemExit(1)
if host.get("Privileged") is not False or caps or not drop_all or ports or exposed or mounts or binds or volumes:
 raise SystemExit(1)
if not any("no-new-privileges" in str(x).lower() for x in security):
 raise SystemExit(1)
if nets!={"basix-tor-egress","basix-scrapling-internal"} or health.get("Test")!=expected_health:
 raise SystemExit(1)
actual=str(c.get("Image") or "").lower()
if len(actual)==64 and all(x in "0123456789abcdef" for x in actual): actual="sha256:"+actual
started=str(cfg.get("Image") or "").lower()
if len(started)==64 and all(x in "0123456789abcdef" for x in started): started="sha256:"+started
raise SystemExit(0 if actual==wanted and started==wanted else 10)
' "$TOR_IMAGE"
}

validate_tor() {
  classify_tor || { printf 'Refusing foreign or unsafe Tor container named %s.\n' "$TOR_CONTAINER" >&2; exit 7; }
}

ensure_tor() {
  ensure_network "$EGRESS_NET" false
  ensure_network "$INTERNAL_NET" true
  if container_json "$TOR_CONTAINER" >/dev/null 2>&1; then
    local classification=0
    classify_tor || classification=$?
    case $classification in
      0) "$RUNTIME" start "$TOR_CONTAINER" >/dev/null; return_after_create=false ;;
      10)
        printf 'Replacing safely managed Tor sidecar with canonical immutable image %s.\n' "$TOR_IMAGE" >&2
        "$RUNTIME" rm -f "$TOR_CONTAINER" >/dev/null || return 7
        return_after_create=true ;;
      *) printf 'Refusing foreign or unsafe Tor container named %s.\n' "$TOR_CONTAINER" >&2; return 7 ;;
    esac
  else
    return_after_create=true
  fi
  if [[ $return_after_create == true ]]; then
    "$RUNTIME" run -d --name "$TOR_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" \
      --network "$EGRESS_NET" --cap-drop ALL --security-opt no-new-privileges \
      --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
      --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 \
      "$TOR_IMAGE" >/dev/null
    created_container=true
    "$RUNTIME" network connect "$INTERNAL_NET" "$TOR_CONTAINER" >/dev/null
    validate_tor
  fi
  local health=''
  for _ in $(seq 1 48); do
    health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || true)
    [[ $health == healthy ]] && break
    [[ $health == unhealthy ]] && break
    sleep 2
  done
  if [[ $health != healthy ]]; then
    printf 'Tor sidecar did not reach 100%% bootstrap (health: %s).\n' "${health:-unknown}" >&2
    return 9
  fi
}

tor_ip() {
  "$RUNTIME" inspect --format "{{with index .NetworkSettings.Networks \"$INTERNAL_NET\"}}{{.IPAddress}}{{end}}" "$TOR_CONTAINER"
}

start_scrapling() {
  ensure_tor
  local ip; ip=$(tor_ip)
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Could not determine numeric Tor gateway IP.\n' >&2; exit 9; }
  exec "$RUNTIME" run -i --rm --label "$LABEL_KEY=$LABEL_VALUE" \
    --network "$INTERNAL_NET" --dns 127.0.0.1 --cap-drop ALL --security-opt no-new-privileges \
    -e "BASIX_TOR_IP=$ip" \
    -e "HTTP_PROXY=socks5h://$ip:9050" -e "HTTPS_PROXY=socks5h://$ip:9050" -e "ALL_PROXY=socks5h://$ip:9050" \
    -e "http_proxy=socks5h://$ip:9050" -e "https_proxy=socks5h://$ip:9050" -e "all_proxy=socks5h://$ip:9050" \
    -e 'NO_PROXY=' -e 'no_proxy=' \
    -v "$HERE/policy_mcp.py:/opt/basix/policy_mcp.py:ro" \
    --entrypoint /app/.venv/bin/python "$SCRAPLING_IMAGE" /opt/basix/policy_mcp.py
}

verify_tor() {
  local ip result
  ip=$(tor_ip)
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Could not determine numeric Tor gateway IP.\n' >&2; return 9; }
  result=$("$RUNTIME" run --rm --network "$INTERNAL_NET" --dns 127.0.0.1 \
    --cap-drop ALL --security-opt no-new-privileges --entrypoint /app/.venv/bin/python \
    "$SCRAPLING_IMAGE" -c "from scrapling.fetchers import Fetcher; print(Fetcher.get('https://check.torproject.org/api/ip',proxy='socks5h://$ip:9050').body.decode())" 2>/dev/null) || {
      printf 'Isolated Tor request failed.\n' >&2; return 9;
    }
  [[ ${result//[[:space:]]/} == *'"IsTor":true'* ]] || { printf 'Tor verification did not report IsTor=true.\n' >&2; return 9; }
}

verify_mcp() {
  python3 - "$HERE/launcher.sh" <<'PY'
import json, subprocess, sys
request=b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"basix-installer","version":"1"}}}\n'
try:
    completed=subprocess.run([sys.argv[1],"run"],input=request,stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE,timeout=30,check=False)
except subprocess.TimeoutExpired:
    print("MCP initialize handshake timed out.",file=sys.stderr); raise SystemExit(9)
for line in completed.stdout.splitlines():
    try: response=json.loads(line)
    except Exception: continue
    if response.get("jsonrpc")=="2.0" and response.get("id")==1 and isinstance(response.get("result"),dict):
        raise SystemExit(0)
print("MCP initialize handshake failed.",file=sys.stderr)
raise SystemExit(9)
PY
}

prepare() {
  ensure_tor
  verify_tor
  verify_mcp
}

case "${1:-run}" in
  prepare) prepare ;;
  tor-ip) ensure_tor; tor_ip ;;
  run) start_scrapling ;;
  *) printf 'Usage: %s [prepare|tor-ip|run]\n' "$0" >&2; exit 2 ;;
esac
