#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
command -v podman >/dev/null || { printf 'podman is required\n' >&2; exit 3; }
command -v codex >/dev/null || { printf 'codex is required\n' >&2; exit 3; }

gate=$(mktemp -d "${TMPDIR:-/tmp}/basix-scrapling-release.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -x $gate/bin/podman ]]; then "$gate/bin/podman" rm -af >/dev/null 2>&1 || true; fi
  chmod -R u+w "$gate" >/dev/null 2>&1 || true
  rm -rf "$gate"
  exit "$status"
}
trap cleanup EXIT INT TERM
mkdir -p "$gate/bin" "$gate/graph" "$gate/run" "$gate/home" "$gate/codex"

real_podman=$(command -v podman)
sed -e "s|@PODMAN@|$real_podman|" -e "s|@GRAPH@|$gate/graph|" -e "s|@RUNROOT@|$gate/run|" >"$gate/bin/podman" <<'WRAPPER'
#!/usr/bin/env bash
exec @PODMAN@ --root @GRAPH@ --runroot @RUNROOT@ --storage-driver overlay "$@"
WRAPPER
chmod 755 "$gate/bin/podman"
export PATH="$gate/bin:$PATH" HOME="$gate/home" CODEX_HOME="$gate/codex"

port=$(PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import socket

with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)

# Parameters: $1 MCP endpoint. Verify the application route and bounded direct
# TCP/UDP isolation; managed-alias DNS metadata remains permitted by ADR 0007.
verify_traffic_boundary() {
  podman exec basix-scrapling-mcp /app/.venv/bin/python -c '
import os,socket
socket.getaddrinfo("basix-tor-proxy",9050)
with socket.create_connection(("basix-tor-proxy",9050),2) as proxy:
    proxy.sendall(b"\x05\x01\x00")
    with proxy.makefile("rb") as reply:
        if reply.read(2) != b"\x05\x00": raise SystemExit("managed Tor SOCKS negotiation failed")
with socket.socket() as direct:
    direct.settimeout(2)
    try: connected=direct.connect_ex(("1.1.1.1",443)) == 0
    except OSError: connected=False
    if connected: raise SystemExit("direct TCP egress unexpectedly connected")
# UDP connect/send success does not demonstrate egress. Only an actual DNS
# response fails this check; timeout or an unreachable route has no reply.
query=os.urandom(2)+b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x07invalid\x00\x00\x01\x00\x01"
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as direct:
    direct.settimeout(2)
    try:
        direct.connect(("1.1.1.1",53))
        direct.send(query)
        direct.recv(512)
    except OSError: pass
    else: raise SystemExit("direct UDP DNS egress unexpectedly received a reply")
print("Managed Tor alias/SOCKS reachable; direct TCP blocked; direct UDP DNS has no reply.")
'
  PYTHONDONTWRITEBYTECODE=1 python3 "$CODEX_HOME/basix/scrapling-tor/health_check.py" "$1"
}

image=${SCRAPLING_RELEASE_IMAGE:-docker.io/pyd4vinci/scrapling:latest}
podman pull "$image" >/dev/null
pinned=$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$image")
printf 'Scrapling immutable image: %s\n' "$pinned"
podman run --rm --network none -v "$ROOT/src/setup/scrapling-tor:/opt/basix:ro" --entrypoint /app/.venv/bin/python "$pinned" -c '
import sys,importlib.metadata
sys.path.insert(0,"/opt/basix")
from policy_mcp import ScraplingMCPServer,assert_upstream_tools
print("Scrapling package version:",importlib.metadata.version("scrapling"), "MCP SDK:", importlib.metadata.version("mcp"))
s=ScraplingMCPServer()
assert_upstream_tools(s)
import inspect
assert {"allowed_hosts","allow_unauthenticated"} <= set(inspect.signature(s.serve).parameters)
'
# Prove a clean install before exercising removal of owned retired resources.
"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --port "$port" --force
verify_traffic_boundary "http://127.0.0.1:$port/mcp"
clean_scrapling_id=$(podman inspect --format '{{.Id}}' basix-scrapling-mcp)
clean_tor_id=$(podman inspect --format '{{.Id}}' basix-scrapling-tor)
podman rm -f "$clean_scrapling_id" "$clean_tor_id" >/dev/null
podman network rm basix-scrapling-internal basix-tor-egress >/dev/null
podman build --format docker --label io.basix.scrapling-tor.managed=true -t localhost/basix-scrapling-tor:legacy "$ROOT/src/setup/scrapling-tor" >/dev/null
podman network create --driver bridge --label io.basix.scrapling-tor.managed=true basix-tor-egress >/dev/null
podman network create --driver bridge --internal --disable-dns --label io.basix.scrapling-tor.managed=true basix-scrapling-internal >/dev/null
podman run -d --name basix-scrapling-tor --label io.basix.scrapling-tor.managed=true \
  --network basix-tor-egress --cap-drop ALL --security-opt no-new-privileges \
  --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
  --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 \
  --entrypoint tor localhost/basix-scrapling-tor:legacy -f /etc/tor/torrc >/dev/null
