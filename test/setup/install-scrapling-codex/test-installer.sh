#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
passes=0 failures=0

make_mocks() {
  case_dir=$(mktemp -d); mkdir -p "$case_dir/bin" "$case_dir/home/codex"; log=$case_dir/log; : >"$log"
  printf '%s\n' "${MOCK_LIST:-[]}" >"$case_dir/list.json"
  cat >"$case_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >>"$MOCK_LOG"
case "$*" in
  'mcp --help') printf 'Commands: add list remove\n' ;;
  'mcp list --help') printf 'Options: --json\n' ;;
  'mcp list --json')
    count=0; [[ ! -f $MOCK_ROOT/count ]] || count=$(<"$MOCK_ROOT/count"); ((count+=1)); printf %s "$count" >"$MOCK_ROOT/count"
    if [[ ${MOCK_RACE:-false} == true && $count -ge 2 ]]; then printf '[{"name":"scrapling","transport":{"type":"stdio","command":"changed","args":[]}}]\n'
    else command cp "$MOCK_ROOT/list.json" /dev/stdout; fi ;;
  mcp\ remove\ *) [[ ${MOCK_REMOVE:-ok} == ok ]] || exit 1; printf '[]\n' >"$MOCK_ROOT/list.json" ;;
  'mcp add scrapling --url '* )
    [[ ${MOCK_ADD:-ok} == ok ]] || exit 1; url=$5
    printf '[{"name":"scrapling","enabled":true,"transport":{"type":"http","url":"%s"}}]\n' "$url" >"$MOCK_ROOT/list.json" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$case_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"$MOCK_LOG"
if [[ ${1-} == */health_check.py ]]; then
  [[ ${MOCK_HANDSHAKE:-ok} == ok ]] || { printf 'MCP HTTP, schema, or Tor verification failed: handshake\n' >&2; exit 9; }
  [[ ${MOCK_ISTOR:-true} == true ]] || { printf 'MCP HTTP, schema, or Tor verification failed: IsTor=true required\n' >&2; exit 9; }
  exit 0
fi
if [[ ${1-} == - && ${2-} =~ ^[0-9]+$ ]]; then exit 0; fi
exec /usr/bin/python3 "$@"
EOF
  cat >"$case_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$case_dir/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$MOCK_LOG"
