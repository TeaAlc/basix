#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROFILE_DIR="$SCRIPT_DIR/quality-gates"
PROFILE_NAME=basix
BASE=''
LOG_DIR=''
DRY_RUN=0
REVIEW_EVIDENCE=''
declare -a CHANGED_FILES=()
declare -a IMPACTS=()
declare -a IMMUTABLES=()

usage() {
  cat <<'EOF'
Usage: run-quality-gates.sh [options]

Select and run the smallest safe gate set for a changed scope. Profiles keep
repository-specific paths and commands separate from the generic runner.

Options:
  --profile NAME       Profile under src/scripts/quality-gates (default: basix)
  --base REF           Compare the working tree with REF to derive changed paths
  --changed-file PATH  Add a changed path explicitly (repeatable)
  --impact CLASS       Add an explicit impact override (repeatable)
  --immutable FILE=SHA256
                       Require a file to retain its hash before and after gates
  --log-dir DIR        Store complete gate output in DIR (created if absent)
  --review-evidence FILE
                       Non-empty evidence file satisfying a selected review gate
  --dry-run             Select and print gates without running commands
  -h, --help            Show this help

Impacts and automated gates are profile-defined. Select a profile and inspect
its dry-run output to see the available impact and gate names.
EOF
}

die() { printf 'quality-gates: %s\n' "$1" >&2; exit "${2:-2}"; }

normalize_path() {
  local path=$1
  [[ $path != /* && $path != *$'\n'* ]] || die "changed path must be relative and single-line: $path"
  while [[ $path == ./* ]]; do path=${path#./}; done
  [[ -n $path && $path != .. && $path != ../* && $path != */../* && $path != */.. ]] ||
    die "changed path escapes the repository: $1"
  printf '%s' "$path"
}

