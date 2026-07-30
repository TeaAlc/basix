#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
passes=0
failures=0

make_mocks() {
  case_dir=$(mktemp -d)
  mkdir -p "$case_dir/bin"
  log="$case_dir/log"
  : > "$log"

  cat > "$case_dir/bin/podman" <<'EOF'
#!/usr/bin/env bash
runtime=${0##*/}
printf '%s %s\n' "$runtime" "$*" >> "$MOCK_LOG"
case "${1-}" in
  info) [[ ${MOCK_RUNTIME_INFO:-ok} == ok ]] ;;
  pull) [[ ${MOCK_RUNTIME_PULL:-ok} == ok ]] ;;
  run) [[ ${MOCK_RUNTIME_RUN:-ok} == ok ]] ;;
  image) [[ ${MOCK_RUNTIME_INSPECT:-ok} == ok ]] ;;
  *) exit 1 ;;
esac
EOF
  cat > "$case_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$MOCK_LOG"
if [[ $* == 'mcp --help' ]]; then printf 'Commands: add get\n'; exit 0; fi
if [[ $* == 'mcp get --help' ]]; then printf 'Options: --json\n'; exit 0; fi
if [[ ${1-} == mcp && ${2-} == get ]]; then
  if [[ -f "$MOCK_STATE" && ${MOCK_CONFIG:-missing} != final_bad ]]; then
    image=${MOCK_IMAGE:-docker.io/pyd4vinci/scrapling:latest}
    runtime=$(<"$MOCK_STATE")
    printf '{"name":"scrapling","transport":{"type":"stdio","command":"%s","args":["run","-i","--rm","%s","mcp"],"env":null,"cwd":null}}\n' "$runtime" "$image"
    exit 0
  fi
  case "${MOCK_CONFIG:-missing}" in
    missing) printf "Error: No MCP server named 'scrapling' found.\n" >&2; exit 1 ;;
    error) printf 'configuration unreadable\n' >&2; exit 1 ;;
    identical) image=${MOCK_IMAGE:-docker.io/pyd4vinci/scrapling:latest} ;;
    conflict) image='different/image:tag' ;;
    final_bad)
      if [[ -f "$MOCK_STATE" ]]; then image='wrong/image:tag'; else printf "Error: No MCP server named 'scrapling' found.\n" >&2; exit 1; fi
      ;;
  esac
  runtime=${MOCK_CONFIG_RUNTIME:-podman}
  printf '{"name":"scrapling","transport":{"type":"stdio","command":"%s","args":["run","-i","--rm","%s","mcp"],"env":null,"cwd":null}}\n' "$runtime" "$image"
  exit 0
fi
if [[ ${1-} == mcp && ${2-} == add ]]; then
  [[ ${MOCK_CODEX_ADD:-ok} == ok ]] || exit 1
  printf '%s\n' "${5-}" > "$MOCK_STATE"
  exit 0
fi
exit 1
EOF
  cp "$case_dir/bin/podman" "$case_dir/bin/docker"
  chmod +x "$case_dir/bin/podman" "$case_dir/bin/docker" "$case_dir/bin/codex"
  for tool in bash grep mktemp rm sed tr; do
    ln -s "$(command -v "$tool")" "$case_dir/bin/$tool"
  done
}

run_installer() {
  output_file="$case_dir/output"
  set +e
  PATH="$case_dir/bin" MOCK_LOG="$log" MOCK_STATE="$case_dir/state" \
    "$ROOT/src/setup/install-scrapling-codex.sh" "$@" >"$output_file" 2>&1
  status=$?
  set -e
}

assert_case() {
  local name="$1" expected_status="$2" output_pattern="$3" log_pattern="${4-}"
  if [[ $status -eq $expected_status ]] && grep -qE "$output_pattern" "$output_file" && { [[ -z "$log_pattern" ]] || grep -qE "$log_pattern" "$log"; }; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (status=%s)\n' "$name" "$status"
    sed -n '1,100p' "$output_file"
    failures=$((failures + 1))
  fi
  rm -rf "$case_dir"
}

set -e

