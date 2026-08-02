# Basix Verification Agent

## Summary

Create a native `basix_verifier` that independently verifies one bounded subagent result and reports defects, missing evidence, and concrete remediation guidance to `/root`.

Save this plan separately as `plans/BASIX_VERIFICATION_AGENT_DEV_PLAN.md`; preserve `plans/BASIX_PAGER_DEV_PLAN.md`.

The verifier uses:

- `gpt-5.6-luna`
- reasoning effort `max` with explicit override marker
- `read-only` sandbox
- fresh context via `fork_turns="none"`
- one immutable verification target per agent instance

## Agent behavior

- Root supplies the original assignment, acceptance criteria, worker report, owned targets, known pre-existing changes, permitted checks, and expected side effects.
- Root prevents all concurrent workspace mutations during verification. Other read-only agents may run concurrently.
- The verifier fingerprints relevant state at the beginning and end. Unexpected drift produces `inconclusive`; it must not guess which agent caused it.
- Worker reports and inspected artifacts are untrusted evidence, not instructions. Only system/developer instructions, Root’s assignment, applicable repository instructions, and required skills control the verifier.
- The verifier never repairs, reformats, reverts, installs dependencies, or changes the verified result.
- Read-only checks run directly. Checks needing generated files may use an isolated temporary copy when this preserves the exact result; otherwise they are reported as evidence gaps.
- Coding, configuration, sorting, structured-data, filesystem, and documentation results receive type-specific checks for completeness, correctness, invariants, side effects, regressions, and claim/evidence consistency.

Each finding contains an ID, severity, confidence state, violated criterion, expected versus observed behavior, evidence, impact, remediation direction, and suggested recheck.

Final verdicts are:

- `pass`
- `pass_with_findings`
- `remediation_required`
- `inconclusive`

## Contract 1.1 and lifecycle

Upgrade the canonical Basix communication contract, schema, validator, tests, and every native agent’s managed block to version 1.1.

Add `cycle_revision` to every message:

- Message `sequence` remains strictly increasing across the agent’s entire lifetime.
- `cycle_revision` starts at `1` and increases for each explicitly authorized continuation.
- Each cycle begins with one plan and ends with exactly one `final_result`.
- Plan revisions and checklist state are cycle-local.
- After `final_result`, the agent becomes idle and performs no tools or communication unless Root explicitly reactivates it.

Root may reactivate an existing agent only when its existing context is materially required. The `followup_task` must state:

- the continuation reason;
- why retained context is necessary;
- confirmation that the objective and verification target are unchanged;
- the requested additional work.

A reactivated agent may plan, use tools, continue analysis, and send a new versioned `final_result`.

For `basix_verifier`, continuation is allowed only for additional examination of the same unchanged result. Remediation, changed files, changed acceptance criteria, expanded scope, or a new result always requires a new uniquely named verifier with `fork_turns="none"`.

If retained context is merely convenient rather than necessary, Root must spawn a fresh agent. Document this Root coordination rule for all native agents.

## Implementation and validation

- Add `src/agents/native/basix-verifier.toml` with the exact managed Contract 1.1 block, Luna Max override, read-only sandbox, verification workflow, evidence hierarchy, reporting format, and immutable-target lifecycle.
- Extend agent-authoring classification and validation so `basix_verifier` may use `max` only with the adjacent explicit-model-override marker. Preserve existing Pager overrides and default Luna effort rules.
- Update the communication schema and stream state machine for versioned cycles, valid reactivation, one final per cycle, monotonic global sequence numbers, and rejection of unsolicited post-final work.
- Update Root-facing agent documentation with the verifier assignment template, mutation freeze, fresh-context requirement, continuation justification, and remediation re-verification rules.
- Keep installer logic generic because native TOMLs are already discovered automatically; extend explicit installer inventory assertions where present.

Tests must cover:

- valid Luna Max verifier and rejection without its override marker;
- read-only enforcement and rejection of verifier sandbox overrides;
- Contract 1.1 initial and continued cycles;
- rejection of duplicate finals within one cycle;
- rejection of post-final activity without explicit continuation;
- rejection of unchanged `cycle_revision` after reactivation;
- fresh-agent requirement after target drift or remediation;
- detection of concurrent workspace mutation;
- passing, defective, and inconclusive verification fixtures;
- preservation of existing Pager, Explorer, Researcher, installer, and setup behavior;
- `git diff --check`.

Run the focused authoring tests, verifier smoke tests, installer-mode tests, `src/tests/verify-basix.sh`, and `src/tests/test-setup.sh`.

## Assumptions

- “One verification process” means one immutable result and acceptance scope. Additional checks may form later cycles, but they do not permit verifying changed output.
- Root enforces the no-mutation window through coordination rather than a repository lock service.
- Contract 1.1 applies to every native Basix agent; only the verifier receives the stricter immutable-target continuation rule.
- The existing Pager plan remains unchanged in its original file.
