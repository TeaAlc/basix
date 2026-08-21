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

image=${SCRAPLING_RELEASE_IMAGE:-docker.io/pyd4vinci/scrapling:latest}
podman pull "$image" >/dev/null
pinned=$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$image")
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
legacy_id=$(podman run -d -i --rm --label io.basix.scrapling-tor.managed=true \
  --network basix-scrapling-internal --dns 127.0.0.1 --cap-drop ALL --security-opt no-new-privileges \
  -e "BASIX_TOR_IP=$tor_ip" -e "HTTP_PROXY=socks5h://$tor_ip:9050" -e "HTTPS_PROXY=socks5h://$tor_ip:9050" -e "ALL_PROXY=socks5h://$tor_ip:9050" \
  -e "http_proxy=socks5h://$tor_ip:9050" -e "https_proxy=socks5h://$tor_ip:9050" -e "all_proxy=socks5h://$tor_ip:9050" -e 'NO_PROXY=' -e 'no_proxy=' \
  -v "$legacy_policy:/opt/basix/policy_mcp.py:ro" --entrypoint /app/.venv/bin/python "$pinned" /opt/basix/policy_mcp.py)
codex mcp add scrapling -- /bin/false

"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --force
if podman container exists "$legacy_id"; then
  printf 'validated legacy container still exists after migration\n' >&2
  exit 9
fi
podman inspect basix-scrapling-mcp | PYTHONDONTWRITEBYTECODE=1 python3 \
  "$ROOT/src/setup/scrapling-tor/container_policy.py" managed scrapling \
  --configured "$pinned" --actual "$(podman image inspect --format '{{.Id}}' "$pinned")" \
  --port 8002 --policy "$CODEX_HOME/basix/scrapling-tor/policy_mcp.py"
[[ $(podman inspect --format '{{json .NetworkSettings.Networks}}' basix-scrapling-mcp) == *basix-scrapling-internal* ]]
[[ $(podman port basix-scrapling-mcp 8002/tcp) == '127.0.0.1:8002' ]]
PYTHONDONTWRITEBYTECODE=1 python3 "$CODEX_HOME/basix/scrapling-tor/health_check.py" http://127.0.0.1:8002/mcp
"$ROOT/src/setup/install-scrapling-codex.sh" --runtime podman --image "$pinned" --force
codex mcp list --json | PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/setup/scrapling-tor/codex_scan.py" verify --endpoint http://127.0.0.1:8002/mcp
printf 'Isolated Podman Scrapling release gate passed.\n'
