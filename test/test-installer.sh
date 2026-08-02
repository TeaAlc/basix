#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
    count_file=$MOCK_ROOT/list-count; count=0; [[ ! -f $count_file ]] || count=$(<"$count_file"); ((count+=1)); printf '%s' "$count" >"$count_file"
    if [[ ${MOCK_RACE:-false} == true && $count -ge 2 ]]; then printf '[{"name":"scrapling","transport":{"type":"stdio","command":"changed","args":[]}}]\n'
    else command cp "$MOCK_ROOT/list.json" /dev/stdout; fi ;;
  mcp\ remove\ *)
    [[ ${MOCK_REMOVE:-ok} == ok ]] || exit 1
    printf '[]\n' >"$MOCK_ROOT/list.json" ;;
  mcp\ add\ scrapling\ --\ *)
    [[ ${MOCK_ADD:-ok} == ok ]] || exit 1
    launcher=$5
    printf '[{"name":"scrapling","enabled":true,"transport":{"type":"stdio","command":"%s","args":["run"],"env":null,"cwd":null}}]\n' "$launcher" >"$MOCK_ROOT/list.json" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$case_dir/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$MOCK_LOG"
case "${1-}" in
  info) [[ ${MOCK_INFO:-ok} == ok ]] ;;
  ps) printf '[]\n' ;;
  pull|build) [[ ${MOCK_RUNTIME:-ok} == ok ]] ;;
  image)
    [[ ${2-} == inspect ]] || exit 0
    if [[ $* == *basix-scrapling-tor* ]]; then
      if [[ ${MOCK_TOR_INSPECT_OUTPUT+x} ]]; then printf '%s' "$MOCK_TOR_INSPECT_OUTPUT"
      elif [[ ${0##*/} == podman ]]; then printf '%064d\n' 2
      else printf 'sha256:%064d\n' 2; fi
    elif [[ ${MOCK_SCRAPLING_INSPECT_OUTPUT+x} ]]; then printf '%s' "$MOCK_SCRAPLING_INSPECT_OUTPUT"
    else printf 'docker.io/pyd4vinci/scrapling@sha256:%064d\n' 1; fi ;;
  network)
    case ${2-} in
      inspect)
        name=${*: -1}; [[ -f $MOCK_ROOT/net-$name ]] || exit 1
        internal=false; [[ $name == basix-scrapling-internal ]] && internal=true
        net_containers=${MOCK_NET_CONTAINERS:-'{}'}
        printf '[{"Driver":"bridge","Internal":%s,"EnableIPv6":false,"Labels":{"io.basix.scrapling-tor.managed":"%s"},"Containers":%s}]\n' "$internal" "${MOCK_OWNER:-true}" "$net_containers" ;;
      create) name=${*: -1}; : >"$MOCK_ROOT/net-$name" ;;
      connect|rm) : ;;
      *) exit 1 ;;
    esac ;;
  inspect)
    if [[ $* == *--format* ]]; then
      [[ $* == *Health.Status* ]] && printf '%s\n' "${MOCK_HEALTH:-healthy}" || printf '10.89.1.2\n'
    else
      [[ -f $MOCK_ROOT/container ]] || exit 1
      tor_id=$(printf '%064d' 2)
      if [[ -f $MOCK_ROOT/container-recreated ]]; then image=$tor_id; config_image=sha256:$tor_id
      else image=${MOCK_CONTAINER_IMAGE:-$tor_id}; config_image=${MOCK_CONFIG_IMAGE:-localhost/basix-scrapling-tor:bookworm}; fi
      if [[ ${0##*/} == docker ]]; then cap_drop=${MOCK_CAP_DROP:-'["ALL"]'}
      else cap_drop=${MOCK_CAP_DROP:-'["CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_FOWNER","CAP_FSETID","CAP_KILL","CAP_NET_BIND_SERVICE","CAP_SETFCAP","CAP_SETGID","CAP_SETPCAP","CAP_SETUID","CAP_SYS_CHROOT"]'}; fi
      create_command=${MOCK_CREATE_COMMAND:-'["podman","run","--cap-drop","ALL"]'}
      effective=${MOCK_EFFECTIVE_CAPS:-null}; bounding=${MOCK_BOUNDING_CAPS:-null}
      printf '[{"Image":"%s","EffectiveCaps":%s,"BoundingCaps":%s,"Mounts":[],"Config":{"Image":"%s","CreateCommand":%s,"Labels":{"io.basix.scrapling-tor.managed":"%s"},"Healthcheck":{"Test":["CMD-SHELL","grep -q '\''Bootstrapped 100%%'\'' /var/log/tor/notices.log"]},"ExposedPorts":null,"Volumes":null},"HostConfig":{"Privileged":false,"CapAdd":null,"CapDrop":%s,"Binds":null,"PortBindings":{},"SecurityOpt":["no-new-privileges"]},"NetworkSettings":{"Networks":{"basix-tor-egress":{"IPAddress":"10.89.0.2"},"basix-scrapling-internal":{"IPAddress":"10.89.1.2"}}}}]\n' "$image" "$effective" "$bounding" "$config_image" "$create_command" "${MOCK_CONTAINER_OWNER:-${MOCK_OWNER:-true}}" "$cap_drop"
    fi ;;
  run)
    if [[ $* == *' -d '* || $* == *'run -d '* ]]; then : >"$MOCK_ROOT/container"; : >"$MOCK_ROOT/container-recreated"
    elif [[ $* == *check.torproject.org* ]]; then printf '{"IsTor":%s}\n' "${MOCK_ISTOR:-true}"
    elif [[ $* == *policy_mcp.py* ]]; then
      [[ ${MOCK_HANDSHAKE:-ok} == ok ]] && printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}\n' || exit 1
    else [[ ${MOCK_RUNTIME:-ok} == ok ]]; fi ;;
  start) : ;; rm) rm -f "$MOCK_ROOT/container" ;;
  *) exit 1 ;;
