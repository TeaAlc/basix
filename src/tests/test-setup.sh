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
check 'shell syntax' bash -n "$ROOT/setup/install_as_plugin.sh" "$ROOT/setup/install_for_project.sh" "$ROOT/setup/install_ory_lumen.sh" "$ROOT/tests/verify-basix.sh" "$ROOT/setup/lib/common.sh" "$ROOT/scripts/run-file-explorer-benchmark.sh" "$ROOT/scripts/run-pager-smoke.sh" "$0"
validator="$ROOT/skills/basix-agent-authoring/scripts/validate.py"
check 'Python syntax' env PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/basix-test-pycache" python3 -m py_compile "$helper" "$validator"
check 'JSON, TOML, and naming metadata' python3 - "$ROOT" <<'PY'
import json,re,sys,tomllib
from pathlib import Path
r=Path(sys.argv[1]); m=json.loads((r/'plugin/plugin.json').read_text())
assert m['name']=='basix' and m['version']=='0.1.0' and m['skills']=='./skills/' and 'agents' not in m
market=json.loads((r/'plugin/marketplace.json').read_text())
assert market['name']=='basix-local' and market['plugins'][0]['name']=='basix'
assert market['plugins'][0]['source']['path']=='./'
native=list((r/'agents/native').glob('*.toml')); assert native
for path in native: assert tomllib.loads(path.read_text())['description'].startswith('Basix-Agent: ')
pager=tomllib.loads((r/'agents/native/basix-pager.toml').read_text())
assert pager['name']=='basix_pager' and pager['model']=='gpt-5.6-luna' and pager['model_reasoning_effort']=='max'
assert pager['sandbox_mode']=='workspace-write'
for profile in ('ui_ux','frontend','backend_web','fullstack','integration'): assert f'`{profile}`' in pager['developer_instructions']
assert 'fork_turns="none"' in pager['developer_instructions']
assert '.basix/contracts/<chain-id>.md' in pager['developer_instructions']
verifier=tomllib.loads((r/'agents/native/basix-verifier.toml').read_text())
assert verifier['name']=='basix_verifier' and verifier['model']=='gpt-5.6-luna' and verifier['model_reasoning_effort']=='max'
assert verifier['sandbox_mode']=='read-only'
for text in ('immutable', 'inconclusive', 'cycle_revision', 'fork_turns="none"', 'followup_task'):
    assert text in verifier['developer_instructions'], text
for path in (r/'skills').glob('*/SKILL.md'):
    assert re.search(r'(?m)^description: Basix-Skill: ', path.read_text()), path
    ui=path.parent/'agents/openai.yaml'
    if ui.exists(): assert re.search(r'(?m)^\s*short_description: "Basix-Skill: ', ui.read_text()), ui
assert not (r/'agents/exec').exists()
assert not any(path.name.startswith('.') for path in r.rglob('*') if path.is_dir())
schema=json.loads((r/'skills/basix-agent-authoring/references/message.schema.json').read_text())
assert schema['$id'].startswith('https://basix.local/')
PY

if python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
readme = ' '.join((root.parent / 'README.md').read_text().split())
installation = ' '.join((root / 'docs/installation.md').read_text().split())
assert 'Exact current-manifest file targets also converge' in readme
assert 'only unrecorded foreign directories or' in readme
assert 'including state-less targets' in installation
assert 'Exact current-manifest file targets still converge' in installation
assert 'targets outside the current manifest' in installation
assert 'Unrecorded targets and physical aliases' not in readme
assert 'unrecorded targets, unreadable sources' not in installation
PY
then ok 'installation docs distinguish known manifest files from foreign targets'; else not_ok 'installation docs distinguish known manifest files from foreign targets'; fi

config="$case_dir/new.toml"
if python3 "$helper" add --config "$config" --instructions "$instructions" && python3 - "$config" <<'PY'
import sys,tomllib
v=tomllib.load(open(sys.argv[1],'rb'))['developer_instructions']
assert v.count('basix:developer-instructions:start')==1
PY
then ok 'helper adds missing config'; else not_ok 'helper adds missing config'; fi

if python3 - "$ROOT" "$config" <<'PY'
import re, sys, tomllib
from pathlib import Path

