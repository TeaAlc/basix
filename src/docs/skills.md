# Skills

The `basix` meta-skill is the runtime router for managed-instruction precedence, installed-skill path resolution, conversation language, Contract 2.0, and agent spawning. Repository layout, placement, documentation, and test-selection rules live in its `references/developing-basix.md`; the router loads that reference completely only for work that maintains, extends, tests, reviews, or verifies the Basix source repository, not for ordinary use of installed Basix components. Complete skill-tree installations include the reference automatically. The meta-skill intentionally contains no scraping, mirroring, or other domain workflow. Basix skills keep technical content in English and produce user-facing chat messages in the language of the current conversation.

The `basix-agent-authoring` skill plans, creates, and updates native agent TOMLs. It keeps two independent axes: task complexity selects Luna reasoning effort, while agent level (`junior`, `senior`, or `principal`) selects coordination and spawn authority. Every native TOML begins with validated commented metadata and declares the same level in its runtime prompt; persistent native principals require an explicit user request and marker. The Basix router maps every native agent to its level and is the sole spawn-authority source: juniors spawn nobody, seniors spawn native juniors but no generic agents, and principals spawn native or generic juniors and seniors. Only `/root` may directly spawn a generic principal. The skill inserts the managed native bootstrap and validates that each agent loads the management-owned Contract 2.0 before planning or domain work without embedding a second contract copy. It retains the JSON Schema and validates message streams. An adjacent sandbox marker permits `workspace-write` only for `basix_pager`; every other native agent remains read-only.

The `basix-experience` skill writes a localized, evidence-based Markdown retrospective when a user requests feedback about the current session, used skills, subagents, or token efficiency. It excludes itself from evaluation and reports only visibly evidenced use. Its read-only collector recursively gathers the latest cumulative rollout telemetry for the root thread and started subagents; failures remain non-blocking, missing values stay explicitly unavailable, and independently supplied structured telemetry remains an unmixed fallback. Visible workflow costs receive qualitative analysis and five ranked saving opportunities.

The [`basix-subagent-efficiency`](../skills/basix-subagent-efficiency/SKILL.md) skill analyzes delegated objectives across repeated attempts, independently of subagent lifetime. Its normalized attempt table supports first-shot success, retry coverage and recovery, cumulative completion, unresolved outcomes, and retry efficiency. It classifies attempt-specific causes and interventions, separates incomplete evidence from failure, and interprets recovery costs and latency. Use it for task-level multi-shot analysis; use `basix-experience` for the broader session retrospective.

The `basix-personality-model` skill creates, assesses, and improves evidence-grounded personality models and standalone agent role specifications. It keeps fourteen dimensions, distinguishes observed behavior from inferred motives, and preserves uncertainty. Internal models are written in English unless the user explicitly requests another language; user-facing communication follows the conversation language. It loads the `basix` router for external research and agent routing. Adapting a model to `.basix/soul.md` is a separate, requested character update that preserves the managed soul header and existing language unless the user explicitly requests a change.

The `configure-tmux` skill diagnoses tmux before changing it, selects between tmux-managed mouse behavior, native terminal scrollback, and keyboard-only copy mode, and applies a confirmed deterministic fragment without replacing unrelated bindings or sessions. It supports Linux and Termux hosts, treats MobaXterm as a manually verified external client, and includes isolated and live read-only verification plus an opt-in clipboard helper.

Add each future workflow under `skills/<name>/SKILL.md` with a specific trigger description. Put its scripts, references, and assets in that skill directory. Put only launchers shared by multiple skills or agents under top-level `scripts/`.

The [`basix-subagent-management`](../skills/basix-subagent-management/SKILL.md) skill is mandatory before delegation, coordination, and every managed agent assignment. It owns role routing, assignments, parent lifecycle, verification freezes, and the sole runtime Contract 2.0 reference. Agents load router, management skill, and complete contract before planning, messages, tools, or domain work; unreadable required sources fail closed. The router retains the sole authority table, while authoring retains schema and validation.

The [`basix-planning`](../skills/basix-planning/SKILL.md) skill owns saved phase plans, canonical per-stem numbering, affected-file descriptions, and phase closure. Saved plans are not transmitted; silent message cycles remain governed by Contract 2.0.

The [`basix-adr`](../skills/basix-adr/SKILL.md) skill is mandatory before planning or implementation and for ADR lifecycle work. It preserves binding active decisions, Unicode budgets, globally increasing numbers, confirmation, conflict notices, and atomic lifecycle/index updates.

The [`basix-agent-memory`](../skills/basix-agent-memory/SKILL.md) skill owns evidence-based memory curation, TOML shape, retention, language, merge scoring, and final session scoring. Startup reads and autonomous ownership stay in developer instructions; Contract 2.0 proposals retain their separate 24-word limit, while persisted insights allow 32 words.

Saved-plan execution resolves model and effort independently: explicit user
override, applicable specialist/skill settings, then `gpt-6.1-sol`/`low` runtime
fallback. A model-only override retains applicable effort. Native authoring Luna
classification defaults are specialized rules; saved plans preserve native
specialist routing and configured settings. Unsupported selected settings block
dispatch without substitution. Every assignment uses no forks, with
complete ownership, resources, dependencies, acceptance checks and continuation
checkpoints. Root may request material task/cycle-attributed analysis; it is not
mandatory for every plan. `foo-001.md` has the adjacent companion
`foo-001_efficency_analysis.md`; archive the pair without collisions. Explicit
report write permission, honest unavailable metrics and evidence-backed material
findings are required. Efficiency and experience remain independent analytical
workflows; companions reuse only relevant attribution/evidence guidance.