make_mocks; MOCK_CONFIG=missing run_installer; assert_case 'new installation prefers Podman' 0 'installation verified' 'codex mcp add scrapling -- podman run -i --rm'
make_mocks; MOCK_CONFIG=identical run_installer; assert_case 'identical Podman configuration exits unchanged' 0 'already configured correctly'
make_mocks; MOCK_CONFIG=conflict run_installer; assert_case 'conflict rejected' 7 'different configuration'
make_mocks; MOCK_CONFIG=conflict run_installer --force; assert_case 'force replaces conflict' 0 'installation verified' 'codex mcp add scrapling'
make_mocks; MOCK_CONFIG=missing run_installer --dry-run
if grep -qE '^(podman|docker) (pull|run)|^codex mcp add' "$log"; then status=99; printf 'mutation found\n' >> "$output_file"; fi
assert_case 'dry run has no mutations' 0 'No image was pulled' '^codex mcp get scrapling --json$'

make_mocks; rm "$case_dir/bin/podman"; MOCK_CONFIG=missing MOCK_CONFIG_RUNTIME=docker run_installer
assert_case 'auto falls back to Docker' 0 'installation verified' 'codex mcp add scrapling -- docker run -i --rm'
make_mocks; MOCK_CONFIG=missing MOCK_CONFIG_RUNTIME=docker run_installer --runtime docker
assert_case 'explicit Docker overrides preference' 0 'installation verified' 'codex mcp add scrapling -- docker run -i --rm'
make_mocks; MOCK_CONFIG=identical MOCK_CONFIG_RUNTIME=docker run_installer
assert_case 'Docker config conflicts when Podman is preferred' 7 'different configuration'
make_mocks; MOCK_CONFIG=identical MOCK_CONFIG_RUNTIME=docker run_installer --force
assert_case 'force migrates Docker config to Podman' 0 'installation verified' 'codex mcp add scrapling -- podman run -i --rm'

make_mocks; MOCK_CONFIG=missing run_installer --wat; assert_case 'unknown option rejected' 2 'Unknown option'
make_mocks; MOCK_CONFIG=missing run_installer --image 'bad image'; assert_case 'invalid image rejected' 2 'Invalid OCI image'
make_mocks; MOCK_CONFIG=missing run_installer --runtime containerd; assert_case 'invalid runtime rejected' 2 'Invalid runtime'

case_dir=$(mktemp -d); mkdir "$case_dir/bin"; ln -s "$(command -v bash)" "$case_dir/bin/bash"; output_file="$case_dir/output"; set +e
PATH="$case_dir/bin" "$ROOT/src/setup/install-scrapling-codex.sh" >"$output_file" 2>&1; status=$?; set -e
log=/dev/null; assert_case 'missing runtimes rejected' 3 'Neither Podman nor Docker CLI'

make_mocks; rm "$case_dir/bin/podman"; run_installer --runtime podman
assert_case 'missing explicitly requested runtime rejected' 3 "Requested container runtime 'podman' was not found"

make_mocks; rm "$case_dir/bin/codex"; run_installer; assert_case 'missing Codex rejected' 3 'Codex CLI not found'

make_mocks
sed -i 's/printf '\''Commands: add get\\n'\''/printf '\''Commands: list\\n'\''/' "$case_dir/bin/codex"
run_installer
assert_case 'Codex without MCP add-get rejected' 8 'lacks required MCP add/get'

make_mocks; MOCK_CONFIG=missing MOCK_RUNTIME_INFO=fail run_installer; assert_case 'runtime failure reported' 4 'Cannot use podman'
make_mocks; MOCK_CONFIG=missing MOCK_RUNTIME_PULL=fail run_installer; assert_case 'pull failure reported' 5 'Could not pull OCI image'
make_mocks; MOCK_CONFIG=missing MOCK_RUNTIME_RUN=fail run_installer; assert_case 'entry point failure reported' 6 'expected `mcp` entry point'
make_mocks; MOCK_CONFIG=error run_installer; assert_case 'Codex get failure reported' 8 'could not inspect'
make_mocks; MOCK_CONFIG=missing MOCK_CODEX_ADD=fail run_installer; assert_case 'Codex add failure reported' 8 'could not register'
make_mocks; MOCK_CONFIG=missing MOCK_RUNTIME_INSPECT=fail run_installer; assert_case 'final image validation failure' 9 'image .* is not available locally'
make_mocks; MOCK_CONFIG=final_bad run_installer; assert_case 'final config validation failure' 9 'configuration does not match'

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