root = Path(sys.argv[1])
policy = tomllib.load(open(sys.argv[2], 'rb'))['developer_instructions']
for text in (
    '## Basix conventions',
    'Do not use gender-inclusive language',
    'first read the Basix router skill',
    'only once per session',
    '## Agent selection',
    '## Agent management',
    'must not perform the same task or any overlapping part in parallel',
    '## Mandatory delegation',
    'Whenever invoking Python, set `PYTHONDONTWRITEBYTECODE=1`',
    'Assign agents only concrete, bounded tasks',
    'Delegate every task requiring current or external facts',
    'before the third filesystem-exploration tool call',
    'basix_researcher',
    'basix_file_explorer',
    'basix_pager',
    'basix_verifier',
):
    assert text in policy, text
for removed in ('Subagent confirmations', 'timeout_ms', 'task_profile',
                'intermediate_result', 'followup_task', '.basix/contracts/',
                'Adaptive pager selection and lifecycle', 'Read-only verification lifecycle'):
    assert removed not in policy, removed

skill = (root / 'skills/basix/SKILL.md').read_text()
for text in ('## Root orchestration', 'fork_turns="none"', 'unique `task_name`',
             'timeout_ms: 120000', 'visible confirmation', 'started: <assignment>',
             'failed to start: <reason>', 'status: <conclusion>', 'generic web access',
             'final_result', 'fresh agent and task name', 'Relay assignments and results',
             'intermediate review handoff'):
    assert text in skill, text

description_requirements = {
    'basix-file-explorer.toml': ('file explorer', 'read-only', 'assign'),
    'basix-researcher.toml': ('researcher', 'read-only', 'assign'),
    'basix-pager.toml': ('pager', 'workspace-writing', 'authorized'),
    'basix-verifier.toml': ('verifier', 'read-only', 'frozen'),
}
for name, phrases in description_requirements.items():
    description = tomllib.loads((root / 'agents/native' / name).read_text())['description']
    assert description.startswith('Basix-Agent: '), name
    for phrase in phrases:
        assert phrase in description.lower(), (name, phrase)
classification = (root / 'skills/basix-agent-authoring/references/model-classification.md').read_text()
for text in ('Highly complex reference roles', '| Highly complex | `gpt-5.6-luna`, `max` |',
             'gpt-5.6-luna` with `max` reasoning', 'bug hunting plus bug fixing', 'coordinating subagents',
             'workspace-write', 'explicit-sandbox-override', 'Every other native Basix', 'agent remains `read-only`',
             '`basix_verifier` performs difficult source-code'):
    assert text in classification, text
agent_docs = ' '.join((root / 'docs/agents.md').read_text().split())
for text in ('Verification assignment and lifecycle', 'basix_verifier', 'immutable', 'verification_id:',
             'mutation_window:', 'report_strictness:', 'fresh verifier',
             'Manual pager smoke scenarios', 'run-pager-smoke.sh', 'real 120-second', 'intentionally not automated'):
    assert text in agent_docs, text
contract = (root / 'skills/basix-agent-authoring/references/communication-contract.md').read_text()
assert 'version=1.2' in contract and 'cycle_revision' in contract
assert '`Berichtsbeginn an /root übermittelt.`' in contract
assert 'automatically resume the interrupted task' in contract
assert re.search(r'first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds', contract)
for path in (root / 'agents/native').glob('*.toml'):
    text = path.read_text()
    assert 'version=1.2' in text, path
    assert '`report_started`' in text, path
    assert re.search(r'first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds', text), path
PY
then ok 'installed policy mandates basix_researcher without generic-web fallback'; else not_ok 'installed policy mandates basix_researcher without generic-web fallback'; fi

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

