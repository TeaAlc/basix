# Developing Basix

Load this reference only when maintaining, extending, testing, reviewing, or
verifying the Basix source repository. It is not runtime guidance for projects
that merely use installed Basix components.

## Canonical sources and placement

- Treat `<Basix-Repo>/src/agents`, `<Basix-Repo>/src/skills`, and
  `<Basix-Repo>/src/scripts` as canonical.
- Exclude repository-local `.codex/` and `.agents/` runtime configuration from
  agent discovery, product evidence, tests, and verifier scope. Agents must not
  modify either directory directly. Only Basix installers may write there during
  an explicitly requested installation; installer tests use isolated temporary
  targets. Use canonical `src/` sources for development and verification.
- Keep reusable task workflows in one skill directory under `src/skills/`.
- Keep skill-specific scripts, references, and assets beside their `SKILL.md`.
- Keep shared launchers under `src/scripts/`.
- Keep native agent definitions canonical under `src/agents/native/`; setup
  scripts only bind them into supported Codex locations.
- Do not add a domain workflow to the `basix` meta-skill. Create a focused skill
  with a precise trigger description instead.

## Documentation and verification

Update the relevant documentation and select tests from the changed components
and their dependents. Run the selected test paths explicitly and report each
command together with the change it covers. Use `./test/verify-basix.sh` only when
a change can affect the full agent, skill, or shared-test aggregation scope, and
use `./test/test-setup.sh` only when a change can affect the full setup aggregation
scope. Every test that is started must finish successfully before completion.

The configure-tmux suite is excluded from standard gates; run it only when an
explicit plan changes the configure-tmux skill. Keep it outside the standard
aggregate and invoke `run-quality-gates.sh --impact configure-tmux` (or its
focused suite) for that plan.

## Risk-based quality gates

Select the smallest gate set proven sufficient for the changed failure surface,
not the smallest set that happens to be fast. Start with scope/diff integrity,
syntax or format checks, and the directly affected deterministic test. Add
focused boundary tests, dependent aggregates, integration/system/security
checks, or a frozen independent review when the change can reach those failure
classes. Never omit a gate merely because it is slow: replace its coverage with
a narrower equivalent or record why the changed surface cannot reach it.

Classify by impact as well as paths: prose/metadata, deterministic component
logic, shared interface or contract, installer/configuration/generated output,
runtime/external side effects, and security/destructive/high-uncertainty work.
Make every trigger and selected command explicit. Fail closed when scope, base
revision, impact, gate definition, or evidence is ambiguous. Run independent
read-only gates concurrently only with isolated resources and logs; never
overlap mutable writers or a verifier with a mutable target. After a correction,
rerun focused gates and restart the frozen review; run expensive aggregates once
the final diff is frozen.

Quality gates exclude `.basix/` entirely: do not include its paths in discovered
scope, diff checks, or gate commands; filter them from automatic change discovery
and reject explicit `.basix/` paths. A verifier is separate: its spawning parent
may explicitly provide read-only paths to the plan or ADR files needed for the
result, and the verifier reads only those named context files rather than scanning
`.basix/`; the parent decides which paths are relevant.

Capture complete output in a recoverable log directory and report only the
selected reason, status, duration, and concise failure context. The reusable
selector is `src/scripts/run-quality-gates.sh`; repository-specific paths,
impact names, gate descriptors, ordering, and commands belong in its profile
under `src/scripts/quality-gates/`. Its initial Basix profile selects
`test-basix-static.sh` for semantic/static policy,
`test-setup-support.sh` for managed round trips, `verify-basix.sh` for
agent/skill/shared dependencies, and `test-setup.sh` (or a directly affected
setup suite) for setup and installer boundaries. It requires explicit frozen
review evidence for normative or communication-contract changes. Scrapling
runtime-policy changes additionally select
`test/setup/install-scrapling-codex/release-gate-podman.sh` after deterministic
setup tests; the standard configure-tmux exclusion and this security gate are
never weakened.

Changes to `install-scrapling-codex.sh`, `scrapling-tor/launcher.sh`, or any
Scrapling runtime-policy component additionally require
`test/setup/install-scrapling-codex/release-gate-podman.sh` after the deterministic
setup aggregation. This real gate uses isolated temporary Podman storage and must
complete before host installation or commit.