esac
EOF
  cp "$case_dir/bin/podman" "$case_dir/bin/docker"
  chmod +x "$case_dir/bin/"*
  for tool in bash chmod cp dirname grep mkdir mktemp mv ps rm seq sleep; do ln -s "$(command -v "$tool")" "$case_dir/bin/$tool"; done
}

run_installer() {
  output=$case_dir/output; set +e
  PATH="$case_dir/bin:$PATH" HOME="$case_dir/home" CODEX_HOME="$case_dir/home/codex" MOCK_LOG="$log" MOCK_ROOT="$case_dir" \
    MOCK_ADD="${MOCK_ADD:-ok}" MOCK_REMOVE="${MOCK_REMOVE:-ok}" MOCK_RACE="${MOCK_RACE:-false}" MOCK_OWNER="${MOCK_OWNER:-true}" \
    MOCK_HEALTH="${MOCK_HEALTH:-healthy}" MOCK_ISTOR="${MOCK_ISTOR:-true}" MOCK_HANDSHAKE="${MOCK_HANDSHAKE:-ok}" MOCK_RUNTIME="${MOCK_RUNTIME:-ok}" \
    MOCK_NET_CONTAINERS="${MOCK_NET_CONTAINERS-}" \
    "$ROOT/src/setup/install-scrapling-codex.sh" "$@" >"$output" 2>&1
  status=$?; set -e
}
check() {
  local name=$1 want=$2 pattern=$3 forbidden=${4-}
  if [[ $status == "$want" ]] && grep -qE "$pattern" "$output" && { [[ -z $forbidden ]] || ! grep -qE "$forbidden" "$log"; }; then
    printf 'ok - %s\n' "$name"; ((passes+=1))
  else printf 'not ok - %s (status %s)\n' "$name" "$status"; sed -n '1,140p' "$output"; printf '%s\n' '--- log ---'; sed -n '1,140p' "$log"; ((failures+=1)); fi
  rm -rf "$case_dir"
}

