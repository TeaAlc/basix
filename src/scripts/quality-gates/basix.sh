#!/usr/bin/env bash
# shellcheck disable=SC2034

# Basix's initial quality-gate profile. The runner owns selection, logging, and
# fail-closed behavior; this profile owns only classification and commands.

QG_PROFILE_NAME='basix'
QG_PROFILE_IMPACTS=(docs prose component interface setup runtime security configure-tmux)
QG_PROFILE_GATES=(static-policy managed-roundtrip basix-aggregate setup-aggregate configure-tmux scrapling-release)

qg_reset_classification() {
  QG_KNOWN=0
  QG_REQUIRED_GATES=()
  QG_REVIEW_REQUIRED=0
}

qg_classify_path() {
  local path=$1
  qg_reset_classification
  case $path in
    src/setup/developer_instruction.md)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy managed-roundtrip)
      QG_REVIEW_REQUIRED=1
      ;;
    src/setup/install-scrapling-codex.sh|src/setup/scrapling-tor/*|test/setup/install-scrapling-codex/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy setup-aggregate scrapling-release)
      ;;
    src/setup/lib/manage_developer_instructions.py|test/setup/test-setup-support/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy managed-roundtrip setup-aggregate)
      ;;
    src/setup/*|test/setup/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy setup-aggregate)
      ;;
    test/verify-basix.sh)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy basix-aggregate)
      ;;
    test/test-setup.sh)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy setup-aggregate)
      ;;
    src/skills/basix/references/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy basix-aggregate)
      QG_REVIEW_REQUIRED=1
      ;;
    src/skills/configure-tmux/*|test/skills/configure-tmux/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy configure-tmux)
      ;;
    src/skills/basix/SKILL.md|src/agents/native/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy basix-aggregate)
      QG_REVIEW_REQUIRED=1
      ;;
    src/agents/*|src/skills/*|src/plugin/*|src/scripts/*|test/agents/*|test/skills/*|test/shared/*|test/scripts/*)
      QG_KNOWN=1
      QG_REQUIRED_GATES=(static-policy basix-aggregate)
      ;;
    src/docs/*|plans/*|*.md|*.txt)
      QG_KNOWN=1
      ;;
    *)
      QG_KNOWN=0
      ;;
  esac
}

qg_apply_impact() {
  case $1 in
    docs) QG_REQUIRED_GATES=() ;;
    prose) QG_REQUIRED_GATES=(static-policy) ;;
    component) QG_REQUIRED_GATES=(static-policy basix-aggregate) ;;
    interface) QG_REQUIRED_GATES=(static-policy basix-aggregate); QG_REVIEW_REQUIRED=1 ;;
    setup) QG_REQUIRED_GATES=(static-policy managed-roundtrip setup-aggregate) ;;
    configure-tmux) QG_REQUIRED_GATES=(static-policy configure-tmux) ;;
    runtime) QG_REQUIRED_GATES=(static-policy basix-aggregate setup-aggregate) ;;
    security) QG_REQUIRED_GATES=(static-policy basix-aggregate setup-aggregate); QG_REVIEW_REQUIRED=1 ;;
    *) printf 'Unsupported impact for profile %s: %s\n' "$QG_PROFILE_NAME" "$1" >&2; return 2 ;;
  esac
}

qg_gate_command() {
  case $1 in
    static-policy) QG_COMMAND=(bash test/skills/basix/test-basix-static.sh) ;;
    managed-roundtrip) QG_COMMAND=(bash test/setup/test-setup-support/test-setup-support.sh) ;;
    basix-aggregate) QG_COMMAND=(./test/verify-basix.sh) ;;
    setup-aggregate) QG_COMMAND=(./test/test-setup.sh) ;;
    configure-tmux) QG_COMMAND=(bash test/skills/configure-tmux/test-configure-tmux-suite.sh) ;;
    scrapling-release) QG_COMMAND=(bash test/setup/install-scrapling-codex/release-gate-podman.sh) ;;
    *) printf 'Unknown gate for profile %s: %s\n' "$QG_PROFILE_NAME" "$1" >&2; return 2 ;;
  esac
}

qg_gate_reason() {
  case $1 in
    static-policy) printf 'focused semantic and static policy assertions' ;;
    managed-roundtrip) printf 'managed instruction insertion/removal boundary' ;;
    basix-aggregate) printf 'agent, skill, authoring, and shared-suite dependencies' ;;
    setup-aggregate) printf 'setup, installer, and generated-target dependencies' ;;
    configure-tmux) printf 'explicit configure-tmux plan boundary' ;;
    scrapling-release) printf 'Scrapling runtime and security release gate' ;;
    *) printf 'Unknown gate reason: %s\n' "$1" >&2; return 2 ;;
  esac
}
