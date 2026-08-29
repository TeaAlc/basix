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

image=${SCRAPLING_RELEASE_IMAGE:-docker.io/pyd4vinci/scrapling:latest}
podman pull "$image" >/dev/null
pinned=$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$image")
podman run --rm --network none --entrypoint /app/.venv/bin/python "$pinned" -c '
import asyncio,inspect
from scrapling.core.ai import ScraplingMCPServer as S
s=S()
expected={"bulk_fetch","bulk_get","bulk_stealthy_fetch","close_session","fetch","list_sessions","make_request","open_request_session","open_session","screenshot","session_fetch","session_make_request","stealthy_fetch"}
actual={t.name for t in asyncio.run(s._build_server("127.0.0.1",8000).list_tools())}
assert actual==expected
required={"open_session":{"session_id","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"open_request_session":{"session_id","proxy"},"make_request":{"url","proxy","proxy_auth","auth","http3"},"bulk_get":{"urls","proxy","proxy_auth","auth","http3"},"session_make_request":{"url","session_id","auth","http3"},"fetch":{"url","proxy","cdp_url","real_chrome","executable_path"},"bulk_fetch":{"urls","proxy","cdp_url","real_chrome","executable_path"},"session_fetch":{"url","session_id"},"stealthy_fetch":{"url","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"bulk_stealthy_fetch":{"urls","proxy","cdp_url","real_chrome","executable_path","additional_args","block_webrtc"},"screenshot":{"url","session_id"},"close_session":{"session_id"}}
assert all(v <= set(inspect.signature(getattr(s,k)).parameters) for k,v in required.items())
assert {"allowed_hosts","allow_unauthenticated"} <= set(inspect.signature(s.serve).parameters)
'
podman build --format docker --label io.basix.scrapling-tor.managed=true -t localhost/basix-scrapling-tor:legacy "$ROOT/src/setup/scrapling-tor" >/dev/null
podman network create --driver bridge --label io.basix.scrapling-tor.managed=true basix-tor-egress >/dev/null
podman network create --driver bridge --internal --disable-dns --label io.basix.scrapling-tor.managed=true basix-scrapling-internal >/dev/null
podman run -d --name basix-scrapling-tor --label io.basix.scrapling-tor.managed=true \
  --network basix-tor-egress --cap-drop ALL --security-opt no-new-privileges \
  --health-cmd "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log" \
  --health-interval 5s --health-timeout 3s --health-start-period 10s --health-retries 24 \
  localhost/basix-scrapling-tor:legacy >/dev/null
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
cp "$ROOT/src/setup/scrapling-tor/policy_mcp.py" "$legacy_policy"
legacy_id=$(podman run -d -i --rm --name basix-scrapling-mcp --label io.basix.scrapling-tor.managed=true \
  --network basix-scrapling-internal --dns 127.0.0.1 --cap-drop ALL --security-opt no-new-privileges \
  -e "BASIX_TOR_IP=$tor_ip" -e "BASIX_PORT=$port" -e "HTTP_PROXY=socks5h://$tor_ip:9050" -e "HTTPS_PROXY=socks5h://$tor_ip:9050" -e "ALL_PROXY=socks5h://$tor_ip:9050" \
  -e "http_proxy=socks5h://$tor_ip:9050" -e "https_proxy=socks5h://$tor_ip:9050" -e "all_proxy=socks5h://$tor_ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
  -v "$legacy_policy:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$pinned" /opt/basix/policy_mcp.py)
codex mcp add scrapling -- /bin/false

"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --port "$port" --force
if podman container exists "$legacy_id"; then
  printf 'validated legacy container still exists after migration\n' >&2
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
podman exec basix-scrapling-mcp /app/.venv/bin/python -c '
import socket
socket.getaddrinfo("basix-tor-proxy",9050)
s=socket.socket(); s.settimeout(2)
if s.connect_ex(("1.1.1.1",443)) == 0: raise SystemExit("direct egress unexpectedly connected")
s=socket.create_connection(("basix-tor-proxy",9050),2); s.close()
'
PYTHONDONTWRITEBYTECODE=1 python3 "$CODEX_HOME/basix/scrapling-tor/health_check.py" "http://127.0.0.1:$port/mcp"
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
PYTHONDONTWRITEBYTECODE=1 python3 "$CODEX_HOME/basix/scrapling-tor/health_check.py" "http://127.0.0.1:$port/mcp"
codex mcp list --json | PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/setup/scrapling-tor/codex_scan.py" verify --endpoint "http://127.0.0.1:$port/mcp"
printf 'Isolated Podman Scrapling release gate passed.\n'
