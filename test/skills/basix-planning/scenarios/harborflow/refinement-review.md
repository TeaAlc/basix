# HarborFlow: planning refinement and independent rerun

Date: 2026-10-24. This follow-up distinguishes the original compliance pass from planning quality. The original first attempt remains valid evidence of full coverage and safeguards; it did not establish an optimal schedule. No HarborFlow implementation, deployment, migration, concurrency speedup or product-test success is claimed.

## Changes and evaluation method

The planning skill now audits implicit waits introduced by baselines, phases, shared resources and combined acceptance. It separates source prerequisites, semantic implementation readiness and integration/release readiness. Extra gates need a reason; genuine contract and safety gates remain. Git writers use the earliest accepted base containing their actual required predecessors.

The skill also calls for the earliest meaningful feedback for the relevant risks, with harness/infrastructure staged for the next useful checks. Partial integration supplements final aggregate checks and frozen review. Full inventories can be referenced through a verified canonical manifest with stable content identity, complete path/work coverage, unambiguous scope IDs and unique primary task ownership. Shared rules remain authoritative while dispatch assignments remain independently complete.

A read-only explorer checked assertion/gate coupling. The initial revision changed two canonical planning files; the failed forward test subsequently justified the conditional validator, its reference, ten regression tests and aggregate wiring. A separate frozen verifier accepted those files without findings and completed `rtk bash test/skills/basix/test-basix-static.sh`, `rtk bash test/verify-basix.sh` and a diff check successfully. The writer also passed skill-creator `quick_validate.py` and the scoped whitespace check. Source and Git-baseline safety obligations were retained.

A fresh planner received only the revised skill and unchanged raw scenario/manifest, without the old plan, critique or expected schedule. It delivered `harborflow-delivery-002.md`. An independent reviewer compared the actual result against both the raw requirements and the original plan. This preserves a meaningful forward test instead of teaching the planner the desired answer.

## Frozen identities

| Artifact | SHA-256 |
| --- | --- |
| Raw scenario, unchanged | `38c9373ccee9e379a34a68f7b70d0198aac00966721cefef823bbd8c4076282f` |
| Source manifest, unchanged | `33542e9240c30a6aaf167e21aba3adbf25061d3edf759790a0e9c0c26eb77dae` |
| Original plan | `86154fbae7f7eec542a0742f1228ec4e5781807835cd081c3c27b5388a7cdad1` |
| New plan, initial rerun | `f4ab36901851c00288e85d401455d349602245aaa7c784dde59382b66efd9169` |
| Initial guidance-only skill | `3dc49108e890559b71182cc529078e13f1c3c52473324d55e1319ef7b9de5703` |
| Final skill with mechanical validation | `ce002171c1d75a614bb5dd22f1566245fb8749416b5ffb178a55ebe141581df2` |
| Conditional validation reference | `780c737bfb1290d32841f0b1959414b90c5dc277b0b947d9dab20b15e89b1058` |
| Read-only graph validator | `7638c9a671b9ae2746c6ded4af9c42ef9fb58b85b4c2c717675e0d7b88cb58ea` |
| Fresh plan 003, unedited by root | `70e47a3502f5e7c2a4facec892faa070e5f515c741e2a57618455116b7a09bf4` |
| Durable 003 validation artifact | `d87b1632d6a908d8faf9b46d91df56ea7b6ab4740f6a6cdd3d6114e7da97704e` |
| Revised parallel Git reference | `17b6d1e6a4c76d56223ea560eae8dcc7cd3c4a34a344c695347a5dd31dceffe4` |

The original plan is recoverable from commit `2d5adb8` at `.basix/plans/harborflow-delivery-001.md` even after normal archival. Its first-attempt [test report](review.md) is preserved separately. The raw [scenario](scenario.md) and [manifest](source-manifest.json) remain the authoritative product inputs.

## Before/after findings

The first fresh rerun (plan 002) improved staging, early partial integration and compactness while preserving all 100 ownership assignments and all twelve acceptance groups. Its independent review nevertheless found one missing explicit cross-task source input: E16 needs E06, owned by Ecore, while Engine's dispatch-input declaration names only Edecide/Cdelivery. Ecore is already transitively scheduled, so the issue is accepted-input identity completeness rather than an additional required wave.

**This attempt is not accepted as a successful skill outcome.** Following the user's clarification, plan 002 remains unchanged. No parent or executor patches it to obtain a pass. Instead, the skill gains reusable mechanical ownership/dependency reconciliation, followed by another fresh planner run from the same raw inputs without prior answers or the project-specific finding. A second independent planner then produced plan 003 from the final skill and unchanged raw inputs, again without earlier plans, review findings or the project-specific missing edge. Root has not edited either generated plan or its validation artifact. The new mechanical run passed. Independent frozen review also passed with no findings or worker-claim mismatches, so root accepts plan 003 as a successful fresh outcome of the final skill.

The reusable validator derives each task's direct external source inputs from a normalized full inventory and primary ownership, then compares them with the declared dispatch inputs and readiness graph. A transitively reachable owner does not excuse losing the required file's accepted checkpoint identity. Normalization is conditional on explicit structured dependencies; simple plans gain no mandatory sidecars. Negative tests include the general transitive-omission failure and rejection of an unnormalized input that would otherwise silently appear dependency-free. Runtime/schema/deployment relationships retain their own meaning. The utility cannot establish adapter fidelity, actual Git acceptance or the semantic merit of a gate; those remain explicit review duties.