status_dir="$case_dir/helper-status"; mkdir -p "$status_dir"
status_config="$status_dir/config.toml"; status_changed="$status_dir/changed.md"
sed 's/<!-- basix:developer-instructions:end -->/status-test\n<!-- basix:developer-instructions:end -->/' "$instructions" > "$status_changed"
add_dry_output=$(python3 "$helper" add --config "$status_dir/dry-add.toml" --instructions "$instructions" --dry-run)
add_output=$(python3 "$helper" add --config "$status_config" --instructions "$instructions")
current_output=$(python3 "$helper" add --config "$status_config" --instructions "$instructions")
update_dry_output=$(python3 "$helper" add --config "$status_config" --instructions "$status_changed" --dry-run)
update_output=$(python3 "$helper" add --config "$status_config" --instructions "$status_changed")
remove_dry_output=$(python3 "$helper" remove --config "$status_config" --remove-empty-file --dry-run)
remove_output=$(python3 "$helper" remove --config "$status_config" --remove-empty-file)
missing_output=$(python3 "$helper" remove --config "$status_config" --remove-empty-file)
if [[ $add_dry_output == "Would add Basix developer instructions: $status_dir/dry-add.toml" && ! -e $status_dir/dry-add.toml &&
  $add_output == "Added Basix developer instructions: $status_config" &&
  $current_output == "Basix developer instructions already current: $status_config" &&
  $update_dry_output == "Would update Basix developer instructions: $status_config" &&
  $update_output == "Updated Basix developer instructions: $status_config" &&
  $remove_dry_output == *"Would remove Basix developer instructions: $status_config"* &&
  $remove_dry_output == *"Would remove empty configuration file: $status_config"* &&
  $remove_output == *"Removed empty configuration file: $status_config"* &&
  $missing_output == "Basix developer instructions not present: $status_config" && ! -e $status_config ]]; then
  ok 'helper reports add, update, no-op, remove, missing, empty-file, and dry-run states'
else
  not_ok 'helper reports add, update, no-op, remove, missing, empty-file, and dry-run states'
fi

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
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" >/dev/null &&
  [[ -L $home/agents/basix-researcher.toml && -L $home/agents/basix-file-explorer.toml && -L $home/agents/basix-pager.toml && -L $home/agents/basix-verifier.toml && ! -e $home/basix-luna-researcher.config.toml &&
    -f $home/basix-plugin-root/.codex-plugin/plugin.json && -f $home/basix-plugin-root/.agents/plugins/marketplace.json &&
    -L $home/basix-plugin-root/skills/basix/SKILL.md && $(readlink "$home/basix-plugin-root/skills/basix/SKILL.md") == "$ROOT/skills/basix/SKILL.md" ]] &&
  cmp -s "$ROOT/plugin/plugin.json" "$home/basix-plugin-root/.codex-plugin/plugin.json" &&
  cmp -s "$ROOT/plugin/marketplace.json" "$home/basix-plugin-root/.agents/plugins/marketplace.json" &&
  grep -Fq "plugin marketplace add $home/basix-plugin-root --json" "$log" && grep -q 'plugin add basix@basix-local' "$log" &&
  awk -F '\t' -v manifest="$home/basix-plugin-root/.codex-plugin/plugin.json" -v skill="$home/basix-plugin-root/skills/basix/SKILL.md" '$1 == "copy" && $2 == manifest { manifest_copy = 1 } $1 == "link" && $2 == skill { skill_link = 1 } END { exit !(manifest_copy && skill_link) }' "$home/.basix-install-state";
then ok 'global creates managed metadata and canonical skill links'; else not_ok 'global creates managed metadata and canonical skill links'; fi
if python3 - "$ROOT" "$home/config.toml" <<'PY'
import re, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1]); config = Path(sys.argv[2])
policy = tomllib.loads(config.read_text())['developer_instructions']
assert 'before the third filesystem-exploration tool call' in policy
assert 'Delegate every task requiring current or external facts' in policy
for role in ('basix_researcher', 'basix_file_explorer', 'basix_pager', 'basix_verifier'):
    assert role in policy, role
for removed in ('timeout_ms', 'task_profile', 'intermediate_result', 'followup_task'):
    assert removed not in policy, removed