make_mocks; run_installer
tor_id=$(printf '%064d' 2)
grep -qx "TOR_IMAGE=sha256:$tor_id" "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
grep -q "sha256:$tor_id" "$log" || status=99
check 'Podman raw Tor image ID is normalized, stored, and used' 0 'immutable image docker.io/.+@sha256:' ''
make_mocks; : >"$case_dir/container"; MOCK_CONFIG_IMAGE="sha256:$tor_id" run_installer
if grep -q 'podman rm -f basix-scrapling-tor' "$log"; then status=99; fi
check 'canonical Podman sidecar is reused with real expanded CapDrop' 0 'installation verified' ''
make_mocks; : >"$case_dir/container"; MOCK_CONTAINER_IMAGE=$(printf '%064d' 9) run_installer
grep -q 'podman rm -f basix-scrapling-tor' "$log" || status=99
grep -q 'podman run -d .*sha256:' "$log" || status=99
check 'safe managed sidecar with stale image is replaced' 0 'Replacing safely managed Tor sidecar' ''
make_mocks; : >"$case_dir/container"; MOCK_CONTAINER_IMAGE=$(printf '%064d' 9) MOCK_CONTAINER_OWNER=false run_installer
check 'foreign stale sidecar is rejected and never removed' 7 'foreign or unsafe Tor container' 'podman rm -f basix-scrapling-tor|codex mcp remove|codex mcp add'
make_mocks; : >"$case_dir/container"; MOCK_CONTAINER_IMAGE=$(printf '%064d' 9) MOCK_CREATE_COMMAND='["podman","run"]' MOCK_CAP_DROP='["CAP_CHOWN"]' run_installer
check 'unsafe stale sidecar is rejected and never removed' 7 'foreign or unsafe Tor container' 'podman rm -f basix-scrapling-tor|codex mcp remove|codex mcp add'
make_mocks; : >"$case_dir/container"; MOCK_CONTAINER_IMAGE=$(printf '%064d' 9) MOCK_EFFECTIVE_CAPS='["CAP_CHOWN"]' run_installer
check 'effective Podman capabilities make a stale sidecar unsafe' 7 'foreign or unsafe Tor container' 'podman rm -f basix-scrapling-tor|codex mcp remove|codex mcp add'
make_mocks; run_installer --runtime docker
grep -qx "TOR_IMAGE=sha256:$tor_id" "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
check 'Docker prefixed Tor image ID remains accepted' 0 'installation verified' ''
make_mocks; MOCK_SCRAPLING_INSPECT_OUTPUT=$(printf '%064d\n' 3) run_installer
grep -qx "SCRAPLING_IMAGE=sha256:$(printf '%064d' 3)" "$case_dir/home/codex/basix/scrapling-tor/config" || status=99
check 'raw Scrapling fallback image ID is normalized' 0 'installation verified' ''
make_mocks; MOCK_TOR_INSPECT_OUTPUT='' run_installer; check 'empty Tor inspect output is rejected before Codex mutation' 6 'immutable Tor image ID' 'codex mcp remove|codex mcp add'
make_mocks; MOCK_TOR_INSPECT_OUTPUT='not-an-image-id' run_installer; check 'invalid Tor inspect output is rejected before Codex mutation' 6 'immutable Tor image ID' 'codex mcp remove|codex mcp add'
make_mocks; MOCK_TOR_INSPECT_OUTPUT=$(printf '%063d\n' 2) run_installer; check 'short Tor inspect output is rejected before Codex mutation' 6 'immutable Tor image ID' 'codex mcp remove|codex mcp add'
make_mocks; MOCK_TOR_INSPECT_OUTPUT=$(printf '%064d\n%064d\n' 2 3) run_installer; check 'multiline Tor inspect output is rejected before Codex mutation' 6 'immutable Tor image ID' 'codex mcp remove|codex mcp add'
one='[{"name":"old-wrapper","enabled":true,"transport":{"type":"stdio","command":"/opt/Scrapling-wrapper","args":[],"env":{"TOKEN":"super-secret"},"cwd":null}}]'
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; run_installer; check 'one registration needs noninteractive approval' 7 'rerun with --force' 'podman pull|codex mcp remove'
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; run_installer --force; check 'force migrates differently named registration' 0 'Running Codex sessions may keep' ''
make_mocks; : >"$case_dir/net-basix-tor-egress"; : >"$case_dir/net-basix-scrapling-internal"
MOCK_NET_CONTAINERS='{"random-old-mcp":{"Name":"sleepy_scrapling"}}' run_installer
check 'randomly named running Scrapling container does not block migration' 0 'installation verified' ''
two='[{"name":"scrapling","command":"x"},{"name":"other","url":"http://SCRAPLING.example/mcp","enabled":false}]'
make_mocks; printf '%s\n' "$two" >"$case_dir/list.json"; run_installer --force; check 'multiple registrations always fail before mutation' 7 'Multiple Scrapling' 'podman pull|podman build|codex mcp remove|codex mcp add'
make_mocks; printf '%s\n' "$two" >"$case_dir/list.json"; run_installer --dry-run; check 'multiple registrations also fail in dry-run' 7 'Multiple Scrapling' 'podman pull|podman build'
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; run_installer --dry-run; check 'dry-run shows migration but changes nothing' 0 'Would prompt.*old-wrapper' 'podman pull|codex mcp remove|codex mcp add'
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; MOCK_RACE=true run_installer --force; check 'race is detected before Codex mutation' 7 'changed concurrently' 'codex mcp remove|codex mcp add'
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; printf 'original = true\n' >"$case_dir/home/codex/config.toml"; MOCK_ADD=fail run_installer --force; restored=$(<"$case_dir/home/codex/config.toml"); [[ $restored == 'original = true' ]] || status=99; check 'add failure restores exact Codex config' 8 'Could not add canonical' ''
make_mocks; printf '%s\n' "$one" >"$case_dir/list.json"; MOCK_REMOVE=fail run_installer --force; check 'remove failure is a Codex error' 8 'Could not remove old' ''
make_mocks; MOCK_OWNER=false run_installer; check 'unsafe preexisting runtime resource rejected' 7 'foreign or unsafe network' 'codex mcp add'
make_mocks; MOCK_ISTOR=false run_installer; check 'non-Tor egress blocks registration' 9 'IsTor=true' 'codex mcp add'
make_mocks; : >"$case_dir/container"; : >"$case_dir/net-basix-tor-egress"; : >"$case_dir/net-basix-scrapling-internal"; MOCK_CONFIG_IMAGE="sha256:$tor_id" MOCK_ISTOR=false run_installer
check 'external Tor failure preserves a preexisting canonical sidecar' 9 'IsTor=true' 'podman rm -f basix-scrapling-tor|codex mcp add'
make_mocks; MOCK_HANDSHAKE=fail run_installer
grep -q 'podman rm -f basix-scrapling-tor' "$log" || status=99
check 'failed MCP handshake rolls back new runtime and blocks registration' 9 'handshake failed' 'codex mcp add'
make_mocks; MOCK_HEALTH=unhealthy run_installer; check 'unhealthy Tor blocks registration' 9 'failed validation or bootstrap' 'codex mcp add'
make_mocks; run_installer --runtime docker; check 'Docker path avoids Podman-only DNS flag' 0 'installation verified' ''
make_mocks; run_installer --wat; check 'unknown option rejected' 2 'Unknown option' ''
make_mocks; run_installer --image 'bad image'; check 'bad image rejected' 2 'Invalid OCI image' ''

secret='[{"name":"neutral","url":"https://token:very-secret@host/SCRAPLING","env":{"API_TOKEN":"never-print"}}]'
make_mocks; printf '%s\n' "$secret" >"$case_dir/list.json"; run_installer --dry-run; if grep -qE 'very-secret|never-print' "$case_dir/output"; then status=99; fi; check 'diagnostics redact URL credentials and env values' 0 '<redacted>' ''

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
