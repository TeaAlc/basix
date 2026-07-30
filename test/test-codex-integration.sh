#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v codex >/dev/null || { printf 'SKIP: codex CLI not installed\n'; exit 0; }

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/codex-home"

cat > "$test_dir/bin/podman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_dir/bin/podman"

PATH="$test_dir/bin:$PATH" CODEX_HOME="$test_dir/codex-home" "$ROOT/src/setup/install-scrapling-codex.sh" >/dev/null
json=$(CODEX_HOME="$test_dir/codex-home" codex mcp get scrapling --json 2>/dev/null)
compact=${json//$'\n'/}; compact=${compact// /}
expected='"command":"podman","args":["run","-i","--rm","docker.io/pyd4vinci/scrapling:latest","mcp"]'
[[ "$compact" == *'"type":"stdio"'* && "$compact" == *"$expected"* && "$compact" == *'"env":null'* && "$compact" == *'"cwd":null'* ]]
printf 'ok - real Codex CLI stored the exact safe Podman stdio transport\n'