assert re.search(r'first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds', (root / 'skills/basix-agent-authoring/references/communication-contract.md').read_text())
PY
then ok 'installed global policy keeps delegation thresholds without lifecycle details'; else not_ok 'installed global policy keeps delegation thresholds without lifecycle details'; fi
before_config=$(sha256sum "$home/config.toml")
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" >/dev/null && [[ $(sha256sum "$home/config.toml") == "$before_config" ]] && [[ $(grep -c 'basix:developer-instructions:start' "$home/config.toml") -eq 1 ]] && awk -F '\t' -v researcher="$home/agents/basix-researcher.toml" -v explorer="$home/agents/basix-file-explorer.toml" -v pager="$home/agents/basix-pager.toml" -v verifier="$home/agents/basix-verifier.toml" '$1 == "link" && $2 == researcher { researcher_link = 1 } $1 == "link" && $2 == explorer { explorer_link = 1 } $1 == "link" && $2 == pager { pager_link = 1 } $1 == "link" && $2 == verifier { verifier_link = 1 } END { exit !(researcher_link && explorer_link && pager_link && verifier_link) }' "$home/.basix-install-state"; then ok 'global reinstall is idempotent'; else not_ok 'global reinstall is idempotent'; fi
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" --uninstall >/dev/null && [[ ! -e $home/agents/basix-researcher.toml && ! -e $home/agents/basix-file-explorer.toml && ! -e $home/agents/basix-pager.toml && ! -e $home/agents/basix-verifier.toml && ! -e $home/basix-luna-researcher.config.toml ]] && ! grep -q 'basix:developer-instructions:start' "$home/config.toml"; then ok 'global uninstall removes managed state'; else not_ok 'global uninstall removes managed state'; fi

bundle_source="$case_dir/update-source"; cp -R "$ROOT" "$bundle_source"
update_home="$case_dir/update-home"; printf '\nupdate-test\n' >> "$bundle_source/skills/basix/SKILL.md"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$update_home" "$bundle_source/setup/install_as_plugin.sh" --install-lumen no >/dev/null &&
  grep -Fq update-test "$update_home/basix-plugin-root/skills/basix/SKILL.md" &&
  printf '\nsecond-update\n' >> "$bundle_source/skills/basix/SKILL.md" &&
  PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$update_home" "$bundle_source/setup/install_as_plugin.sh" --install-lumen no >/dev/null &&
  grep -Fq second-update "$update_home/basix-plugin-root/skills/basix/SKILL.md";
then ok 'global update synchronizes generated plugin bundle'; else not_ok 'global update synchronizes generated plugin bundle'; fi

mode_home="$case_dir/mode-home"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$mode_home" "$ROOT/setup/install_as_plugin.sh" --mode copy --install-lumen no >/dev/null &&
  [[ -f $mode_home/basix-plugin-root/skills/basix/SKILL.md && ! -L $mode_home/basix-plugin-root/skills/basix/SKILL.md &&
    -f $mode_home/basix-plugin-root/.codex-plugin/plugin.json && ! -L $mode_home/basix-plugin-root/.codex-plugin/plugin.json ]] &&
  printf '\nlocal-drift\n' >> "$mode_home/basix-plugin-root/skills/basix/SKILL.md" &&
  PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$mode_home" "$ROOT/setup/install_as_plugin.sh" --mode link --install-lumen no >/dev/null &&
  [[ -L $mode_home/basix-plugin-root/skills/basix/SKILL.md && $(readlink "$mode_home/basix-plugin-root/skills/basix/SKILL.md") == "$ROOT/skills/basix/SKILL.md" &&
    -f $mode_home/basix-plugin-root/.codex-plugin/plugin.json && ! -L $mode_home/basix-plugin-root/.codex-plugin/plugin.json ]] &&
  PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$mode_home" "$ROOT/setup/install_as_plugin.sh" --mode copy --install-lumen no >/dev/null &&
  [[ -f $mode_home/basix-plugin-root/skills/basix/SKILL.md && ! -L $mode_home/basix-plugin-root/skills/basix/SKILL.md ]]; then
  ok 'global plugin skills converge in both directions without force'
else not_ok 'global plugin skills converge in both directions without force'; fi

preserve_home="$case_dir/preserve-home"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$preserve_home" "$ROOT/setup/install_as_plugin.sh" --mode copy --install-lumen no >/dev/null &&
  printf '\nlocal-change\n' >> "$preserve_home/basix-plugin-root/skills/basix/SKILL.md" &&
  PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$preserve_home" "$ROOT/setup/install_as_plugin.sh" --uninstall >/dev/null &&
  grep -Fq local-change "$preserve_home/basix-plugin-root/skills/basix/SKILL.md" &&
  [[ ! -e $preserve_home/basix-plugin-root/.codex-plugin/plugin.json && ! -e $preserve_home/basix-plugin-root/.agents/plugins/marketplace.json ]];
