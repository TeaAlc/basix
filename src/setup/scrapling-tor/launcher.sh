#!/usr/bin/env bash
set -Eeuo pipefail

readonly LABEL_KEY='io.basix.scrapling-tor.managed' LABEL_VALUE='true'
readonly INTERNAL_NET='basix-scrapling-internal' EGRESS_NET='basix-tor-egress'
readonly TOR_CONTAINER='basix-scrapling-tor' SCRAPLING_CONTAINER='basix-scrapling-mcp'
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); readonly HERE
[[ -r $HERE/config ]] || { printf 'Basix Scrapling configuration is missing; rerun the installer.\n' >&2; exit 3; }
# shellcheck source=/dev/null
source "$HERE/config"
: "${RUNTIME:?}" "${SCRAPLING_IMAGE:?}" "${SCRAPLING_ID:?}" "${TOR_IMAGE:?}" "${PORT:?}"
readonly ENDPOINT="http://127.0.0.1:$PORT/mcp"

created_internal=false created_egress=false created_tor=false created_scrapling=false
rollback() {
  local status=$?; trap - ERR
  if $created_scrapling; then "$RUNTIME" rm -f "$SCRAPLING_CONTAINER" >/dev/null 2>&1 || true; fi
  if $created_tor; then "$RUNTIME" rm -f "$TOR_CONTAINER" >/dev/null 2>&1 || true; fi
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

classify_container() {
  local name=$1 kind=$2 configured_image=$3 actual_image=$4 tor_address=${5-} policy_path=${6-}
  container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
c=json.load(sys.stdin)[0]; kind,wanted_started,wanted_actual,port,tor_ip,policy_path=sys.argv[1:]
cfg=c.get("Config") or {}; host=c.get("HostConfig") or {}; labels=cfg.get("Labels") or {}
nets=set(((c.get("NetworkSettings") or {}).get("Networks") or {})); expected={"basix-tor-egress","basix-scrapling-internal"} if kind=="tor" else {"basix-scrapling-internal"}
caps=host.get("CapAdd") or []; drops={str(x).upper().removeprefix("CAP_") for x in host.get("CapDrop") or []}
create=cfg.get("CreateCommand") or []; podman_drop=any(x=="--cap-drop=ALL" for x in create) or any(create[i]=="--cap-drop" and create[i+1]=="ALL" for i in range(len(create)-1))
podman_empty="EffectiveCaps" in c and "BoundingCaps" in c and not(c.get("EffectiveCaps") or []) and not(c.get("BoundingCaps") or [])
ports=host.get("PortBindings") or {}; wanted_ports={} if kind=="tor" else {port+"/tcp":[{"HostIp":"127.0.0.1","HostPort":port}]}
mounts=c.get("Mounts") or []; security=host.get("SecurityOpt") or []
if labels.get("io.basix.scrapling-tor.managed")!="true" or host.get("Privileged") is not False or caps or not("ALL" in drops or (podman_drop and podman_empty)): raise SystemExit(1)
if not any("no-new-privileges" in str(x).lower() for x in security) or nets!=expected or ports!=wanted_ports: raise SystemExit(1)
if kind=="tor" and mounts: raise SystemExit(1)
restart=(host.get("RestartPolicy") or {}).get("Name")
if restart!="unless-stopped": raise SystemExit(1)
if kind=="tor":
 health=cfg.get("Healthcheck") or {}
 expected_health="grep -q "+chr(39)+"Bootstrapped 100%"+chr(39)+" /var/log/tor/notices.log"
 if health.get("Test") != ["CMD-SHELL",expected_health]: raise SystemExit(1)
if kind=="scrapling":
 if len(mounts)!=1 or mounts[0].get("Destination")!="/opt/basix/policy_mcp.py" or mounts[0].get("RW") is not False or mounts[0].get("Source")!=policy_path: raise SystemExit(1)
 env=dict(item.split("=",1) for item in (cfg.get("Env") or []) if "=" in item)
 required={"BASIX_TOR_IP":tor_ip,"BASIX_PORT":port,"NO_PROXY":"","no_proxy":""}
 if any(env.get(k)!=v for k,v in required.items()): raise SystemExit(1)
 for key in ("HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"):
  if env.get(key)!=f"socks5h://{tor_ip}:9050": raise SystemExit(1)
 entrypoint=cfg.get("Entrypoint") or []; command=cfg.get("Cmd") or []
 if entrypoint != ["/app/.venv/bin/python"] or command != ["/opt/basix/policy_mcp.py"]: raise SystemExit(1)
actual=str(c.get("Image") or "").lower(); started=str(cfg.get("Image") or "").lower()
if len(actual)==64: actual="sha256:"+actual
if len(started)==64: started="sha256:"+started
raise SystemExit(0 if actual==wanted_actual.lower() and started==wanted_started.lower() else 10)
' "$kind" "$configured_image" "$actual_image" "$PORT" "$tor_address" "$policy_path"
}

ensure_tor() {
  ensure_network "$EGRESS_NET" false; ensure_network "$INTERNAL_NET" true
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
    "$RUNTIME" run -d --name "$TOR_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$EGRESS_NET" --cap-drop ALL --security-opt no-new-privileges \
      --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
      --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 "$TOR_IMAGE" >/dev/null
    created_tor=true; "$RUNTIME" network connect "$INTERNAL_NET" "$TOR_CONTAINER" >/dev/null
    classify_container "$TOR_CONTAINER" tor "$TOR_IMAGE" "$TOR_IMAGE"
  fi
  local health=''
  for _ in $(seq 1 48); do health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || true); [[ $health == healthy || $health == unhealthy ]] && break; sleep 2; done
  [[ $health == healthy ]] || { printf 'Tor sidecar did not reach 100%% bootstrap (health: %s).\n' "${health:-unknown}" >&2; return 9; }
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

reject_foreign_scrapling() {
  local name
  while IFS= read -r name; do
    [[ -n $name && $name != "$TOR_CONTAINER" && $name != "$SCRAPLING_CONTAINER" ]] || continue
    if container_json "$name" | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
c=json.load(sys.stdin)[0]; cfg=c.get("Config") or {}
image=str(cfg.get("Image") or "").lower(); command=" ".join(str(x) for x in ((cfg.get("Entrypoint") or [])+(cfg.get("Cmd") or []))).lower()
wanted=sys.argv[1].lower()
raise SystemExit(0 if image==wanted or "policy_mcp.py" in command or "scrapling" in command else 1)
' "$SCRAPLING_IMAGE"; then
      printf 'Refusing foreign running Scrapling container named %s.\n' "$name" >&2
      return 7
    fi
  done < <("$RUNTIME" ps --format '{{.Names}}')
}

ensure_scrapling() {
  ensure_tor
  local ip create=true classification=0; ip=$(tor_ip)
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Could not determine numeric Tor gateway IP.\n' >&2; return 9; }
  reject_foreign_scrapling
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
    "$RUNTIME" run -d --name "$SCRAPLING_CONTAINER" --label "$LABEL_KEY=$LABEL_VALUE" --restart unless-stopped \
      --network "$INTERNAL_NET" "${dns[@]}" --cap-drop ALL --security-opt no-new-privileges -p "127.0.0.1:$PORT:$PORT" \
      -e "BASIX_TOR_IP=$ip" -e "BASIX_PORT=$PORT" -e "HTTP_PROXY=socks5h://$ip:9050" -e "HTTPS_PROXY=socks5h://$ip:9050" -e "ALL_PROXY=socks5h://$ip:9050" \
      -e "http_proxy=socks5h://$ip:9050" -e "https_proxy=socks5h://$ip:9050" -e "all_proxy=socks5h://$ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
      -v "$HERE/policy_mcp.py:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$SCRAPLING_IMAGE" /opt/basix/policy_mcp.py >/dev/null
    created_scrapling=true; classify_container "$SCRAPLING_CONTAINER" scrapling "$SCRAPLING_IMAGE" "$SCRAPLING_ID" "$ip" "$HERE/policy_mcp.py"
  fi
}

verify_mcp() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/health_check.py" "$ENDPOINT"
}

prepare() { ensure_scrapling; verify_mcp; }
start() { ensure_scrapling; verify_mcp; }
stop() { "$RUNTIME" stop "$SCRAPLING_CONTAINER" "$TOR_CONTAINER" >/dev/null; }
status() {
  local tor_health scrapling_state registration
  tor_health=$("$RUNTIME" inspect --format '{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || printf absent)
  scrapling_state=$("$RUNTIME" inspect --format '{{.State.Status}}' "$SCRAPLING_CONTAINER" 2>/dev/null || printf absent)
  if command -v codex >/dev/null 2>&1 && codex mcp list --json 2>/dev/null | PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/codex_scan.py" verify --endpoint "$ENDPOINT" >/dev/null 2>&1; then registration=canonical; else registration=missing-or-different; fi
  printf 'Tor health: %s\nScrapling state: %s\nEndpoint: %s\nCodex registration: %s\n' "$tor_health" "$scrapling_state" "$ENDPOINT" "$registration"
}

case "${1:-status}" in
  prepare) prepare ;; start) start ;; stop) stop ;; status) status ;; tor-ip) ensure_tor; tor_ip ;;
  *) printf 'Usage: %s [prepare|start|stop|status|tor-ip]\n' "$0" >&2; exit 2 ;;
esac
