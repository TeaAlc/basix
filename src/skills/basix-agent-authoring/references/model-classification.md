# Model classification

Always choose the lowest level that can reliably complete the assignment. File count
alone is not complexity. For mixed assignments, use the hardest material component.

This complexity classification selects model reasoning effort, not agent level.
Agent level separately controls coordination and spawn authority: juniors handle
bounded work without children, seniors coordinate complex work and may spawn native
juniors but no generic agents, and principals may spawn native or generic juniors
and seniors. Only `/root` may directly spawn a generic principal. Junior roles
normally use `low` or `medium`; senior roles should use complexity-appropriate
`high`, `xhigh`, or `max`.

A persistent native principal may be authored only after an explicit user request.
Its leading metadata block must include level `principal` and the standardized
`explicit-principal-level` marker; update its prompt level declaration in the same change.

| Class | Default | Use when |
|---|---|---|
| Simple | `gpt-5.6-luna`, `low` | Bounded search, extraction, formatting, inventory, or short summary needs no material interpretation. |
| Medium | `gpt-5.6-luna`, `medium` | Several sources require synthesis, evidence gathering, comparison, or limited interpretation without deep causal analysis. |
| Complex | `gpt-5.6-luna`, `high` | Multi-step causal, dependency, security, architectural, state, lifecycle, or conflicting-requirement analysis is central. |
| Highly complex | `gpt-5.6-luna`, `xhigh` | Demanding implementation, source-code verification, debugging and repair, or multi-stage planning with subagent coordination requires sustained reasoning across several interacting concerns. |
| Exceptional | `gpt-5.6-luna`, `max` | Rare work combines multiple Highly-complex dimensions across a broad, high-risk scope and requires exhaustive reasoning throughout. |

## Highly complex reference roles

The canonical `basix_pager` and `basix_verifier` are reference examples for the
**Highly complex** class. Both use `gpt-5.6-luna` with `xhigh` reasoning as their
classification default, without an explicit model override marker.

`basix_pager` performs demanding implementation and integration work while
coordinating scoped specialists. It is also the sole native agent authorized to
use `workspace-write`. Its `sandbox_mode` field must be immediately preceded by
`# basix-agent-authoring: explicit-sandbox-override`. Every other native Basix
agent remains `read-only`; the validator rejects workspace-write or an unauthorized
sandbox marker on any other agent.

`basix_verifier` performs difficult source-code and result verification involving
dependency, evidence, drift, lifecycle, and remediation analysis. It remains
strictly `read-only` and may not carry a sandbox override marker.

## Decision rules

- Choose `low` only for mechanical search, extraction, formatting, or short summary.
- Choose `high` whenever dependency impact, root cause, security, architecture, or
  conflict analysis is central but sustained reasoning across interacting concerns
  is unnecessary.
- Choose `xhigh` for highly complex development, difficult verification of development
  work or source code, bug hunting plus bug fixing, and high-quality multi-stage
  planning that includes selecting, assigning, or coordinating subagents.
- Choose `max` only for rare Exceptional assignments combining multiple such
  dimensions across a broad, high-risk scope with exhaustive reasoning throughout.
- Choose `medium` for remaining multi-source or moderately interpretive work.
- Before generating TOML, record the class, short rationale, and selected default.
- An explicitly requested model or effort overrides the default. Place
  `# basix-agent-authoring: explicit-model-override` immediately before the
  `model` field. Without it, only Luna and the five documented efforts are valid.

## Selection cases

| Assignment | Class | Effort | Reason |
|---|---|---|---|
| List hundreds of files matching fixed extensions | Simple | `low` | Volume does not add interpretation. |
| Locate tests and entry points | Simple | `low` | Mechanical repository search. |
| Extract values from one known TOML | Simple | `low` | Fixed-source extraction. |
| Summarize several design documents by theme | Medium | `medium` | Multi-source synthesis. |
| Map use of one API across several files | Medium | `medium` | Evidence gathering with limited interpretation. |
| Reconstruct an incident timeline from logs | Medium | `medium` | Correlates several sources without deep system analysis. |
| Causally analyze a few lines across two modules | Complex | `high` | Small input still requires causal reasoning. |
| Assess migration impact across services | Complex | `high` | Dependency and compatibility analysis. |
| Trace a concurrency lifecycle bug | Complex | `high` | State and timing reasoning are central. |
| Implement a feature across interacting subsystems | Highly complex | `xhigh` | Development requires sustained architectural, dependency, implementation, and verification reasoning. |
| Verify a substantial source-code change and its regressions | Highly complex | `xhigh` | Difficult development verification spans behavior, evidence, dependencies, and failure modes. |
| Find, repair, and regression-test a non-local bug | Highly complex | `xhigh` | Root-cause analysis must remain coherent through implementation and validation. |
| Plan a multi-stage delivery using coordinated subagents | Highly complex | `xhigh` | High-quality planning must partition work, define contracts, order dependencies, and coordinate handoffs. |
| Redesign security-critical services while migrating data and coordinating incident recovery | Exceptional | `max` | Architecture, security, migration, operations, and verification span a broad high-risk scope and demand exhaustive reasoning. |
