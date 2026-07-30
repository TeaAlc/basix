#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
passes=0 failures=0
ok() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
not_ok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
helper="$ROOT/setup/lib/manage_developer_instructions.py"
instructions="$ROOT/setup/developer_instruction.md"

check 'specific verifier name' test ! -e "$ROOT/tests/verify.sh"
check 'shell syntax' bash -n "$ROOT/setup/install_as_plugin.sh" "$ROOT/setup/install_for_project.sh" "$ROOT/setup/install_ory_lumen.sh" "$ROOT/tests/verify-basix.sh" "$ROOT/setup/lib/common.sh" "$ROOT/scripts/run-file-explorer-benchmark.sh" "$0"
validator="$ROOT/skills/basix-agent-authoring/scripts/validate.py"
check 'Python syntax' env PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/basix-test-pycache" python3 -m py_compile "$helper" "$validator"
check 'JSON, TOML, and naming metadata' python3 - "$ROOT" <<'PY'
import json,re,sys,tomllib
from pathlib import Path
r=Path(sys.argv[1]); m=json.loads((r/'.codex-plugin/plugin.json').read_text())
assert m['name']=='basix' and m['version']=='0.1.0' and m['skills']=='./skills/' and 'agents' not in m
market=json.loads((r/'.agents/plugins/marketplace.json').read_text())
assert market['name']=='basix-local' and market['plugins'][0]['name']=='basix'
assert market['plugins'][0]['source']['path']=='./'
native=list((r/'agents/native').glob('*.toml')); assert native
for path in native: assert tomllib.loads(path.read_text())['description'].startswith('Basix-Agent: ')
for path in (r/'skills').glob('*/SKILL.md'):
    assert re.search(r'(?m)^description: Basix-Skill: ', path.read_text()), path
    ui=path.parent/'agents/openai.yaml'
    if ui.exists(): assert re.search(r'(?m)^\s*short_description: "Basix-Skill: ', ui.read_text()), ui
assert not (r/'agents/exec').exists()
schema=json.loads((r/'skills/basix-agent-authoring/references/message.schema.json').read_text())
assert schema['$id'].startswith('https://basix.local/')
PY

config="$case_dir/new.toml"
if python3 "$helper" add --config "$config" --instructions "$instructions" && python3 - "$config" <<'PY'
import sys,tomllib
v=tomllib.load(open(sys.argv[1],'rb'))['developer_instructions']
assert v.count('basix:developer-instructions:start')==1
PY
then ok 'helper adds missing config'; else not_ok 'helper adds missing config'; fi

printf '%s\n' 'model = "other"' 'developer_instructions = "foreign"' '[agents]' 'enabled = true' > "$case_dir/merge.toml"
if python3 "$helper" add --config "$case_dir/merge.toml" --instructions "$instructions" && first=$(sha256sum "$case_dir/merge.toml") && python3 "$helper" add --config "$case_dir/merge.toml" --instructions "$instructions" && second=$(sha256sum "$case_dir/merge.toml") && [[ $first == "$second" ]] && python3 - "$case_dir/merge.toml" <<'PY'
import sys,tomllib
d=tomllib.load(open(sys.argv[1],'rb')); v=d['developer_instructions']
assert d['model']=='other' and d['agents']['enabled'] is True and v.startswith('foreign') and v.count('basix:developer-instructions:start')==1
PY
then ok 'helper preserves foreign data and is idempotent'; else not_ok 'helper preserves foreign data and is idempotent'; fi

if python3 "$helper" remove --config "$case_dir/merge.toml" && python3 - "$case_dir/merge.toml" <<'PY'
import sys,tomllib
d=tomllib.load(open(sys.argv[1],'rb')); assert d['developer_instructions']=='foreign' and d['model']=='other'
PY
then ok 'helper removes only managed block'; else not_ok 'helper removes only managed block'; fi

for bad in invalid marker type; do
  file="$case_dir/bad-$bad.toml"
  case $bad in
    invalid) printf '%s\n' 'not = [' > "$file" ;;
    marker) printf '%s\n' 'developer_instructions = "<!-- basix:developer-instructions:start -->"' > "$file" ;;
    type) printf '%s\n' 'developer_instructions = 7' > "$file" ;;
  esac
  before=$(sha256sum "$file")
  if python3 "$helper" add --config "$file" --instructions "$instructions" >/dev/null 2>&1 || [[ $(sha256sum "$file") != "$before" ]]; then not_ok "helper rejects $bad without changes"; else ok "helper rejects $bad without changes"; fi
done

