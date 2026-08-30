#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
passes=0 failures=0

make_mocks() {
  case_dir=$(mktemp -d); mkdir -p "$case_dir/bin" "$case_dir/home/codex" "$case_dir/xdg-runtime/libpod/tmp"; log=$case_dir/log; : >"$log"
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
    printf '[{"name":"scrapling","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"%s","bearer_token_env_var":null,"http_headers":null,"env_http_headers":null},"startup_timeout_sec":null,"tool_timeout_sec":null,"auth_status":"unsupported"}]\n' "$url" >"$MOCK_ROOT/list.json" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$case_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"$MOCK_LOG"
if [[ ${1-} == */health_check.py ]]; then
  if [[ ${MOCK_HANDSHAKE:-ok} == reset-once && ! -e $MOCK_ROOT/health-reset ]]; then
    : >"$MOCK_ROOT/health-reset"
    printf 'MCP HTTP, schema, or Tor verification failed: MCP phase initialize failed at http://127.0.0.1:8002/mcp: [Errno 104] Connection reset by peer\n' >&2
    exit 9
  fi
  [[ ${MOCK_HANDSHAKE:-ok} == ok || (${MOCK_HANDSHAKE:-ok} == reset-once && -e $MOCK_ROOT/health-reset) ]] || { printf 'MCP HTTP, schema, or Tor verification failed: handshake\n' >&2; exit 9; }
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
  info)
    [[ ${MOCK_INFO:-ok} == ok ]] || exit 1
    if [[ $* == *'Host.Security.Rootless'* ]]; then printf '%s\n' "${MOCK_ROOTLESS:-true}";
    elif [[ $* == *'Store.RunRoot'* ]]; then printf '%s\n' "${MOCK_RUNROOT:-/run/user/1000/containers}"; fi ;;
  --log-level=debug)
    [[ ${2-} == info ]] || exit 1
    [[ ${MOCK_TMPDIR_DEBUG:-ok} != fail ]] || exit 1
    [[ ${MOCK_TMPDIR_DEBUG:-ok} != empty ]] || exit 0
    printf 'time=mock level=debug msg="Using tmp dir %s"\n' "${MOCK_TMPDIR:-$MOCK_ROOT/xdg-runtime/libpod/tmp}" ;;
  ps)
    [[ ${MOCK_PS_FAIL:-false} != true ]] || exit 1
    [[ ${MOCK_PS_MALFORMED:-false} != true ]] || printf '%064d\n' 7
    [[ ${MOCK_FOREIGN:-false} != true ]] || printf '%064d foreign-scrapling\n' 8
    [[ ${MOCK_BENIGN_SCALAR:-false} != true ]] || printf '%064d benign-scalar-entrypoint\n' 9
    [[ ${MOCK_LEGACY:-false} != true ]] || printf '49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab adoring_rhodes\n' ;;
  pull|build) [[ ${MOCK_RUNTIME:-ok} == ok ]] ;;
  image)
    if [[ $* == *basix-scrapling-tor* ]]; then printf '%064d\n' 2
    elif [[ ${4-} == '{{.Id}}' ]]; then printf 'sha256:%064d\n' 1
    else printf 'docker.io/pyd4vinci/scrapling@sha256:%064d\n' 1; fi ;;
  network)
    case ${2-} in
      inspect) name=${*: -1}; [[ -f $MOCK_ROOT/net-$name ]] || exit 1; if [[ $* == *'--format'* ]]; then printf 'network-%s\n' "$name"; else internal=false; [[ $name == basix-scrapling-internal ]] && internal=true; dns=true; [[ ! -f $MOCK_ROOT/dns-disabled-$name ]] || dns=false; labels='{"io.basix.scrapling-tor.managed":"'"${MOCK_OWNER:-true}"'"}'; [[ -z ${BASIX_SETUP_TRANSACTION_ID:-} || $name == basix-scrapling-capability-* ]] || labels='{"io.basix.scrapling-tor.managed":"'"${MOCK_OWNER:-true}"'","io.basix.scrapling-tor.setup":"'"$BASIX_SETUP_TRANSACTION_ID"'"}'; containers='{}'; [[ $name != basix-scrapling-internal || ${MOCK_LEGACY:-false} != true ]] || containers='{"49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab":{"Name":"adoring_rhodes"}}'; printf '[{"Id":"network-%s","Driver":"bridge","Internal":%s,"DNSEnabled":%s,"NetworkDNSServers":[],"EnableIPv6":false,"Containers":%s,"Labels":%s}]\n' "$name" "$internal" "$dns" "$containers" "$labels"; fi ;;
      create) name=${*: -1}; [[ ${MOCK_CAPABILITY_FAIL:-false} != true || $name != basix-scrapling-capability-* ]] || exit 125; [[ ${MOCK_REQUIRE_NETNS_TARGET:-false} != true || ( -d "${MOCK_TMPDIR}/rootless-netns${XDG_RUNTIME_DIR}" && -d "$MOCK_TMPDIR/rootless-netns/run/systemd" && -d "$MOCK_TMPDIR/rootless-netns/run/systemd/resolve" && -d "$MOCK_TMPDIR/rootless-netns/var/lib" && -f "$MOCK_TMPDIR/rootless-netns/resolv.conf" ) ]] || exit 125; : >"$MOCK_ROOT/net-$name"; rm -f "$MOCK_ROOT/dns-disabled-$name" ;;
      connect) : ;;
      disconnect) : ;;
      rm) rm -f "$MOCK_ROOT/net-${*: -1}" ;;
    esac ;;
  inspect)
    name=${*: -1}
    if [[ $* == *--format* ]]; then
      if [[ $* == *'.Id'* ]]; then
        if [[ -f $MOCK_ROOT/rename-id-$name ]]; then printf '%s\n' "$(<"$MOCK_ROOT/rename-id-$name")"; else printf '%s\n' "$name"; fi
      elif [[ $* == *Health.Status* ]]; then printf '%s\n' "${MOCK_HEALTH:-healthy}"
      elif [[ $* == *State.Status* ]]; then
        [[ ${MOCK_BOOTSTRAP:-true} == true ]] && printf 'running\n' || printf 'exited\n'
      else printf '10.89.1.2\n'; fi
      exit 0
    fi
    if [[ $name == basix-scrapling-tor && ${MOCK_TOR_FOREIGN_CREATED:-false} == true ]]; then
      printf '[{"Id":"foreign-tor-created-id","State":{"Status":"created"},"Config":{"Image":"docker.io/library/alpine:latest"},"HostConfig":{},"NetworkSettings":{"Networks":{}},"Mounts":[]} ]\n'
      exit 0
    fi
    if [[ $name == basix-scrapling-mcp && ${MOCK_SCRAPLING_FOREIGN_CREATED:-false} == true ]]; then
      printf '[{"Id":"foreign-scrapling-created-id","State":{"Status":"created"},"Config":{"Image":"docker.io/library/alpine:latest"},"HostConfig":{},"NetworkSettings":{"Networks":{}},"Mounts":[]} ]\n'
      exit 0
    fi
    if [[ $name == $(printf '%064d' 8) ]]; then
      printf '[{"Id":"%064d","Config":{"Image":"docker.io/pyd4vinci/scrapling@sha256:%064d","Entrypoint":["python"],"Cmd":["policy_mcp.py"]}}]\n' 8 1
      exit 0
    fi
    if [[ $name == $(printf '%064d' 9) ]]; then
      printf '[{"Id":"%064d","Config":{"Image":"docker.io/library/debian:bookworm-slim","Entrypoint":"/usr/bin/tini","Cmd":["sleep","infinity"]},"HostConfig":{},"NetworkSettings":{"Networks":{}},"Mounts":[]}]\n' 9
      exit 0
    fi
    if [[ $name == 49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab ]]; then
      sed "s|/home/codex/.codex|$MOCK_ROOT/home/codex|" "$MOCK_FIXTURE"
      exit 0
    fi
    [[ -f $MOCK_ROOT/container-$name ]] || exit 1
    tor=0; [[ $name == basix-scrapling-tor ]] && tor=1
    if ((tor)); then image=sha256:$(printf '%064d' 2); nets='{"basix-tor-egress":{},"basix-scrapling-internal":{"Aliases":["basix-tor-proxy"]}}'; ports='{}'; mounts='[]'; env='[]'; entrypoint='null'; cmd='null'; health='{"Test":["CMD-SHELL","grep -q '\''Bootstrapped 100%'\'' /var/log/tor/notices.log"]}'
    else image=sha256:$(printf '%064d' 1); config_image=docker.io/pyd4vinci/scrapling@sha256:$(printf '%064d' 1); nets='{"basix-scrapling-internal":{}}'; port=$(<"$MOCK_ROOT/scrapling-port"); ports="{\"$port/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"$port\"}]}"; mounts="[{\"Source\":\"$MOCK_ROOT/home/codex/basix/scrapling-tor/policy_mcp.py\",\"Destination\":\"/opt/basix/policy_mcp.py\",\"RW\":false}]"; env="[\"BASIX_TOR_HOST=basix-tor-proxy\",\"BASIX_PORT=$port\",\"HTTP_PROXY=socks5h://basix-tor-proxy:9050\",\"HTTPS_PROXY=socks5h://basix-tor-proxy:9050\",\"ALL_PROXY=socks5h://basix-tor-proxy:9050\",\"http_proxy=socks5h://basix-tor-proxy:9050\",\"https_proxy=socks5h://basix-tor-proxy:9050\",\"all_proxy=socks5h://basix-tor-proxy:9050\",\"NO_PROXY=\",\"no_proxy=\"]"; entrypoint='["/app/.venv/bin/python"]'; cmd='["/opt/basix/policy_mcp.py"]'; health='null'; fi
    config_image=${config_image:-$image}
    owner=${MOCK_CONTAINER_OWNER:-${MOCK_OWNER:-true}}
    restart=${MOCK_RESTART:-unless-stopped}
    [[ $restart != legacy-empty || -f $MOCK_ROOT/restart-current-$name ]] || restart=''
    [[ $restart != legacy-empty ]] || restart=unless-stopped
    printf '[{"Image":"%s","EffectiveCaps":[],"BoundingCaps":[],"Mounts":%s,"Config":{"Image":"%s","Env":%s,"Entrypoint":%s,"Cmd":%s,"Healthcheck":%s,"CreateCommand":["podman","run","--cap-drop","ALL"],"Labels":{"io.basix.scrapling-tor.managed":"%s"}},"HostConfig":{"Privileged":false,"CapAdd":null,"CapDrop":["ALL"],"PortBindings":%s,"SecurityOpt":["no-new-privileges"],"RestartPolicy":{"Name":"%s"}},"NetworkSettings":{"Networks":%s}}]\n' "$image" "$mounts" "$config_image" "$env" "$entrypoint" "$cmd" "$health" "$owner" "$ports" "$restart" "$nets" ;;
  exec)
    if [[ $* == *'/var/log/tor/notices.log'* ]]; then
      [[ ${MOCK_BOOTSTRAP:-true} == true ]]
    fi ;;
  run)
    if [[ $* == *'--name basix-scrapling-egress-probe-'* ]]; then
      if [[ ${MOCK_PROBE_FAIL:-false} == true ]]; then
        probe_name=''; previous=''
        for argument in "$@"; do if [[ $previous == --name ]]; then probe_name=$argument; break; fi; previous=$argument; done
        : >"$MOCK_ROOT/container-$probe_name"; exit 125
      fi
    elif [[ $* == *' --name basix-scrapling-tor '* ]]; then
      if [[ ${MOCK_TOR_RUN_FAIL:-false} == true ]]; then
        : >"$MOCK_ROOT/container-tor-created-id"; printf 'tor-created-id\n'; exit 125
      fi
      : >"$MOCK_ROOT/container-basix-scrapling-tor"; : >"$MOCK_ROOT/restart-current-basix-scrapling-tor"; printf 'tor-running-id\n'
    elif [[ $* == *' --name basix-scrapling-mcp '* ]]; then
      if [[ ${MOCK_SCRAPLING_RUN_FAIL:-false} == true ]]; then
        : >"$MOCK_ROOT/container-scrapling-created-id"; printf 'scrapling-created-id\n'; exit 125
      fi
      : >"$MOCK_ROOT/container-basix-scrapling-mcp"; : >"$MOCK_ROOT/restart-current-basix-scrapling-mcp"; printf 'scrapling-running-id\n'; previous=''
      for argument in "$@"; do if [[ $previous == -p ]]; then binding=$argument; break; fi; previous=$argument; done
      binding=${binding#127.0.0.1:}; printf '%s\n' "${binding%%:*}" >"$MOCK_ROOT/scrapling-port"
    elif [[ $* == *check.torproject.org* ]]; then printf '{"IsTor":%s}\n' "${MOCK_ISTOR:-true}"
    else [[ ${MOCK_RUNTIME:-ok} == ok ]]; fi ;;
  logs) printf 'mock logs for %s\n' "${*: -1}" ;;
  start) : ;;
  stop) : ;;
  rename)
    old=$2; new=$3; [[ -f $MOCK_ROOT/container-$old ]] || exit 1
    mv "$MOCK_ROOT/container-$old" "$MOCK_ROOT/container-$new"
    if [[ -f $MOCK_ROOT/restart-current-$old ]]; then mv "$MOCK_ROOT/restart-current-$old" "$MOCK_ROOT/restart-current-$new"; fi
    old_id=$old; [[ ! -f $MOCK_ROOT/rename-id-$old ]] || old_id=$(<"$MOCK_ROOT/rename-id-$old")
    printf '%s\n' "$old_id" >"$MOCK_ROOT/rename-id-$new"
    ;;
  rm)
    target=${*: -1}; remove_target=$target
    if [[ ! -e $MOCK_ROOT/container-$target ]]; then
      for marker in "$MOCK_ROOT"/rename-id-*; do
        [[ -e $marker ]] || continue
        [[ $(<"$marker") == "$target" ]] || continue
        remove_target=${marker##*/rename-id-}; break
      done
    fi
    rm -f "$MOCK_ROOT/container-$remove_target" "$MOCK_ROOT/restart-current-$remove_target" "$MOCK_ROOT/rename-id-$remove_target" ;;
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
    XDG_RUNTIME_DIR="${MOCK_XDG_RUNTIME_DIR:-$case_dir/xdg-runtime}" MOCK_TMPDIR="$case_dir/xdg-runtime/libpod/tmp" \
    MOCK_ADD="${MOCK_ADD:-ok}" MOCK_REMOVE="${MOCK_REMOVE:-ok}" MOCK_RACE="${MOCK_RACE:-false}" MOCK_OWNER="${MOCK_OWNER:-true}" \
    MOCK_HEALTH="${MOCK_HEALTH:-healthy}" MOCK_ISTOR="${MOCK_ISTOR:-true}" MOCK_HANDSHAKE="${MOCK_HANDSHAKE:-ok}" MOCK_RUNTIME="${MOCK_RUNTIME:-ok}" \
    MOCK_FOREIGN="${MOCK_FOREIGN:-false}" MOCK_BENIGN_SCALAR="${MOCK_BENIGN_SCALAR:-false}" MOCK_RESTART="${MOCK_RESTART:-unless-stopped}" \
    MOCK_LEGACY="${MOCK_LEGACY:-false}" MOCK_FIXTURE="$ROOT/test/setup/install-scrapling-codex/fixtures/podman-legacy-stdio.json" \
    MOCK_PS_FAIL="${MOCK_PS_FAIL:-false}" \
    MOCK_CAPABILITY_FAIL="${MOCK_CAPABILITY_FAIL:-false}" \
    MOCK_REQUIRE_NETNS_TARGET="${MOCK_REQUIRE_NETNS_TARGET:-false}" \
    MOCK_TMPDIR_DEBUG="${MOCK_TMPDIR_DEBUG:-ok}" \
    MOCK_PS_MALFORMED="${MOCK_PS_MALFORMED:-false}" \
    MOCK_PROBE_FAIL="${MOCK_PROBE_FAIL:-false}" MOCK_ROOTLESS="${MOCK_ROOTLESS:-true}" MOCK_RUNROOT="${MOCK_RUNROOT:-/run/user/1000/containers}" \
    MOCK_TOR_RUN_FAIL="${MOCK_TOR_RUN_FAIL:-false}" MOCK_SCRAPLING_RUN_FAIL="${MOCK_SCRAPLING_RUN_FAIL:-false}" MOCK_BOOTSTRAP="${MOCK_BOOTSTRAP:-true}" \
    MOCK_TOR_FOREIGN_CREATED="${MOCK_TOR_FOREIGN_CREATED:-false}" MOCK_SCRAPLING_FOREIGN_CREATED="${MOCK_SCRAPLING_FOREIGN_CREATED:-false}" \
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

make_mocks
old_support="$case_dir/home/codex/basix/scrapling-tor"
mkdir -p "$old_support"
printf 'old support\n' >"$old_support/old-marker"
run_installer
[[ ! -e "$old_support/old-marker" ]] || status=99
check 'replacement does not nest the previous support tree' 0 'installation verified'

make_mocks; MOCK_CAPABILITY_FAIL=true run_installer
! grep -q -- '--name basix-scrapling-tor ' "$log" || status=99
! grep -q -- '--name basix-scrapling-mcp ' "$log" || status=99
check 'failed alias and egress proof blocks managed mutation' 4 'Internal alias and direct-egress capability proof failed' 'codex mcp add'

make_mocks; MOCK_REQUIRE_NETNS_TARGET=true run_installer
check 'rootless netns mount target is prepared before capability proof' 0 'installation verified'

make_mocks; MOCK_XDG_RUNTIME_DIR="$case_dir/missing-runtime" run_installer
! grep -q -- '--name basix-scrapling-tor ' "$log" || status=99
check 'missing rootless runtime blocks managed mutation' 4 'XDG_RUNTIME_DIR is missing or not writable' 'podman pull|codex mcp add'

make_mocks; printf 'not a directory\n' >"$case_dir/not-a-runtime"; MOCK_XDG_RUNTIME_DIR="$case_dir/not-a-runtime" run_installer
! grep -q -- '--name basix-scrapling-tor ' "$log" || status=99
check 'unusable rootless runtime blocks managed mutation' 4 'XDG_RUNTIME_DIR is missing or not writable' 'podman pull|codex mcp add'

make_mocks; MOCK_TMPDIR_DEBUG=empty run_installer
! grep -q -- '--name basix-scrapling-tor ' "$log" || status=99
check 'unparseable rootless temp path blocks managed mutation' 4 'temporary directory is missing or not writable' 'podman pull|codex mcp add'

make_mocks; MOCK_ROOTLESS=false run_installer
[[ ! -e "$case_dir/xdg-runtime/libpod/tmp/rootless-netns" ]] || status=99
check 'rootful Podman skips the rootless repair' 0 'installation verified'

make_mocks; MOCK_PROBE_FAIL=true MOCK_ROOTLESS=true MOCK_RUNROOT=/run/user/1000/containers run_installer
! grep -q -- '--name basix-scrapling-tor ' "$log" || status=99
! grep -q -- '--name basix-scrapling-mcp ' "$log" || status=99
check 'failed rootless network probe blocks all service creation and Codex mutation' 4 'Runtime: podman; Rootless: true; Store.RunRoot: /run/user/1000/containers' 'codex mcp add'

make_mocks; MOCK_TOR_RUN_FAIL=true run_installer
grep -q 'rm -f tor-created-id' "$log" || status=99
! grep -q -- '--name basix-scrapling-mcp ' "$log" || status=99
check 'failed Tor run rolls back the exact created container ID' 9 'Managed Tor failed validation or bootstrap' 'codex mcp add'

make_mocks; MOCK_SCRAPLING_RUN_FAIL=true run_installer
grep -q 'rm -f scrapling-created-id' "$log" || status=99
grep -q 'rm -f tor-running-id' "$log" || status=99
check 'failed Scrapling run rolls back both exact created resources' 9 'Managed Tor failed validation or bootstrap' 'codex mcp add'

make_mocks; MOCK_TOR_FOREIGN_CREATED=true run_installer --force
! grep -q 'rm -f basix-scrapling-tor' "$log" || status=99
! grep -q -- '--name basix-scrapling-mcp ' "$log" || status=99
check 'foreign Created Tor container is unchanged and blocks installation' 7 'foreign or unsafe Tor container' 'codex mcp add'

make_mocks; MOCK_SCRAPLING_FOREIGN_CREATED=true run_installer --force
! grep -q 'rm -f basix-scrapling-mcp' "$log" || status=99
! grep -q -- '--name basix-scrapling-mcp ' "$log" || status=99
check 'foreign Created Scrapling container is unchanged and blocks installation' 7 'foreign or unsafe Scrapling container' 'codex mcp add'

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
make_mocks
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" "$case_dir/container-basix-scrapling-tor" "$case_dir/container-basix-scrapling-mcp"
printf '8002\n' >"$case_dir/scrapling-port"
MOCK_RESTART=legacy-empty run_installer
grep -q 'rm -f basix-scrapling-tor' "$log" || status=99
grep -q 'rm -f basix-scrapling-mcp' "$log" || status=99
grep -q 'run -d --name basix-scrapling-tor ' "$log" || status=99
grep -q 'run -d --name basix-scrapling-mcp ' "$log" || status=99
check 'legacy managed containers without restart policy are upgraded' 0 'installation verified'
make_mocks
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" \
  "$case_dir/container-basix-scrapling-tor" "$case_dir/container-basix-scrapling-mcp" \
  "$case_dir/restart-current-basix-scrapling-tor" "$case_dir/restart-current-basix-scrapling-mcp"
printf '8002\n' >"$case_dir/scrapling-port"
run_installer
grep -q 'rm -f basix-scrapling-mcp' "$log" || status=99
grep -q 'run -d --name basix-scrapling-mcp ' "$log" || status=99
check 'installer replaces an existing canonical Scrapling service' 0 'Replacing the existing managed Scrapling service'
make_mocks
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" "$case_dir/dns-disabled-basix-scrapling-internal" "$case_dir/container-basix-scrapling-tor" "$case_dir/container-basix-scrapling-mcp"
printf '8002\n' >"$case_dir/scrapling-port"
run_installer
grep -q 'network connect --alias basix-tor-proxy basix-scrapling-internal basix-scrapling-tor' "$log" || status=99
grep -q 'rm -f basix-scrapling-mcp' "$log" || status=99
check 'owned DNS-disabled network migrates with stable Tor alias' 0 'installation verified'
make_mocks
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" "$case_dir/container-basix-scrapling-tor"
MOCK_FOREIGN=true MOCK_RESTART=legacy-empty run_installer --force
! grep -qE 'rm -f basix-scrapling-tor|start basix-scrapling-tor|run -d --name basix-scrapling-tor ' "$log" || status=99
check 'foreign running Scrapling blocks install before Tor reconciliation' 7 'foreign or unsafe running Scrapling' 'codex mcp add'
make_mocks; MOCK_PS_FAIL=true run_installer --force; check 'runtime enumeration failure blocks install' 7 'Could not enumerate running containers' 'codex mcp add'
make_mocks; MOCK_PS_MALFORMED=true run_installer --force; check 'malformed runtime enumeration blocks install' 7 'malformed container listing' 'codex mcp add'
make_mocks; MOCK_BENIGN_SCALAR=true run_installer; check 'scalar entrypoint on unrelated container is ignored' 0 'installation verified'
make_mocks; MOCK_LEGACY=true run_installer
verify_line=$(grep -n 'health_check.py' "$log" | tail -n1 | cut -d: -f1)
remove_line=$(grep -n 'rm -f 49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab' "$log" | tail -n1 | cut -d: -f1)
[[ -n $verify_line && -n $remove_line && $verify_line -lt $remove_line ]] || status=99
check 'validated stdio legacy is removed only after HTTP verification' 0 'Removed validated legacy Scrapling container adoring_rhodes'
make_mocks; MOCK_LEGACY=true MOCK_ADD=fail run_installer --force
check 'Codex failure preserves validated legacy runtime' 8 'Could not add canonical' 'rm -f 49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab'
make_mocks
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" "$case_dir/dns-disabled-basix-scrapling-internal" \
  "$case_dir/container-basix-scrapling-tor" "$case_dir/container-basix-scrapling-mcp"
printf '8002\n' >"$case_dir/scrapling-port"
MOCK_LEGACY=true MOCK_ADD=fail run_installer --force
check 'DNS migration keeps validated legacy container restorable on Codex failure' 8 'Could not add canonical' 'rm -f 49ac63819ee416d827015b0cd8136e3d1c849f0316a701f1c2949ccd48a7ecab'
make_mocks
old_support="$case_dir/home/codex/basix/scrapling-tor"
mkdir -p "$old_support"
printf 'old support\n' >"$old_support/old-marker"
MOCK_HANDSHAKE=fail run_installer
[[ -f "$old_support/old-marker" && $(<"$old_support/old-marker") == 'old support' ]] || status=99
diag_line=$(grep -n 'podman logs --tail 200 basix-scrapling-tor' "$log" | tail -n1 | cut -d: -f1)
rollback_line=$(grep -n 'podman rm -f tor-running-id' "$log" | tail -n1 | cut -d: -f1)
[[ -n $diag_line && -n $rollback_line && $diag_line -lt $rollback_line ]] || status=99
grep -q 'MCP verification failed; collecting container diagnostics before rollback' "$output" || status=99
check 'HTTP failure rolls back both new containers with diagnostics first' 9 'Status 9:.*status 4' 'codex mcp add'
make_mocks; MOCK_ISTOR=false run_installer; check 'non-Tor egress blocks Codex registration' 9 'IsTor=true' 'codex mcp add'
make_mocks; MOCK_HEALTH=starting MOCK_BOOTSTRAP=false run_installer; check 'direct Tor bootstrap check blocks service registration' 9 'direct notice check: failed' 'codex mcp add'
make_mocks; MOCK_HANDSHAKE=reset-once run_installer; check 'transient MCP startup reset is retried' 0 'retrying health check'
make_mocks; run_installer --runtime docker; check 'Docker receives the same security boundary' 0 'installation verified'

make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"; printf 'original = true\n' >"$case_dir/home/codex/config.toml"; MOCK_ADD=fail run_installer --force
[[ $(<"$case_dir/home/codex/config.toml") == 'original = true' ]] || status=99
check 'add failure restores Codex config' 8 'Could not add canonical'

make_mocks; printf '%s\n' "$old" >"$case_dir/list.json"
touch "$case_dir/net-basix-tor-egress" "$case_dir/net-basix-scrapling-internal" \
  "$case_dir/container-basix-scrapling-tor" "$case_dir/container-basix-scrapling-mcp"
printf '8002\n' >"$case_dir/scrapling-port"
MOCK_ADD=fail run_installer --force
[[ -e "$case_dir/container-basix-scrapling-tor" && -e "$case_dir/container-basix-scrapling-mcp" ]] || status=99
! compgen -G "$case_dir/container-basix-scrapling-*.basix-rollback-*" >/dev/null || status=99
check 'Codex failure restores pre-existing managed runtime' 8 'Could not add canonical'

secret='[{"name":"neutral","url":"https://token:very-secret@host/SCRAPLING","env":{"API_TOKEN":"never-print"}}]'
make_mocks; printf '%s\n' "$secret" >"$case_dir/list.json"; run_installer --dry-run; grep -qE 'very-secret|never-print' "$case_dir/output" && status=99
check 'diagnostics redact credentials and values' 0 '<redacted>'

make_mocks; run_installer --dry-run
[[ ! -e "$case_dir/xdg-runtime/libpod/tmp/rootless-netns" ]] || status=99
check 'dry-run does not prepare or mutate the runtime' 0 'Dry run \(no changes\)'

printf '%d passed, %d failed\n' "$passes" "$failures"
grep -q '"make_request","open_request_session","open_session"' \
  "$ROOT/src/setup/install-scrapling-codex.sh" || { printf 'not ok - pinned tool inventory assertion missing\n'; exit 1; }
grep -q '"session_make_request":{"url","session_id","auth","http3"}' \
  "$ROOT/src/setup/install-scrapling-codex.sh" || { printf 'not ok - request-session schema assertion missing\n'; exit 1; }
((failures == 0))