## Final independent outcome

**Fresh final-skill run 003: PASS, without root edits or a repair cycle.** The read-only verifier independently derived all 100 exclusive ownership assignments across 20 production tasks and all 98 direct cross-owner source inputs. It confirmed every required file/owner/accepted-identity reference, the complete raw adapter fidelity (226 source, three migration and eleven schema edges), retained runtime/deployment metadata, and equality of the durable and temporary task graphs. Its validator rerun exited 0. All supplied plan, sidecar, raw and source hashes still matched.

The reviewer found useful early atomic fault feedback, later flow/dispatch joins, staged harness growth, maximum-three-descendant scheduling, isolated branches/worktrees/resources, and no runtime A↔X build cycle. All twelve future acceptance groups and all four injection procedures were complete. Exact-SHA integration, inactive-writer frozen review, guarded worktree-safe target update, migration-retirement gates, cleanup and permission boundaries remained explicit. Four future Learnings fields were empty; no product check was falsely claimed.

Two legal scheduling traces checked by the reviewer:

1. After bind, contract-base and SQL source may run independently. Accepted reservation contracts unlock arithmetic/candidate work while ports/schema continue; pure engine work uses accepted contract/arithmetic checkpoints without waiting for migration application. Tenant and storage checks wait only for their named source/schema evidence. Engine plus atomic storage can enable meaningful fault feedback before the entire service harness exists.
2. With shared predecessors accepted, ingestion, inventory and settlement component work use three isolated slots. An unchanged-contract inventory failure blocks its acceptance and flow/final joins, while accepted independent work remains valid; allocation/execution fixture work can occupy released slots from their actual sources. They do not require an accepted inventory implementation just to start. Real peer behavior is verified by the later named integration joins.

Recoverable independent logs/checks: `/tmp/harborflow-mechanical-review`. Frozen accepted [plan 003](../../../../../.basix/plans/harborflow-delivery-003.md) and its [actual planning-validation artifact](delivery-003-validation.json) are the new results. Plans 001 and rejected 002 are archived locally with exact basenames only after this acceptance. The archive directory is ignored by repository policy; it is not force-added. The original 001 remains recoverable from commit `2d5adb8`; the rejected 002 identity and failure are retained in this report and the generalized missing-input regression test.

## Measurement and limits

| Artifact | UTF-8 bytes | Whitespace-delimited words | Lines |
| --- | ---: | ---: | ---: |
| Original delivery plan | 56,170 | 7,655 | 256 |
| Initial revised-skill delivery plan (rejected 002) | 43,887 | 5,508 | 206 |
| Fresh final-skill plan 003 | 47,235 | 5,567 | 181 |
| Durable 003 validation artifact | 48,224 | 3,141 | 1,739 |
| 003 plan plus durable validation | 95,459 | 8,708 | 1,920 |

The initial rerun is 21.9% smaller by bytes and 28.0% by this word-count convention. The skill entrypoint changed from 5,453 to 7,471 bytes (7,045 at the guidance-only attempt); its conditional Git reference from 4,315 to 4,742 bytes. These are exact file-size observations, not model-token or runtime measurements. The added guidance is justified only insofar as the rerun improves decisions or reduces repeated plan content while retaining completeness.

Plan 003 alone is 15.9% smaller by bytes and 27.3% by whitespace words than 001. Including its durable machine-readable graph and actual validation result, however, the artifacts are 70.0% larger by bytes and 13.8% by whitespace words. The sidecar is conditional planning/check evidence and need not be loaded in full for every dispatch. These observations do **not** establish an overall token reduction: mechanical reliability adds an explicit storage/context cost.

This single invented project cannot establish global optimality or a general pass rate. Static graph reachability identifies a conservative impact set, not proof that every downstream behavior changed. Proposed fixture policies remain proposals; real baselines, durations, resources and command bindings would be resolved before execution. The original contract-change injection occurs after one accepted result; a separate future test would be needed to establish behavior when shared contracts change during several active implementations.

## Source verification and execution environment

The final frozen skill/tool passed ten focused regression tests, static policy, syntax and independent source review. Initial aggregate runs failed untouched explorer and source-memory suites. The source-memory suite passed three isolated reruns and subsequent aggregates; explorer passed in isolation but still failed through the quality runner, including with a system-tool PATH. No unrelated product or test source is changed. Recoverable failed logs remain under `/tmp/planning-refinement-final-gates`, `/tmp/planning-refinement-final-gates-retry` and `/tmp/planning-refinement-system-tools-gates`; a subsequent complete quality-runner invocation passed every deterministic suite without source changes. Its command used `rtk bash -lc` with `PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1` and the same seven changed paths and frozen-review evidence. Passing runner/aggregate logs: `/tmp/planning-gate-diagnosis-cycle3/runner.log` and `/tmp/planning-gate-diagnosis-cycle3/gates/basix-aggregate.log`. No deterministic root cause was established, so this is recorded as transient environment sensitivity rather than a proven PATH fix. Root reconfirmed all seven final source hashes unchanged after completion.

Native read-only agents in this runtime could not access `collaboration.send_message`; root received their structured final findings and recoverable logs through available final output. Their domain-check outcomes and this transport limitation are recorded separately; no successful Contract 2.0 message delivery is claimed for those native agents. The generic independent planners did deliver their mandatory terminal messages.