make_mock() {
  mock="$case_dir/mock"; mkdir -p "$mock"
cat > "$mock/codex" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == mcp && $2 == get && $3 == lumen ]]; then printf '{"name":"lumen","enabled":true,"disabled_reason":null}\n'; exit; fi
printf '%s\n' "$*" >> "$MOCK_LOG"
exit "${MOCK_EXIT:-0}"
EOF
  chmod +x "$mock/codex"
}
make_mock

home="$case_dir/home"; log="$case_dir/global.log"; : > "$log"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" >/dev/null && [[ -L $home/agents/basix-researcher.toml && -L $home/agents/basix-file-explorer.toml && ! -e $home/basix-luna-researcher.config.toml ]] && grep -q 'plugin marketplace add' "$log" && grep -q 'plugin add basix@basix-local' "$log"; then ok 'global installs only native agents'; else not_ok 'global installs only native agents'; fi
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" >/dev/null && [[ $(grep -c 'basix:developer-instructions:start' "$home/config.toml") -eq 1 ]]; then ok 'global reinstall is idempotent'; else not_ok 'global reinstall is idempotent'; fi
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" --uninstall >/dev/null && [[ ! -e $home/agents/basix-researcher.toml && ! -e $home/agents/basix-file-explorer.toml && ! -e $home/basix-luna-researcher.config.toml ]] && ! grep -q 'basix:developer-instructions:start' "$home/config.toml"; then ok 'global uninstall removes managed state'; else not_ok 'global uninstall removes managed state'; fi

legacy_source="$case_dir/legacy-profile"; printf 'managed legacy\n' > "$legacy_source"
upgrade_home="$case_dir/upgrade-home"; mkdir -p "$upgrade_home"; ln -s "$legacy_source" "$upgrade_home/basix-luna-researcher.config.toml"
printf 'link\t%s\t%s\n' "$upgrade_home/basix-luna-researcher.config.toml" "$legacy_source" > "$upgrade_home/.basix-install-state"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$upgrade_home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >/dev/null && [[ ! -e $upgrade_home/basix-luna-researcher.config.toml ]]; then ok 'upgrade removes unchanged managed legacy profile'; else not_ok 'upgrade removes unchanged managed legacy profile'; fi

changed_home="$case_dir/changed-upgrade-home"; mkdir -p "$changed_home"; printf 'locally changed\n' > "$changed_home/basix-luna-researcher.config.toml"
printf 'copy\t%s\t%s\n' "$changed_home/basix-luna-researcher.config.toml" "$(printf 'old managed content\n' | sha256sum | awk '{print $1}')" > "$changed_home/.basix-install-state"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$changed_home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >/dev/null && grep -Fqx 'locally changed' "$changed_home/basix-luna-researcher.config.toml"; then ok 'upgrade preserves changed legacy profile'; else not_ok 'upgrade preserves changed legacy profile'; fi

foreign_home="$case_dir/foreign-upgrade-home"; mkdir -p "$foreign_home"; printf 'foreign\n' > "$foreign_home/basix-luna-researcher.config.toml"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$foreign_home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >/dev/null && grep -Fqx 'foreign' "$foreign_home/basix-luna-researcher.config.toml"; then ok 'upgrade preserves unrecorded legacy profile'; else not_ok 'upgrade preserves unrecorded legacy profile'; fi

multi_bundle="$case_dir/multi-bundle"; multi_home="$case_dir/multi-home"
cp -R "$ROOT" "$multi_bundle"
cp "$multi_bundle/agents/native/basix-researcher.toml" "$multi_bundle/agents/native/second-agent.toml"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$multi_home" "$multi_bundle/setup/install_as_plugin.sh" --install-lumen no >/dev/null && [[ -L $multi_home/agents/basix-researcher.toml && -L $multi_home/agents/second-agent.toml ]]; then ok 'global automatically installs every native agent'; else not_ok 'global automatically installs every native agent'; fi
multi_project="$case_dir/multi-project"
if PATH="$mock:$PATH" MOCK_LOG="$log" "$multi_bundle/setup/install_for_project.sh" "$multi_project" --install-lumen no --lumen-index no >/dev/null && [[ -L $multi_project/.codex/agents/basix-researcher.toml && -L $multi_project/.codex/agents/second-agent.toml ]]; then ok 'project automatically installs every native agent'; else not_ok 'project automatically installs every native agent'; fi

dry="$case_dir/dry"; if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$dry" "$ROOT/setup/install_as_plugin.sh" --dry-run >/dev/null && [[ ! -e $dry ]]; then ok 'global dry run does not mutate'; else not_ok 'global dry run does not mutate'; fi