case "${1-}" in
  info) [[ ${MOCK_INFO:-ok} == ok ]] ;;
  ps) [[ ${MOCK_FOREIGN:-false} == true ]] && printf 'foreign-scrapling\n' || true ;;
  pull|build) [[ ${MOCK_RUNTIME:-ok} == ok ]] ;;
  image)
    if [[ $* == *basix-scrapling-tor* ]]; then printf '%064d\n' 2
    elif [[ ${4-} == '{{.Id}}' ]]; then printf 'sha256:%064d\n' 1
    else printf 'docker.io/pyd4vinci/scrapling@sha256:%064d\n' 1; fi ;;
  network)
    case ${2-} in
      inspect) name=${*: -1}; [[ -f $MOCK_ROOT/net-$name ]] || exit 1; internal=false; [[ $name == basix-scrapling-internal ]] && internal=true; printf '[{"Driver":"bridge","Internal":%s,"EnableIPv6":false,"Labels":{"io.basix.scrapling-tor.managed":"%s"}}]\n' "$internal" "${MOCK_OWNER:-true}" ;;
      create) name=${*: -1}; : >"$MOCK_ROOT/net-$name" ;;
      connect) : ;;
      rm) rm -f "$MOCK_ROOT/net-${*: -1}" ;;
    esac ;;
  inspect)
    name=${*: -1}
    if [[ $* == *--format* ]]; then
      if [[ $* == *Health.Status* ]]; then printf '%s\n' "${MOCK_HEALTH:-healthy}"
      elif [[ $* == *State.Status* ]]; then printf 'running\n'
      else printf '10.89.1.2\n'; fi
      exit 0
    fi
    if [[ $name == foreign-scrapling ]]; then
      printf '[{"Config":{"Image":"docker.io/pyd4vinci/scrapling@sha256:%064d","Entrypoint":["python"],"Cmd":["policy_mcp.py"]}}]\n' 1
      exit 0
    fi
    [[ -f $MOCK_ROOT/container-$name ]] || exit 1
    tor=0; [[ $name == basix-scrapling-tor ]] && tor=1
    if ((tor)); then image=sha256:$(printf '%064d' 2); nets='{"basix-tor-egress":{},"basix-scrapling-internal":{}}'; ports='{}'; mounts='[]'; env='[]'; entrypoint='null'; cmd='null'; health='{"Test":["CMD-SHELL","grep -q '\''Bootstrapped 100%'\'' /var/log/tor/notices.log"]}'
    else image=sha256:$(printf '%064d' 1); config_image=docker.io/pyd4vinci/scrapling@sha256:$(printf '%064d' 1); nets='{"basix-scrapling-internal":{}}'; port=$(<"$MOCK_ROOT/scrapling-port"); ports="{\"$port/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"$port\"}]}"; mounts="[{\"Source\":\"$MOCK_ROOT/home/codex/basix/scrapling-tor/policy_mcp.py\",\"Destination\":\"/opt/basix/policy_mcp.py\",\"RW\":false}]"; env="[\"BASIX_TOR_IP=10.89.1.2\",\"BASIX_PORT=$port\",\"HTTP_PROXY=socks5h://10.89.1.2:9050\",\"HTTPS_PROXY=socks5h://10.89.1.2:9050\",\"ALL_PROXY=socks5h://10.89.1.2:9050\",\"http_proxy=socks5h://10.89.1.2:9050\",\"https_proxy=socks5h://10.89.1.2:9050\",\"all_proxy=socks5h://10.89.1.2:9050\",\"NO_PROXY=\",\"no_proxy=\"]"; entrypoint='["/app/.venv/bin/python"]'; cmd='["/opt/basix/policy_mcp.py"]'; health='null'; fi
    config_image=${config_image:-$image}
    owner=${MOCK_CONTAINER_OWNER:-${MOCK_OWNER:-true}}
    printf '[{"Image":"%s","EffectiveCaps":[],"BoundingCaps":[],"Mounts":%s,"Config":{"Image":"%s","Env":%s,"Entrypoint":%s,"Cmd":%s,"Healthcheck":%s,"CreateCommand":["podman","run","--cap-drop","ALL"],"Labels":{"io.basix.scrapling-tor.managed":"%s"}},"HostConfig":{"Privileged":false,"CapAdd":null,"CapDrop":["ALL"],"PortBindings":%s,"SecurityOpt":["no-new-privileges"],"RestartPolicy":{"Name":"unless-stopped"}},"NetworkSettings":{"Networks":%s}}]\n' "$image" "$mounts" "$config_image" "$env" "$entrypoint" "$cmd" "$health" "$owner" "$ports" "$nets" ;;
  run)
    if [[ $* == *' --name basix-scrapling-tor '* ]]; then : >"$MOCK_ROOT/container-basix-scrapling-tor"
    elif [[ $* == *' --name basix-scrapling-mcp '* ]]; then
      : >"$MOCK_ROOT/container-basix-scrapling-mcp"; previous=''
      for argument in "$@"; do if [[ $previous == -p ]]; then binding=$argument; break; fi; previous=$argument; done
      binding=${binding#127.0.0.1:}; printf '%s\n' "${binding%%:*}" >"$MOCK_ROOT/scrapling-port"
    elif [[ $* == *check.torproject.org* ]]; then printf '{"IsTor":%s}\n' "${MOCK_ISTOR:-true}"
    else [[ ${MOCK_RUNTIME:-ok} == ok ]]; fi ;;
  start) : ;;
  stop) : ;;
  rm) rm -f "$MOCK_ROOT/container-${*: -1}" ;;
  *) exit 1 ;;
esac
EOF
  cp "$case_dir/bin/podman" "$case_dir/bin/docker"
  chmod +x "$case_dir/bin/"*
  for tool in bash chmod cp dirname grep mkdir mktemp mv rm seq sleep; do ln -s "$(command -v "$tool")" "$case_dir/bin/$tool"; done
}