then ok 'global uninstall preserves modified bundle files only'; else not_ok 'global uninstall preserves modified bundle files only'; fi

force_home="$case_dir/force-home"; mkdir -p "$force_home/basix-plugin-root/.codex-plugin"; printf 'foreign\n' > "$force_home/basix-plugin-root/.codex-plugin/plugin.json"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$force_home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >/dev/null &&
  cmp -s "$ROOT/plugin/plugin.json" "$force_home/basix-plugin-root/.codex-plugin/plugin.json";
then ok 'global manifest replaces state-less bundle-file conflicts'; else not_ok 'global manifest replaces state-less bundle-file conflicts'; fi

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

progress_home="$case_dir/progress-home"; progress_output="$case_dir/global-progress.out"
if PATH="$mock:$PATH" MOCK_LOG="$log" CODEX_HOME="$progress_home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >"$progress_output" &&
  grep -Fq "Target: $progress_home" "$progress_output" && grep -Fq 'Mode: link' "$progress_output" &&
  grep -Fq 'Agents' "$progress_output" && grep -Fq '✓ basix-researcher' "$progress_output" &&
  grep -Fq '✓ Developer instructions' "$progress_output" &&
  grep -Fq '✓ Marketplace' "$progress_output" && grep -Fq '✓ Plugin' "$progress_output" &&
  grep -Fq 'Result' "$progress_output" && grep -Fq '✓ Complete' "$progress_output" &&
  ! grep -Fq '<!-- basix:developer-instructions:start -->' "$progress_output"; then
  ok 'global installer reports compact phases without instruction contents'
else
  not_ok 'global installer reports compact phases without instruction contents'
fi

progress_project="$case_dir/progress-project"; project_progress_output="$case_dir/project-progress.out"
if PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" "$progress_project" --mode link --install-lumen no --lumen-index no >"$project_progress_output" &&
  grep -Fq "Target: $progress_project" "$project_progress_output" && grep -Fq 'Mode: link' "$project_progress_output" &&
  grep -Fq 'Skills' "$project_progress_output" && grep -Fq '✓ basix —' "$project_progress_output" &&
  grep -Fq '✓ Developer instructions' "$project_progress_output" &&
  grep -Fq -- '- Project index — Skipped' "$project_progress_output" &&
  grep -Fq 'Result' "$project_progress_output" && grep -Fq '✓ Complete' "$project_progress_output" &&
  ! grep -Fq '<!-- basix:developer-instructions:start -->' "$project_progress_output"; then
  ok 'project installer reports compact phases without instruction contents'
else
  not_ok 'project installer reports compact phases without instruction contents'
fi