while (($#)); do
  case $1 in
    --profile) (($# >= 2)) || die '--profile requires a value'; PROFILE_NAME=$2; shift 2 ;;
    --base) (($# >= 2)) || die '--base requires a value'; BASE=$2; shift 2 ;;
    --changed-file) (($# >= 2)) || die '--changed-file requires a value'; CHANGED_FILES+=("$(normalize_path "$2")"); shift 2 ;;
    --impact) (($# >= 2)) || die '--impact requires a value'; IMPACTS+=("$2"); shift 2 ;;
    --immutable) (($# >= 2)) || die '--immutable requires FILE=SHA256'; IMMUTABLES+=("$2"); shift 2 ;;
    --log-dir) (($# >= 2)) || die '--log-dir requires a directory'; LOG_DIR=$2; shift 2 ;;
    --review-evidence) (($# >= 2)) || die '--review-evidence requires a file'; REVIEW_EVIDENCE=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

PROFILE_PATH="$PROFILE_DIR/$PROFILE_NAME.sh"
[[ -r $PROFILE_PATH ]] || die "profile is not readable: $PROFILE_NAME"
# Profiles are repository-controlled shell descriptors. They do not receive
# untrusted positional data beyond normalized paths and declared impacts.
# shellcheck source=/dev/null
source "$PROFILE_PATH"
[[ ${QG_PROFILE_NAME:-} == "$PROFILE_NAME" ]] || die "profile name mismatch: $PROFILE_NAME"
if [[ -z ${QG_PROFILE_IMPACTS+x} ]] || ((${#QG_PROFILE_IMPACTS[@]} == 0)); then die 'profile defines no impacts'; fi
if [[ -z ${QG_PROFILE_GATES+x} ]] || ((${#QG_PROFILE_GATES[@]} == 0)); then die 'profile defines no automated gates'; fi
declare -A profile_gate_seen=()
for profile_gate in "${QG_PROFILE_GATES[@]}"; do
  [[ $profile_gate =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "profile gate has an invalid ID: $profile_gate"
  [[ -z ${profile_gate_seen[$profile_gate]:-} ]] || die "profile gate is duplicated: $profile_gate"
  profile_gate_seen[$profile_gate]=1
  qg_gate_command "$profile_gate" >/dev/null 2>&1 || die "profile gate has no command: $profile_gate"
  qg_gate_reason "$profile_gate" >/dev/null 2>&1 || die "profile gate has no reason: $profile_gate"
done
for profile_impact in "${QG_PROFILE_IMPACTS[@]}"; do
  qg_reset_classification
  qg_apply_impact "$profile_impact" >/dev/null 2>&1 || die "profile impact has no selector: $profile_impact"
  for profile_gate in "${QG_REQUIRED_GATES[@]}"; do
    [[ -n ${profile_gate_seen[$profile_gate]:-} ]] || die "profile impact selects an unknown gate: $profile_impact -> $profile_gate"
  done
done
qg_reset_classification

if ((${#CHANGED_FILES[@]} == 0)); then
  if [[ -n $BASE ]]; then
    git -C "$ROOT" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base revision is invalid: $BASE"
    while IFS= read -r path; do
      [[ -z $path ]] || CHANGED_FILES+=("$(normalize_path "$path")")
    done < <(git -C "$ROOT" diff --name-only "$BASE" --)
  else
    while IFS= read -r path; do
      [[ -z $path ]] || CHANGED_FILES+=("$(normalize_path "$path")")
    done < <(git -C "$ROOT" diff --name-only --)
    while IFS= read -r path; do
      [[ -z $path ]] || CHANGED_FILES+=("$(normalize_path "$path")")
    done < <(git -C "$ROOT" diff --cached --name-only --)
  fi
  while IFS= read -r path; do
    [[ -z $path ]] || CHANGED_FILES+=("$(normalize_path "$path")")
  done < <(git -C "$ROOT" ls-files --others --exclude-standard)
fi
((${#CHANGED_FILES[@]} > 0)) || die 'no changed paths supplied or found; fail-closed scope selection'

# De-duplicate while preserving order and reject runtime-managed paths.
declare -A seen=()
declare -a UNIQUE_FILES=()
for path in "${CHANGED_FILES[@]}"; do
  [[ -n ${seen[$path]:-} ]] && continue
  seen[$path]=1
  case $path in
    .agents/*|.codex/*) die "runtime-managed path is outside source scope: $path" ;;
  esac
  if [[ ! -e $ROOT/$path ]] && ! git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    die "changed path is neither present nor tracked: $path"
  fi
  UNIQUE_FILES+=("$path")
done
CHANGED_FILES=("${UNIQUE_FILES[@]}")

declare -A selected=(
  [scope]=1 [diff-check]=1 [immutable]=0 [review-required]=0
)
for profile_gate in "${QG_PROFILE_GATES[@]}"; do selected[$profile_gate]=0; done
unknown=()
for path in "${CHANGED_FILES[@]}"; do
  qg_classify_path "$path"
  if ((QG_KNOWN == 0)); then unknown+=("$path"); continue; fi
  for profile_gate in "${QG_REQUIRED_GATES[@]}"; do
    [[ -n ${profile_gate_seen[$profile_gate]:-} ]] || die "path selects an unknown gate: $path -> $profile_gate"
    selected[$profile_gate]=1
  done
  ((QG_REVIEW_REQUIRED)) && selected[review-required]=1
done
if ((${#unknown[@]} > 0 && ${#IMPACTS[@]} == 0)); then
  die "unclassified changed paths require an explicit --impact: ${unknown[*]}"
fi
for impact in "${IMPACTS[@]}"; do
  qg_apply_impact "$impact" || exit $?
  for profile_gate in "${QG_REQUIRED_GATES[@]}"; do
    [[ -n ${profile_gate_seen[$profile_gate]:-} ]] || die "impact selects an unknown gate: $impact -> $profile_gate"
    selected[$profile_gate]=1
  done
  ((QG_REVIEW_REQUIRED)) && selected[review-required]=1
done

if ((${#IMMUTABLES[@]} > 0)); then selected[immutable]=1; fi
declare -a GATES=(scope diff-check)
((selected[immutable])) && GATES+=(immutable)
for profile_gate in "${QG_PROFILE_GATES[@]}"; do
  ((selected[$profile_gate])) && GATES+=("$profile_gate")
done

declare -A before_hash=()
for spec in "${IMMUTABLES[@]}"; do
  [[ $spec == *=* ]] || die "immutable value must be FILE=SHA256: $spec"
  file=${spec%%=*}; expected=${spec#*=}; file=$(normalize_path "$file")
  [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || die "immutable hash must be 64 hexadecimal characters: $spec"
  [[ -f $ROOT/$file ]] || die "immutable file does not exist: $file"
  actual=$(sha256sum "$ROOT/$file" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "immutable target changed before gates: $file" 4
  before_hash[$file]=$actual
done
if [[ -n $REVIEW_EVIDENCE && ! -s $REVIEW_EVIDENCE ]]; then
  die "review evidence is empty or unreadable: $REVIEW_EVIDENCE"
fi

printf 'quality-gates: profile=%s changed=%s impact=%s\n' "$PROFILE_NAME" "${#CHANGED_FILES[@]}" "${#IMPACTS[@]}"
printf 'quality-gates: selected=%s\n' "${GATES[*]}"
((selected[review-required])) && printf 'quality-gates: review-required=independent frozen review\n'
if ((${#unknown[@]} > 0)); then printf 'quality-gates: explicit-impact-scope=%s\n' "${unknown[*]}"; fi
if ((DRY_RUN)); then
  ((selected[review-required])) && printf 'quality-gates: review evidence is required before closure\n'
  exit 0
fi

if [[ -z $LOG_DIR ]]; then
  LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/basix-quality-gates.XXXXXX")
else
  mkdir -p -- "$LOG_DIR"
fi
[[ -d $LOG_DIR && -w $LOG_DIR ]] || die "log directory is not writable: $LOG_DIR"
printf 'quality-gates: logs=%s\n' "$LOG_DIR"

failures=0
quality_gate_reason() {
  case $1 in
    scope) printf 'changed paths are inside the declared repository scope' ;;
    diff-check) printf 'diff whitespace and patch integrity' ;;
    immutable) printf 'frozen target identity' ;;
    review-required) printf 'frozen independent review evidence' ;;
    *) qg_gate_reason "$1" ;;
  esac
}

run_gate() {
  local id=$1 log="$LOG_DIR/$1.log" start end status=0
  start=$(date +%s%N)
  case $id in
    scope)
      printf '%s\n' "${CHANGED_FILES[@]}" >"$log"
      ;;
    diff-check)
      if [[ -n $BASE ]]; then
        if git -C "$ROOT" diff --check "$BASE" -- "${CHANGED_FILES[@]}" >"$log" 2>&1; then status=0; else status=$?; fi
      elif git -C "$ROOT" diff --check -- "${CHANGED_FILES[@]}" >"$log" 2>&1 &&
           git -C "$ROOT" diff --cached --check -- "${CHANGED_FILES[@]}" >>"$log" 2>&1; then
        status=0
      else
        status=$?
      fi
      for path in "${CHANGED_FILES[@]}"; do
        if ! git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
          if git diff --no-index --check /dev/null "$ROOT/$path" >>"$log" 2>&1; then
            :
          else
            untracked_status=$?
            ((untracked_status <= 1)) || status=$untracked_status
          fi
        fi
      done
      ;;
    immutable)
      : >"$log"
      for file in "${!before_hash[@]}"; do
        actual=$(sha256sum "$ROOT/$file" | awk '{print $1}')
        printf '%s %s\n' "$file" "$actual" >>"$log"
        [[ $actual == "${before_hash[$file]}" ]] || status=1
      done
      ;;
    *)
      if qg_gate_command "$id"; then
        if (cd "$ROOT" && "${QG_COMMAND[@]}") >"$log" 2>&1; then status=0; else status=$?; fi
      else
        status=$?
        printf 'cannot resolve gate command\n' >"$log"
      fi
      ;;
  esac
  end=$(date +%s%N)
  if ((status == 0)); then
    printf 'PASS %-18s %6.0fms — %s\n' "$id" "$(( (end-start)/1000000 ))" "$(quality_gate_reason "$id")"
  else
    failures=$((failures + 1))
    printf 'FAIL %-18s %6.0fms — %s; log=%s\n' "$id" "$(( (end-start)/1000000 ))" "$(quality_gate_reason "$id")" "$log"
    tail -n 8 "$log" | sed 's/^/  | /' >&2 || true
  fi
}

for gate in "${GATES[@]}"; do run_gate "$gate"; done

if ((selected[review-required])) && [[ -z $REVIEW_EVIDENCE ]]; then
  failures=$((failures + 1))
  printf 'FAIL %-18s        — frozen/review evidence is required; pass --review-evidence FILE or --immutable FILE=SHA256\n' review-required >&2
elif [[ -n $REVIEW_EVIDENCE ]]; then
  [[ -s $REVIEW_EVIDENCE ]] || { failures=$((failures + 1)); printf 'FAIL %-18s        — review evidence is empty or unreadable: %s\n' review-required "$REVIEW_EVIDENCE" >&2; }
fi

for file in "${!before_hash[@]}"; do
  actual=$(sha256sum "$ROOT/$file" | awk '{print $1}')
  [[ $actual == "${before_hash[$file]}" ]] || { failures=$((failures + 1)); printf 'FAIL %-18s        — immutable target changed during gates: %s\n' immutable "$file" >&2; }
done

if ((failures)); then
  printf 'quality-gates: %d gate(s) failed; complete logs remain in %s\n' "$failures" "$LOG_DIR" >&2
  exit 1
fi
printf 'quality-gates: all automated gates passed; logs remain in %s\n' "$LOG_DIR"