run_installer() {
  output=$case_dir/output; set +e
  PATH="$case_dir/bin:$PATH" HOME="$case_dir/home" CODEX_HOME="$case_dir/home/codex" MOCK_LOG="$log" MOCK_ROOT="$case_dir" \
    MOCK_ADD="${MOCK_ADD:-ok}" MOCK_REMOVE="${MOCK_REMOVE:-ok}" MOCK_RACE="${MOCK_RACE:-false}" MOCK_OWNER="${MOCK_OWNER:-true}" \
    MOCK_HEALTH="${MOCK_HEALTH:-healthy}" MOCK_ISTOR="${MOCK_ISTOR:-true}" MOCK_HANDSHAKE="${MOCK_HANDSHAKE:-ok}" MOCK_RUNTIME="${MOCK_RUNTIME:-ok}" \
    MOCK_FOREIGN="${MOCK_FOREIGN:-false}" \
    "$ROOT/src/setup/install-scrapling-codex.sh" "$@" >"$output" 2>&1
  status=$?; set -e
}
check() {
  local name=$1 want=$2 pattern=$3 forbidden=${4-}
  if [[ $status == "$want" ]] && grep -qE "$pattern" "$output" && { [[ -z $forbidden ]] || ! grep -qE "$forbidden" "$log"; }; then printf 'ok - %s\n' "$name"; ((passes+=1))
  else printf 'not ok - %s (status %s)\n' "$name" "$status"; sed -n '1,120p' "$output"; printf '%s\n' '--- log ---'; sed -n '1,120p' "$log"; ((failures+=1)); fi
  rm -rf "$case_dir"
}

make_mocks; run_installer
grep -qx 'PORT=8002' "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
grep -q -- '--network basix-scrapling-internal.*-p 127.0.0.1:8002:8002' "$log" || status=99
grep -q 'codex mcp add scrapling --url http://127.0.0.1:8002/mcp' "$log" || status=99
check 'default installs isolated persistent HTTP service' 0 'Endpoint: http://127.0.0.1:8002/mcp'

make_mocks; run_installer --port 9123
grep -qx 'PORT=9123' "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
grep -q 'codex mcp add scrapling --url http://127.0.0.1:9123/mcp' "$log" || status=99
check 'custom port reaches container and Codex URL' 0 'Endpoint: http://127.0.0.1:9123/mcp'

for bad in 80 00080 0 65536 word; do make_mocks; run_installer --port "$bad"; check "unsafe port $bad is rejected" 2 'Port must be' 'podman pull|codex mcp add'; done
make_mocks; run_installer --port 01024
grep -qx 'PORT=1024' "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
check 'leading-zero safe port is normalized in base ten' 0 'Endpoint: http://127.0.0.1:1024/mcp'

old='[{"name":"old-wrapper","enabled":true,"transport":{"type":"stdio","command":"/old/policy_mcp","args":["run"]}}]'
make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"; run_installer; check 'stdio migration requires approval' 7 'rerun with --force' 'podman pull|codex mcp remove'
make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"; run_installer --force; check 'force migrates stdio to URL' 0 'Endpoint: http://127.0.0.1:8002/mcp'
extra='[{"name":"scrapling","enabled":true,"transport":{"type":"http","url":"http://127.0.0.1:8002/mcp","command":"/evil"}}]'
make_mocks; printf '%s\n' "$extra" >"$case_dir/list.json"; run_installer; check 'URL registration with stale stdio fields is not canonical' 7 'rerun with --force' 'podman pull'
make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"; MOCK_RACE=true run_installer --force; check 'race blocks Codex mutation' 7 'changed concurrently' 'codex mcp remove|codex mcp add'

make_mocks; MOCK_OWNER=false run_installer; check 'foreign runtime resource is not taken over' 7 'foreign or unsafe network' 'codex mcp add'
make_mocks; MOCK_FOREIGN=true run_installer; check 'foreign running Scrapling container blocks install' 7 'foreign running Scrapling' 'codex mcp add'
make_mocks; MOCK_HANDSHAKE=fail run_installer; check 'HTTP failure rolls back both new containers' 9 'HTTP.*verification failed' 'codex mcp add'
make_mocks; MOCK_ISTOR=false run_installer; check 'non-Tor egress blocks Codex registration' 9 'IsTor=true' 'codex mcp add'
make_mocks; MOCK_HEALTH=unhealthy run_installer; check 'Tor health blocks service registration' 9 'failed validation or bootstrap' 'codex mcp add'
make_mocks; run_installer --runtime docker; check 'Docker receives the same security boundary' 0 'installation verified'

make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"; printf 'original = true\n' >"$case_dir/home/codex/config.toml"; MOCK_ADD=fail run_installer --force
[[ $(<"$case_dir/home/codex/config.toml") == 'original = true' ]] || status=99
check 'add failure restores Codex config' 8 'Could not add canonical'

secret='[{"name":"neutral","url":"https://token:very-secret@host/SCRAPLING","env":{"API_TOKEN":"never-print"}}]'
make_mocks; printf '%s\n' "$secret" >"$case_dir/list.json"; run_installer --dry-run; grep -qE 'very-secret|never-print' "$case_dir/output" && status=99
check 'diagnostics redact credentials and values' 0 '<redacted>'

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