podman network connect basix-scrapling-internal basix-scrapling-tor

tor_bootstrap=false
for _ in $(seq 1 120); do
  state=$(podman inspect --format '{{.State.Status}}' basix-scrapling-tor 2>/dev/null || true)
  if [[ $state == running ]] && podman exec basix-scrapling-tor grep -q 'Bootstrapped 100%' /var/log/tor/notices.log; then
    tor_bootstrap=true
    break
  fi
  [[ $state == exited || $state == stopped || $state == dead ]] && break
  sleep 2
done
if ! $tor_bootstrap; then
  health=$(podman inspect --format '{{.State.Health.Status}}' basix-scrapling-tor 2>/dev/null || true)
  state=$(podman inspect --format '{{.State.Status}}' basix-scrapling-tor 2>/dev/null || true)
  printf 'legacy Tor bootstrap failed: state=%s runtime-health=%s direct-notice-check=failed\n' "${state:-unknown}" "${health:-unknown}" >&2
  podman logs basix-scrapling-tor >&2 || true
  podman exec basix-scrapling-tor sh -c 'tail -n 200 /var/log/tor/notices.log' >&2 || true
  exit 9
fi
tor_ip=$(podman inspect --format '{{with index .NetworkSettings.Networks "basix-scrapling-internal"}}{{.IPAddress}}{{end}}' basix-scrapling-tor)
legacy_policy="$CODEX_HOME/basix/scrapling-tor/policy_mcp.py"
mkdir -p "${legacy_policy%/*}"
# Model an owned retired extraction-only resource; it must be removed.
sed '/    configure_acquisition(server, policy.monitor)/d' "$ROOT/src/setup/scrapling-tor/policy_mcp.py" >"$legacy_policy"
legacy_id=$(podman run -d -i --rm --name basix-scrapling-legacy-stdio --label io.basix.scrapling-tor.managed=true \
  --network basix-scrapling-internal --dns 127.0.0.1 --cap-drop ALL --security-opt no-new-privileges \
  -e "BASIX_TOR_IP=$tor_ip" -e "BASIX_PORT=$port" -e "HTTP_PROXY=socks5h://$tor_ip:9050" -e "HTTPS_PROXY=socks5h://$tor_ip:9050" -e "ALL_PROXY=socks5h://$tor_ip:9050" \
  -e "http_proxy=socks5h://$tor_ip:9050" -e "https_proxy=socks5h://$tor_ip:9050" -e "all_proxy=socks5h://$tor_ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
  -v "$legacy_policy:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$pinned" /opt/basix/policy_mcp.py)
legacy_http_id=$(podman run -d -i --name basix-scrapling-mcp --label io.basix.scrapling-tor.managed=true \
  --network basix-scrapling-internal --dns 127.0.0.1 --cap-drop ALL --security-opt no-new-privileges \
  -p "127.0.0.1:$port:$port" \
  -e "BASIX_TOR_IP=$tor_ip" -e "BASIX_PORT=$port" -e "HTTP_PROXY=socks5h://$tor_ip:9050" -e "HTTPS_PROXY=socks5h://$tor_ip:9050" -e "ALL_PROXY=socks5h://$tor_ip:9050" \
  -e "http_proxy=socks5h://$tor_ip:9050" -e "https_proxy=socks5h://$tor_ip:9050" -e "all_proxy=socks5h://$tor_ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
  -v "$legacy_policy:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$pinned" /opt/basix/policy_mcp.py)
