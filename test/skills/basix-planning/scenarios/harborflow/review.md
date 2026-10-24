# HarborFlow planning-skill behavioral test

Date: 2026-10-24. This is an invented software-delivery scenario, not a product implementation or a performance benchmark. The experiment exercises the current canonical `src/skills/basix-planning/SKILL.md` after its parallel-planning rollout.

## Inputs and method

The [scenario](scenario.md) supplies requirements, acceptance cases and injected changes; the [manifest](source-manifest.json) supplies the exact production-source inventory. A separate scenario author created these raw inputs. Root checked their structure before a fresh planner received the skill and raw inputs, without an ideal schedule or suspected defect. A separate read-only verifier then received the immutable artifacts and an explicit evaluation rubric. No implementation workers, product branches, databases or deployments were created.

The resulting future plan is [harborflow-delivery-001.md](../../../../../.basix/plans/harborflow-delivery-001.md). Its implementation QS remains unexecuted and its phase Learnings must remain empty. The experiment's administrative plan is separate and is archived when this experiment finishes.

## Scenario complexity

| Group | Production sources |
| --- | ---: |
| Shared contracts | 12 |
| Central deterministic engine | 18 |
| Shared storage | 15 |
| Ingestion service | 11 |
| Inventory service | 11 |
| Allocation service | 11 |
| Execution service | 11 |
| Settlement service | 11 |
| **Total** | **100** |

The inventory contains 96 TypeScript files and four SQL migrations. Its 226 static dependencies, three migration-order edges and eleven adapter/schema requirements resolve to known IDs and form an acyclic combined prerequisite graph. Five runtime service edges include allocation → execution → allocation; that coupling must not become circular build prerequisites. Each service uses the same central engine. Each product environment has one shared application database/schema; separate worktrees need isolated environments.

The scenario adds tenant isolation, transactional inbox/outbox, duplicate and reordered events, deterministic replay, corrupt snapshots, lease fencing, lost carrier responses, immutable financial postings, mixed-version deployment, resumable backfill and irreversible schema cleanup. Twelve observable future acceptance cases cover these behaviors. Four explicit injections exercise accepted-contract revision, local inventory failure, target drift during frozen review and preservation of unrelated user edits.

## Actual evidence

- Root's manifest integrity assertions passed: exactly 100 unique IDs and paths, eight declared group counts, descriptions of at most 32 Unicode characters, resolved typed prerequisites, an acyclic combined graph, five engine-dependent services and the mutual runtime edge.
- `rtk bash test/skills/basix/test-basix-static.sh` passed. This repository static check does not prove the fictional implementation works.
- The independent planner delivered five future phases and an exact-file ownership/dependency ledger. Its reported self-checks are distinct from the independent review below.

Frozen first-attempt SHA-256 identities:

| Artifact | SHA-256 |
| --- | --- |
| scenario.md | `38c9373ccee9e379a34a68f7b70d0198aac00966721cefef823bbd8c4076282f` |
| source-manifest.json | `33542e9240c30a6aaf167e21aba3adbf25061d3edf759790a0e9c0c26eb77dae` |
| harborflow-delivery-001.md | `86154fbae7f7eec542a0742f1228ec4e5781807835cd081c3c27b5388a7cdad1` |

## Independent review

**First attempt: PASS, with no required corrections.** The independent verifier's completed terminal result reported no findings, no mismatch with the planner's claims and no need for another review cycle. Root accepted that result against the unchanged frozen hashes above. No skill change was justified by this experiment.

| Criterion | Independent evidence |
| --- | --- |
| Complete ownership | 100 manifest files match 100 plan rows; no missing, extra or duplicate IDs. Nine primary work owners cover C12/E18/M4/D11/G11/I11/A11/X11/S11. Longest work description: 28 characters. |
| Dependency fidelity | Zero mismatches between the plan's typed dependency ledger and the manifest. No static cycle; runtime coupling is explicitly separate. |
| Observable behavior | All twelve acceptance cases A01–A12 have component and real integration/release checks. |
| Readiness and slots | Accepted-result joins and explicit dispatch conditions support independent progress with at most three active descendants. No nested slots are granted. |
| Git integration | Bound real baselines, branch/worktree identities, resource isolation, root checkpoints, exact-SHA integration, frozen review and guarded worktree-safe target update are specified. |
| Recovery | All four injections have concrete procedures; migration retirement, financial compensation and resource cleanup preserve their distinct safety conditions. |
| Evidence honesty | Five future phases retain empty Learnings. Product checks and B0/B1 remain explicitly hypothetical. |

Two legal scheduling traces establish more than a generic promise of parallelism:

1. After baseline/harness acceptance, contracts C and migration source M can run together from foundation f0. Accepted compatible contracts C2 feed engine E; shared adapters D follow accepted engine and migrations. Migration 0004 can be authored early while its application stays behind the later retirement gate.
2. After shared foundation f3, ingestion G, inventory I and settlement S occupy three slots independently. Accepted I alone creates integrated base fi and releases a slot for allocation A. Execution X starts when another slot is released, or after A. G/S need not finish for I's named join; A/X component work uses accepted protocol fixtures without circular source dependencies. Real A/X interaction is checked later by J in an exclusive shared-schema environment.

The four recovery walkthroughs were also checked:

- **Contract revision:** C06/C07/C12 have a 90-file static reverse impact closure. The plan additionally assesses schema/runtime/fixture effects, invalidates affected acceptance and rechecks compatible C2 before dependent dispatch. Evidence outside the closure is retained only when its independence is established.
- **Inventory failure:** failed I is not accepted. Dependent A/X stay blocked while independent G/S and a settlement money check can proceed. Bounded repair or explicit replanning retains the failed scope.
- **Target drift:** a B1 contract change invalidates any moving-target review. The candidate is preserved, exact new identities are bound, affected integration and aggregate checks rerun, and a fresh frozen review precedes the guarded update.
- **User edits:** tracked operator/simulator changes and untracked scratch notes stay outside task worktrees and scoped commits. Overlap aborts preflight rather than claiming ownership; final update must preserve foreign bytes and checkout consistency.

Plan evidence locations: execution rules and identities; Phase 2 for compatible boundaries and migration-source separation; Phase 3 for the three-slot service schedule; Phases 4–5 for real integration, frozen reviews and irreversible rollout; the acceptance matrix; injection procedures; and the 100-file ownership/dependency ledger. These are prospective procedures, not observed software outcomes.

The test supports the narrower conclusion that the current skill enabled one fresh executor to produce a complete, independently accepted plan for this demanding scenario. It does not establish a universal pass rate or demonstrate that actual branch integration, service recovery or database migration succeeds.

## Limits

This tests one complex invented scenario and one independent planning attempt. It cannot establish general reliability, actual concurrency speedup, token savings or software correctness. B0/B1, resource values and service checks describe future execution; no real HarborFlow repository or baseline commit exists. Tests/configuration/documentation are auxiliary scope and do not inflate the 100 production-source count. A planner error alone does not establish a missing skill instruction.