project="$case_dir/project with spaces"
if PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" "$project" --mode link >/dev/null && [[ -L $project/.basix && -L $project/.agents/skills/basix/SKILL.md && -L $project/.agents/skills/basix-agent-authoring/SKILL.md && -L $project/.agents/skills/basix-agent-authoring/references/message.schema.json && -L $project/.agents/skills/basix-agent-authoring/scripts/validate.py && -L $project/.codex/agents/basix-researcher.toml && -L $project/.codex/agents/basix-file-explorer.toml ]]; then ok 'project installs complete skills and native agents'; else not_ok 'project installs complete skills and native agents'; fi
if PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" "$project" --uninstall >/dev/null && [[ ! -e $project/.basix && ! -e $project/.agents/skills/basix/SKILL.md && ! -e $project/.agents/skills/basix-agent-authoring ]]; then ok 'project uninstall removes managed links'; else not_ok 'project uninstall removes managed links'; fi

lumen_case="$case_dir/lumen install"; lumen_mock="$lumen_case/mock"; lumen_home="$lumen_case/home"; lumen_codex_home="$lumen_case/codex home"
mkdir -p "$lumen_mock" "$lumen_home"
cat > "$lumen_mock/codex" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == mcp && $2 == get ]]; then [[ -f $LUMEN_MCP_STATE ]] || exit 1; printf '{"name":"lumen","enabled":true}\n'; exit; fi
if [[ $1 == mcp && $2 == add ]]; then touch "$LUMEN_MCP_STATE"; printf '%s\n' "$*" >> "$LUMEN_LOG"; exit; fi
printf '%s\n' "$*" >> "$LUMEN_LOG"
exit 0
EOF
cat > "$lumen_mock/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LUMEN_LOG"
target=$3
mkdir -p "$target/scripts" "$target/skills"
printf '#!/usr/bin/env bash\n' > "$target/scripts/run"
chmod +x "$target/scripts/run"
EOF
chmod +x "$lumen_mock/codex" "$lumen_mock/git"
lumen_log="$lumen_case/actions.log"; lumen_state="$lumen_case/mcp.state"
if PATH="$lumen_mock:$PATH" HOME="$lumen_home" CODEX_HOME="$lumen_codex_home" LUMEN_LOG="$lumen_log" LUMEN_MCP_STATE="$lumen_state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null && [[ -L $lumen_home/.agents/skills/lumen && $(readlink "$lumen_home/.agents/skills/lumen") == "$lumen_codex_home/lumen/skills" ]] && grep -Fq "clone https://github.com/ory/lumen.git $lumen_codex_home/lumen" "$lumen_log" && grep -Fq 'mcp add lumen --' "$lumen_log"; then ok 'Ory Lumen installer clones, links, and registers MCP'; else not_ok 'Ory Lumen installer clones, links, and registers MCP'; fi
before=$(sha256sum "$lumen_log")
if PATH="$lumen_mock:$PATH" HOME="$lumen_home" CODEX_HOME="$lumen_codex_home" LUMEN_LOG="$lumen_log" LUMEN_MCP_STATE="$lumen_state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null && [[ $(sha256sum "$lumen_log") == "$before" ]]; then ok 'Ory Lumen reinstall is idempotent'; else not_ok 'Ory Lumen reinstall is idempotent'; fi

global_lumen_case="$case_dir/global-installs-lumen"; mkdir -p "$global_lumen_case/home"
if PATH="$lumen_mock:$PATH" HOME="$global_lumen_case/home" CODEX_HOME="$global_lumen_case/codex" LUMEN_LOG="$global_lumen_case/actions.log" LUMEN_MCP_STATE="$global_lumen_case/mcp.state" "$ROOT/setup/install_as_plugin.sh" >/dev/null && [[ -f $global_lumen_case/mcp.state && -L $global_lumen_case/home/.agents/skills/lumen ]]; then ok 'global installer installs missing Lumen by default'; else not_ok 'global installer installs missing Lumen by default'; fi

project_lumen_case="$case_dir/project-installs-lumen"; mkdir -p "$project_lumen_case/home"
if PATH="$lumen_mock:$PATH" HOME="$project_lumen_case/home" CODEX_HOME="$project_lumen_case/codex" LUMEN_LOG="$project_lumen_case/actions.log" LUMEN_MCP_STATE="$project_lumen_case/mcp.state" "$ROOT/setup/install_for_project.sh" "$project_lumen_case/work" --lumen-index no >/dev/null && [[ -f $project_lumen_case/mcp.state && -L $project_lumen_case/home/.agents/skills/lumen ]]; then ok 'project installer installs missing Lumen by default'; else not_ok 'project installer installs missing Lumen by default'; fi