printf 'Legacy fixture Tor restart policy: %s\n' "$(podman inspect --format '{{json .HostConfig.RestartPolicy}}' basix-scrapling-tor)"

"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --port "$port" --force
if podman container exists "$legacy_id" || podman container exists "$legacy_http_id"; then
  printf 'owned retired container still exists after replacement\n' >&2
  exit 9
fi
podman inspect basix-scrapling-mcp | PYTHONDONTWRITEBYTECODE=1 python3 \
  "$ROOT/src/setup/scrapling-tor/container_policy.py" managed scrapling \
  --configured "$pinned" --actual "$(podman image inspect --format '{{.Id}}' "$pinned")" \
  --port "$port" --policy "$CODEX_HOME/basix/scrapling-tor/policy_mcp.py"
[[ $(podman inspect --format '{{json .NetworkSettings.Networks}}' basix-scrapling-mcp) == *basix-scrapling-internal* ]]
[[ $(podman port basix-scrapling-mcp "$port/tcp") == "127.0.0.1:$port" ]]
podman network inspect basix-scrapling-internal | PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
assert bool(n.get("Internal",n.get("internal",False))) is True
assert n.get("DNSEnabled",n.get("dns_enabled",True)) is not False
assert not (n.get("NetworkDNSServers",n.get("DNSServers",n.get("dns_servers",[]))) or [])
assert not bool(n.get("EnableIPv6",n.get("IPv6Enabled",n.get("ipv6_enabled",False))))
assert (n.get("Labels",n.get("labels",{})) or {}).get("io.basix.scrapling-tor.managed") == "true"
'
verify_traffic_boundary "http://127.0.0.1:$port/mcp"
"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --port "$port" --force
scrapling_id=$(podman inspect --format '{{.Id}}' basix-scrapling-mcp)
scrapling_started=$(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-mcp)
old_tor_ip=$(podman inspect --format '{{with index .NetworkSettings.Networks "basix-scrapling-internal"}}{{.IPAddress}}{{end}}' basix-scrapling-tor)
podman rm -f basix-scrapling-tor >/dev/null
podman run -d --name basix-ip-holder --network basix-scrapling-internal \
  --cap-drop ALL --security-opt no-new-privileges --entrypoint /bin/sh docker.io/library/debian:bookworm-slim -c 'sleep 300' >/dev/null
"$CODEX_HOME/basix/scrapling-tor/launcher.sh" start
new_tor_ip=$(podman inspect --format '{{with index .NetworkSettings.Networks "basix-scrapling-internal"}}{{.IPAddress}}{{end}}' basix-scrapling-tor)
[[ $new_tor_ip != "$old_tor_ip" ]] || { printf 'Tor IP did not change during drift gate\n' >&2; exit 9; }
[[ $(podman inspect --format '{{.Id}}' basix-scrapling-mcp) == "$scrapling_id" ]]
[[ $(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-mcp) == "$scrapling_started" ]]
podman rm -f basix-ip-holder >/dev/null
verify_traffic_boundary "http://127.0.0.1:$port/mcp"

# Exercise actual child failure and a stopped event loop without host health timers.
# Parameters: $1 container name; $2 Python executable; $3 child argv marker;
# $4 signal number. Print the exact signalled PID for later replacement checks.
# Exclude PID 1: the supervisor command also contains its service marker.
signal_managed_child() {
  podman exec "$1" "$2" -c '
import os,pathlib,signal,sys
marker,number=sys.argv[1],int(sys.argv[2])
matches=[]
for item in pathlib.Path("/proc").iterdir():
    if not item.name.isdigit() or int(item.name) in (1,os.getpid()): continue
    try: argv=(item/"cmdline").read_bytes().split(b"\0")
    except (FileNotFoundError,ProcessLookupError,PermissionError): continue
    if marker.encode() in argv: matches.append(int(item.name))
if len(matches)!=1: raise SystemExit(f"expected one managed child, got {matches}")
os.kill(matches[0],number)
print(matches[0])
' "$3" "$4"
}