current_project="$case_dir/current-project"; mkdir -p "$current_project"
if (cd "$current_project" && PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" --install-lumen no --lumen-index no >/dev/null) && [[ ! -e $current_project/.basix && -L $current_project/.agents/skills/basix/SKILL.md && -L $current_project/.agents/skills/basix-agent-authoring/SKILL.md && -L $current_project/.agents/skills/basix-agent-authoring/references/message.schema.json && -L $current_project/.agents/skills/basix-agent-authoring/scripts/validate.py && -L $current_project/.codex/agents/basix-researcher.toml && -L $current_project/.codex/agents/basix-file-explorer.toml && -L $current_project/.codex/agents/basix-pager.toml && -L $current_project/.codex/agents/basix-verifier.toml ]]; then ok 'project defaults to current working directory'; else not_ok 'project defaults to current working directory'; fi
if (cd "$current_project" && PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" --uninstall >/dev/null) && [[ ! -e $current_project/.basix && ! -e $current_project/.agents/skills/basix/SKILL.md && ! -e $current_project/.agents/skills/basix-agent-authoring && ! -e $current_project/.codex/agents/basix-researcher.toml && ! -e $current_project/.codex/agents/basix-file-explorer.toml && ! -e $current_project/.codex/agents/basix-pager.toml && ! -e $current_project/.codex/agents/basix-verifier.toml ]]; then ok 'project uninstall defaults to current working directory'; else not_ok 'project uninstall defaults to current working directory'; fi

project="$case_dir/project with spaces"
if PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" "$project" --mode link >/dev/null && [[ ! -e $project/.basix && -L $project/.agents/skills/basix/SKILL.md && -L $project/.agents/skills/basix-agent-authoring/SKILL.md && -L $project/.agents/skills/basix-agent-authoring/references/message.schema.json && -L $project/.agents/skills/basix-agent-authoring/scripts/validate.py && -L $project/.codex/agents/basix-researcher.toml && -L $project/.codex/agents/basix-file-explorer.toml && -L $project/.codex/agents/basix-pager.toml && -L $project/.codex/agents/basix-verifier.toml ]]; then ok 'project installs complete skills and native agents'; else not_ok 'project installs complete skills and native agents'; fi
if PATH="$mock:$PATH" MOCK_LOG="$log" "$ROOT/setup/install_for_project.sh" "$project" --uninstall >/dev/null && [[ ! -e $project/.basix && ! -e $project/.agents/skills/basix/SKILL.md && ! -e $project/.agents/skills/basix-agent-authoring && ! -e $project/.codex/agents/basix-pager.toml && ! -e $project/.codex/agents/basix-verifier.toml ]]; then ok 'project uninstall removes managed links'; else not_ok 'project uninstall removes managed links'; fi

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
if ! PATH="$missing_mock:$PATH" "$ROOT/setup/install_for_project.sh" "$case_dir/no-lumen-project" --install-lumen no --lumen-index yes >"$warning_output" 2>&1 && grep -Fq '✗ Project index' "$warning_output" && grep -Fq '✗ Failed' "$warning_output"; then ok 'explicit unavailable Lumen index fails safely'; else not_ok 'explicit unavailable Lumen index fails safely'; fi

dry_lumen="$case_dir/dry-lumen"
if PATH="$lumen_mock:$PATH" HOME="$dry_lumen/home" CODEX_HOME="$dry_lumen/codex" LUMEN_LOG="$dry_lumen/log" LUMEN_MCP_STATE="$dry_lumen/state" "$ROOT/setup/install_ory_lumen.sh" --dry-run >/dev/null && [[ ! -e $dry_lumen ]]; then ok 'Ory Lumen dry run does not mutate'; else not_ok 'Ory Lumen dry run does not mutate'; fi

copy_project="$case_dir/copy-project"
if "$ROOT/setup/install_for_project.sh" "$copy_project" --mode copy >/dev/null && [[ ! -e $copy_project/.basix && ! -L $copy_project/.codex/agents/basix-researcher.toml && -f $copy_project/.agents/skills/basix/SKILL.md ]]; then ok 'project copy installation writes direct independent targets'; else not_ok 'project copy installation writes direct independent targets'; fi
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

pager_runner_ok=true
for profile in ui_ux frontend backend_web fullstack integration; do
  pager_log="$case_dir/pager-$profile.args"
  if ! PATH="$mock:$PATH" MOCK_LOG="$pager_log" "$ROOT/scripts/run-pager-smoke.sh" --profile "$profile" --workdir "$case_dir" --trace "$case_dir/pager-$profile.trace" >/dev/null; then
    pager_runner_ok=false
  fi
done
if [[ $pager_runner_ok == true ]] && python3 - "$case_dir" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
for profile in ('ui_ux', 'frontend', 'backend_web', 'fullstack', 'integration'):
    values = [item.decode() for item in (root / f'pager-{profile}.args').read_bytes().split(b'\0')[:-1]]
    for value in ('exec', '--ephemeral', '--ignore-user-config', '--ignore-rules',
                  '--skip-git-repo-check', '--sandbox', 'workspace-write', '--model',
                  'gpt-5.6-luna', '-c', 'model_reasoning_effort="max"', '--json'):
        assert value in values, (profile, value)
    assert any(item.startswith('developer_instructions=') for item in values)
    assert any(f'task_profile={profile}' in item for item in values)
PY
then ok 'pager smoke runner covers every adaptive profile'; else not_ok 'pager smoke runner covers every adaptive profile'; fi

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
