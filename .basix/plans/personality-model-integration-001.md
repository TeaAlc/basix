# Integrate the personality model skill with Basix

Overall goal: Make `basix-personality-model` conform to Basix metadata, routing, soul adaptation, language, and documentation conventions while preserving its fourteen required dimensions and evidence safeguards.

Estimated effort: One small implementation and verification cycle, well below 10 million input tokens. This document authorizes no execution by itself; the current request is planning only.

## Agreed scope and constraints

- Change `src/skills/basix-personality-model/SKILL.md` and `src/docs/skills.md`.
- Preserve all fourteen required dimensions, their substantive guidance, and the standalone compact core. Do not introduce a shorter mode or extract detail references for token savings.
- Internal content is English. User-facing communication follows the user's language. Explicit user language requests override the default for their stated scope. Apply this distinction consistently to the full model, its compact core, and soul adaptation.
- Keep personality separate from tasks, tools, permissions, expertise, memory, and workflows. Preserve evidence attribution, uncertainty, and safeguards against invented psychological claims.
- Do not deploy a personality, create an actual soul file, change native agents, or reinstall Basix as part of this implementation.
- Existing skill-tree discovery covers installation and plugin discovery; no installer or plugin manifest change is planned.
- Use canonical source files only; exclude repository-local `.agents/` and `.codex/` from product evidence and mutations.
- The active ADR index was checked. ADR 0001 governs this plan. No architectural decision or ADR replacement is needed for the agreed scope.
- The skill directory is currently user-created and untracked. Preserve its supplied content except for the agreed changes; explicitly review its full contents before including it in the implementation commit.

## Phase 1: Implement the agreed compatibility changes

**Goal:** The skill and catalog express all five agreed integration points without changing the personality model's substantive structure.

**Work:**
1. **Task 1:** Load the applicable skill-authoring guidance before editing, retain already loaded Basix instructions, and capture the current skill baseline and task-owned diff. Confirm scope has not changed since this plan.
2. **Task 2:** Set frontmatter `name` to `basix-personality-model` and give the description a YAML-quoted `Basix-Skill: ` prefix with precise create, assess, and improve triggers; depends on Task 1.
3. **Task 3:** Require the Basix router before domain work and route external research through `basix_researcher` under the existing delegation rules. Reference the router rather than duplicate its communication contract or agent policy; depends on Task 1.
4. **Task 4:** Define the boundary between producing a standalone model and explicitly requested soul adaptation. Preserve the managed first line `**Your are <name>! Your role is <role>!**`, relevant existing character content, and character-only scope when adaptation is requested. Clarify that the model's `You are ...` opening is not the soul file header; depends on Task 1.
5. **Task 5:** Replace the blanket user-language rule with English for internal artifacts, the user's language for user-facing communication, and scoped explicit language overrides. Ensure second-person output and soul adaptation obey the same rule; depends on Tasks 3 and 4.
6. **Task 6:** Add the canonical skill name, triggers, model scope, language distinction, and soul adaptation boundary to `src/docs/skills.md`; depends on Tasks 2 through 5.

**QS:** Frontmatter is valid YAML and the skill name matches its directory; description has the required prefix; all fourteen dimensions remain; research routing is explicit; model production does not implicitly authorize deployment; soul adaptation preserves the required header; English internal content and localized user communication are unambiguous, including explicit overrides; catalog and skill agree. Update the remaining plan from these results before proceeding.

**Learnings:**

## Phase 2: Verify the frozen implementation

**Goal:** Obtain source-level and deterministic evidence that the final changes satisfy the agreed behavior and existing Basix checks.

**Work:**
1. **Task 1:** After Phase 1, inspect the complete task diff and validate YAML frontmatter with an available YAML parser. Review representative cases: German conversation with an English internal model, an explicitly requested German model, external research, and explicitly requested soul adaptation. These are instruction-consistency checks, not claims of live behavioral evaluation.
2. **Task 2:** Run `bash test/skills/basix/test-basix-static.sh` for mandatory metadata and policy checks. Resolve failures within the agreed scope before freezing the implementation; depends on Task 1.
3. **Task 3:** Inspect the frozen skill and catalog independently (Subagent Task: basix_verifier); depends on Task 2. Supply the exact owned targets, relevant canonical router and soul-rule context, and the agreed acceptance criteria. All overlapping writers must be inactive; freeze both files until the verifier finishes. Record review evidence outside the source tree.
4. **Task 4:** Run `./test/verify-basix.sh` once on the final frozen result for the skill-tree and dependent agent/shared aggregation required by the quality-gate profile; depends on Task 3. Preserve complete logs and report command, status, and relevant failure context. No setup aggregate, live research, or configure-tmux suite is required because their implementations and runtime boundaries are unchanged.
5. **Task 5:** If correction is necessary, stop any overlapping verifier before editing, rerun affected checks, and obtain a fresh frozen review. Wait for every started verification to finish successfully before Phase 3.

**QS:** YAML validation, focused static policy checks, aggregate checks, and independent review succeed. No unresolved acceptance gap remains. Product quality-gate scope excludes `.basix/`. Avoid tests that merely mirror prose; no new test suite is planned for these instruction edits. Update the remaining plan from verified results.

**Learnings:**

## Phase 3: Complete and commit the implementation

**Goal:** Deliver the verified integration as a scoped Conventional Commit with a concise user-facing completion report.

**Work:**
1. **Task 1:** After Phase 2, review staged content against the captured baseline and include only the agreed skill, catalog, and eligible task bookkeeping. Curate memory under its retention rules without repeating usefulness increments already applied in this session.
2. **Task 2:** Populate completed phase learnings only with verified findings relevant to subsequent work, and archive this plan under its exact numbered basename after completion. Respect the archive ignore rule; do not force-add ignored files.
3. **Task 3:** Commit task changes as `codex` using a Conventional Commits message such as `feat(skills): integrate personality model with basix`; depends on Tasks 1 and 2 and all successful checks. Do not include unrelated user changes.
4. **Task 4:** Report implemented behavior, verification commands and results, commit identifier, and any material limitation; depends on Task 3.

**QS:** Only intended changes are committed; no verification remains running or failed; the fourteen-section model is preserved; the completion report distinguishes instruction review from live execution testing.

**Learnings:**