tor_started=$(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-tor)
signal_managed_child basix-scrapling-tor python3 tor 9 >/dev/null
recovered=false
for _ in $(seq 1 180); do
  if [[ $(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-tor) != "$tor_started" ]] && \
    podman exec basix-scrapling-tor python3 /opt/basix/service_supervisor.py --probe tor >/dev/null 2>&1; then
    recovered=true; break
  fi
  sleep 2
done
if ! $recovered; then podman logs --tail 100 basix-scrapling-tor >&2; printf 'Tor child-exit recovery failed\n' >&2; exit 9; fi
verify_traffic_boundary "http://127.0.0.1:$port/mcp"

mcp_started=$(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-mcp)
stopped_pid=$(signal_managed_child basix-scrapling-mcp /app/.venv/bin/python /opt/basix/policy_mcp.py 19)
recovered=false
for _ in $(seq 1 120); do
  if podman logs basix-scrapling-mcp 2>&1 | grep -F 'restarting mcp after cooldown=' >/dev/null && \
    podman exec basix-scrapling-mcp /app/.venv/bin/python /opt/basix/service_supervisor.py --probe mcp >/dev/null 2>&1; then
    recovered=true; break
  fi
  sleep 2
done
if ! $recovered; then podman logs --tail 100 basix-scrapling-mcp >&2; printf 'MCP hung-child recovery failed\n' >&2; exit 9; fi
[[ $(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-mcp) == "$mcp_started" ]]
podman exec basix-scrapling-mcp /app/.venv/bin/python -c 'import os,sys; assert not os.path.exists("/proc/"+sys.argv[1])' "$stopped_pid"
verify_traffic_boundary "http://127.0.0.1:$port/mcp"
# Exercise the same private local signal used for irreversible policy degradation.
policy_pid=$(signal_managed_child basix-scrapling-mcp /app/.venv/bin/python /opt/basix/policy_mcp.py 0)
podman exec basix-scrapling-mcp /app/.venv/bin/python -c 'import os,signal;os.kill(1,signal.SIGUSR1)'
recovered=false
for _ in $(seq 1 75); do
  if podman exec basix-scrapling-mcp /app/.venv/bin/python -c 'import os,sys;assert not os.path.exists("/proc/"+sys.argv[1])' "$policy_pid" >/dev/null 2>&1 && \
    podman exec basix-scrapling-mcp /app/.venv/bin/python /opt/basix/service_supervisor.py --probe mcp >/dev/null 2>&1; then
    recovered=true; break
  fi
  sleep 2
done
if ! $recovered; then podman logs --tail 100 basix-scrapling-mcp >&2; printf 'Policy degradation recovery failed\n' >&2; exit 9; fi
[[ $(podman inspect --format '{{.State.StartedAt}}' basix-scrapling-mcp) == "$mcp_started" ]]
printf 'Irreversible policy health signal recovered through bounded child supervision.\n'
verify_traffic_boundary "http://127.0.0.1:$port/mcp"
codex mcp list --json | PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/setup/scrapling-tor/codex_scan.py" verify --endpoint "http://127.0.0.1:$port/mcp"
# Benign runtime smoke; this is not a tester-controlled DNS/observer fixture.
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" "http://127.0.0.1:$port/mcp" "$CODEX_HOME" <<'PYLIVE'
import hashlib,importlib.util,json,pathlib,sys,time
root,endpoint,home=sys.argv[1:]
spec=importlib.util.spec_from_file_location("health",pathlib.Path(root)/"src/setup/scrapling-tor/health_check.py")
health=importlib.util.module_from_spec(spec);spec.loader.exec_module(health)
client=health.MCPClient(endpoint)
client.send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"binary-release","version":"1"}}})
client.send({"jsonrpc":"2.0","method":"notifications/initialized"},expect_response=False)
schemas=client.send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
health.validate_tool_inventory(endpoint,schemas)
print("Runtime schema snapshot:",json.dumps(schemas["result"],sort_keys=True))
def call(name,**arguments):
    """Call owned tool. :param name: Tool. :param arguments: Nonsecret arguments."""
    arguments["client_id"]=client.client_id
    result=client.send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":name,"arguments":arguments}})
    payload=result["result"]
    assert not payload.get("isError"),"MCP tool rejected release call"
    return json.loads(payload["content"][0]["text"])
