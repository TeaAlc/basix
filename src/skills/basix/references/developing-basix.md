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
explicit plan changes the configure-tmux skill.
