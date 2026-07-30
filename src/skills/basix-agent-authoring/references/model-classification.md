# Model classification

Always choose the lowest level that can reliably complete the assignment. File count
alone is not complexity. For mixed assignments, use the hardest material component.

| Class | Default | Use when |
|---|---|---|
| Simple | `gpt-5.6-luna`, `low` | Bounded search, extraction, formatting, inventory, or short summary needs no material interpretation. |
| Medium | `gpt-5.6-luna`, `medium` | Several sources require synthesis, evidence gathering, comparison, or limited interpretation without deep causal analysis. |
| Complex | `gpt-5.6-luna`, `high` | Multi-step causal, dependency, security, architectural, state, lifecycle, or conflicting-requirement analysis is central. |

## Decision rules

- Choose `low` only for mechanical search, extraction, formatting, or short summary.
- Choose `high` whenever dependency impact, root cause, security, architecture, or
  conflict analysis is central.
- Choose `medium` for remaining multi-source or moderately interpretive work.
- Before generating TOML, record the class, short rationale, and selected default.
- An explicitly requested model or effort overrides the default. Place
  `# basix-agent-authoring: explicit-model-override` immediately before the
  `model` field. Without it, only Luna and the three documented efforts are valid.

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