index_case="$case_dir/index project"; index_mock="$index_case/mock"; index_project="$index_case/project root"; mkdir -p "$index_mock" "$index_project/lumen/scripts"
index_launcher="$index_project/lumen/scripts/run"; index_log="$index_case/index.log"
cat > "$index_mock/codex" <<EOF
#!/usr/bin/env bash
if [[ \$1 == mcp && \$2 == get ]]; then printf '%s\n' '{"name":"lumen","enabled":true,"transport":{"type":"stdio","command":"$index_launcher","args":["stdio"]}}'; exit; fi
exit 1
EOF
cat > "$index_launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$PWD" "$*" >> "$INDEX_LOG"
EOF
chmod +x "$index_mock/codex" "$index_launcher"
if PATH="$index_mock:$PATH" INDEX_LOG="$index_log" "$ROOT/setup/install_for_project.sh" "$index_project/work tree" --install-lumen no --lumen-index yes >/dev/null && grep -Fqx "$index_project/work tree"$'\t''index .' "$index_log"; then ok 'project installer runs lumen index in project root'; else not_ok 'project installer runs lumen index in project root'; fi

missing_mock="$case_dir/missing-mcp"; mkdir -p "$missing_mock"
cat > "$missing_mock/codex" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$missing_mock/codex"
warning_output="$case_dir/lumen-warning.out"
if PATH="$missing_mock:$PATH" "$ROOT/setup/install_for_project.sh" "$case_dir/no-lumen-project" --install-lumen no --lumen-index yes >"$warning_output" 2>&1 && grep -Fq $'\033[38;5;208mwarning:' "$warning_output" && grep -Fq 'lumen index . is unavailable' "$warning_output"; then ok 'project installer warns in orange when Lumen MCP is missing'; else not_ok 'project installer warns in orange when Lumen MCP is missing'; fi

dry_lumen="$case_dir/dry-lumen"
if PATH="$lumen_mock:$PATH" HOME="$dry_lumen/home" CODEX_HOME="$dry_lumen/codex" LUMEN_LOG="$dry_lumen/log" LUMEN_MCP_STATE="$dry_lumen/state" "$ROOT/setup/install_ory_lumen.sh" --dry-run >/dev/null && [[ ! -e $dry_lumen ]]; then ok 'Ory Lumen dry run does not mutate'; else not_ok 'Ory Lumen dry run does not mutate'; fi

copy_project="$case_dir/copy-project"
if "$ROOT/setup/install_for_project.sh" "$copy_project" --mode copy >/dev/null && [[ -d $copy_project/.basix && ! -L $copy_project/.codex/agents/basix-researcher.toml ]]; then ok 'project copy installation'; else not_ok 'project copy installation'; fi
printf 'changed\n' >> "$copy_project/.codex/agents/basix-researcher.toml"
if "$ROOT/setup/install_for_project.sh" "$copy_project" --uninstall >/dev/null && [[ -f $copy_project/.codex/agents/basix-researcher.toml ]]; then ok 'uninstall preserves changed project file'; else not_ok 'uninstall preserves changed project file'; fi

explorer_runner_log="$case_dir/explorer-runner.args"
cat > "$mock/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$MOCK_LOG"
EOF
chmod +x "$mock/codex"
if PATH="$mock:$PATH" MOCK_LOG="$explorer_runner_log" "$ROOT/scripts/run-file-explorer-benchmark.sh" --prompt 'find evidence' --workdir "$case_dir" --output "$case_dir/explorer result" && python3 - "$explorer_runner_log" "$case_dir" <<'PY'
import sys
a=open(sys.argv[1],'rb').read().split(b'\0')[:-1]; a=[x.decode() for x in a]
for value in ('exec','--ephemeral','--ignore-user-config','--ignore-rules','--skip-git-repo-check','--sandbox','read-only','--model','gpt-5.6-luna','--cd',sys.argv[2],'--json','--output-last-message','find evidence'): assert value in a
assert 'model_reasoning_effort="low"' in a
assert 'web_search="disabled"' in a
instructions=next(x for x in a if x.startswith('developer_instructions='))
assert 'rg --files --hidden' in instructions and 'Never use Lumen' in instructions
assert 'basix-agent-authoring:contract' not in instructions
PY
then ok 'file explorer runner isolates Luna low search configuration'; else not_ok 'file explorer runner isolates Luna low search configuration'; fi

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