job=call("download_start",url="https://example.com/",maximum_bytes=1048576,time_budget=60,idempotency_key="release-smoke")
assert job["state"]=="running",job
for _ in range(120):
    job=call("download_status",job_id=job["job_id"])
    if job["state"]!="running":break
    time.sleep(.5)
assert job["state"]=="completed",job
export=call("artifact_export",artifact_id=job["artifact_id"])
body=(pathlib.Path(home)/"basix/scrapling-artifacts/export"/export["filename"]).read_bytes()
assert len(body)==export["length"] and hashlib.sha256(body).hexdigest()==export["sha256"]
print("Neutral HTTPS binary runtime smoke:",json.dumps({"length":len(body),"sha256":export["sha256"],"policy":job["policy"]},sort_keys=True))
PYLIVE
# Verify the actual Tor addressmap and SafeSocks numeric path, not only doubles.
podman exec -i basix-scrapling-tor python3 - <<'PYGATEWAY'
import asyncio,sys,socket
from pathlib import Path
sys.path.insert(0,"/opt/basix")
from pinning_gateway import Gateway

def mappings():
    """Read trusted Tor-local control mappings without exposing its credential."""
    with socket.create_connection(("127.0.0.1",9051),2) as control:
        stream=control.makefile("rb")
        control.sendall(b"AUTHENTICATE "+Path("/var/lib/tor/control_auth_cookie").read_bytes().hex().encode()+b"\r\n")
        assert stream.readline()==b"250 OK\r\n"
        control.sendall(b"GETINFO address-mappings/control\r\n")
        lines=[]
        for _ in range(32):
            line=stream.readline()
            if line==b"250 OK\r\n":return b"".join(lines)
            assert line and not line.startswith((b"4",b"5")),"mapping query rejected"
            lines.append(line)
        raise AssertionError("mapping query exceeded bound")

async def verify():
    """Share a live map, perform numeric SafeSocks CONNECT, then prove unmapping."""
    gateway=Gateway()
    first,second=await asyncio.gather(gateway.acquire("1.1.1.1"),gateway.acquire("1.1.1.1"))
    assert first==second and len(gateway.mappings)==1
    assert first.encode() in mappings()
    try:
        reader,writer=await asyncio.wait_for(gateway.tor_connect(first,443),30)
        writer.close()
        await writer.wait_closed()
    finally:
        await gateway.release("1.1.1.1")
        assert first.encode() in mappings(),"mapping removed while referenced"
        await gateway.release("1.1.1.1")
    assert first.encode() not in mappings(),"unused mapping retained"
    assert not gateway.mappings
    print("Live Tor SafeSocks numeric CONNECT, shared mapping and final cleanup verified.")
asyncio.run(verify())
PYGATEWAY
podman exec basix-scrapling-mcp /app/.venv/bin/python -c '
import socket,os
assert not os.path.exists("/var/lib/tor/control_auth_cookie")
with socket.socket() as control:
    control.settimeout(2)
    try: result=control.connect_ex(("basix-tor-proxy",9051))
    except OSError: result=1
    assert result!=0,"Tor control exposed to worker"
print("Worker cannot reach control port or read control cookie.")
'
egress_address=$(podman inspect --format '{{with index .NetworkSettings.Networks "basix-tor-egress"}}{{.IPAddress}}{{end}}' basix-scrapling-tor)
internal_address=$(podman inspect --format '{{with index .NetworkSettings.Networks "basix-scrapling-internal"}}{{.IPAddress}}{{end}}' basix-scrapling-tor)
podman run --rm --network basix-tor-egress --cap-drop ALL --security-opt no-new-privileges --entrypoint /app/.venv/bin/python "$pinned" -c '
import socket,sys,ipaddress
assert len(sys.argv)==3 and len(set(sys.argv[1:]))==2
assert all(ipaddress.ip_address(address).is_private for address in sys.argv[1:])
for address in sys.argv[1:]:
    try:
        with socket.create_connection((address,9052),2) as peer:
            peer.settimeout(2)
            peer.sendall(b"\x05\x01\x00")
            assert peer.recv(2) != b"\x05\x00", "egress peer reached pinning gateway"
    except OSError: pass
print("Unrelated egress peer cannot negotiate numeric gateway on either Tor address.")
' "$egress_address" "$internal_address"
printf 'Isolated Podman Scrapling release gate passed.\n'
