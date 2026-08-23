# Local network and test socket permissions

## Overall goal

Replace the Playwright-specific project permission name with the purpose-based
`local-network` option and add an independent `test-socket` option that permits
exactly the absolute Unix socket `<repopath>/test/test.sock`, while preserving
Basix ownership, rollback, and foreign-TOML safety guarantees.

## Phase 1

**Goal:** Apply ADR 0004 by establishing the renamed and separated permission
contract, including a safe composition model for every option combination.

**Work:**

1. **Task 1:** Define the public installer matrix for `--local-network`,
   `--no-local-network`, `--test-socket`, and `--no-test-socket`, including TTY
   prompts, mandatory noninteractive choices, uninstall behavior, and the four
   enabled/disabled combinations.
2. **Task 2:** Validate with the installed Codex configuration parser how two
   independent capabilities can be composed under one `default_permissions`
   value; select named `local-network`, `test-socket`, and, only if required, a
   generated combined profile without broadening either capability.
3. **Task 3:** Define migration behavior for configurations managed by the
   released `playwright` markers and profile: recognize only the exact legacy
   Basix-owned shape, convert it deterministically to `local-network`, and reject
   damaged, modified, partial, or foreign overlaps before mutation.

**QS:**

- Each CLI combination has one unambiguous effective configuration and removal
  behavior; neither capability silently enables the other.
- Local network access remains limited to the existing loopback-domain and local
  binding contract, while test socket access contains exactly one absolute path.
- The chosen composition parses with the installed Codex CLI and does not depend
  on undocumented multi-profile activation.
- The validated contract conforms to active ADR 0004 without retaining
  Playwright as a permission name.

**Learnings:**

## Phase 2

**Goal:** Implement independent, TOML-safe local-network and test-socket profile
management with deterministic legacy migration.

**Work:**

1. **Task 1:** Refactor `src/setup/lib/manage_developer_instructions.py` from
   Playwright-specific constants and actions to capability-oriented parsing,
   validation, check/add/remove, and profile-composition operations; depends on
   Phase 1's validated configuration model.
2. **Task 2:** Generate the local-network permission under purpose-based managed
   markers and names, preserving the existing limited network proxy,
   `localhost`, `127.0.0.1`, `::1`, and unrestricted local-port binding behavior.
3. **Task 3:** Generate the test-socket permission under separate managed markers
   and names, deriving only the absolute `<canonical-project-root>/test/test.sock`
   key without requiring the socket or `test/` directory to exist.
4. **Task 4:** Implement exact effective-value validation, foreign-overlap
   detection, idempotent updates, selective removal, byte-preserving separators,
   and atomic conversion of recognized legacy Playwright-owned blocks.

**QS:**

- The four capability combinations produce parseable TOML with exactly their
  requested permissions and no residual Playwright-named effective profile.
- Reapplying any combination is byte-stable; changing one capability leaves the
  other capability's effective permission unchanged.
- Disable and uninstall remove only Basix-owned regions and preserve unrelated
  LF, CRLF, and no-final-newline configuration bytes exactly.
- Legacy migration is all-or-nothing and refuses ambiguous ownership or modified
  values before writing.

**Learnings:**

## Phase 3

**Goal:** Expose both permissions independently through project installation and
communicate their scopes accurately in installed guidance.

**Work:**

1. **Task 1:** Replace `--playwright`/`--no-playwright` in
   `src/setup/install_for_project.sh` with `--local-network`/
   `--no-local-network`, add `--test-socket`/`--no-test-socket`, and pass the
   canonical project root to every relevant preflight, apply, dry-run, disable,
   and uninstall operation; depends on Phase 2.
2. **Task 2:** Add separate interactive decisions and reports: describe local
   networking as suitable for uses such as Playwright, and describe test-socket
   access as exactly one repository-local test socket.
3. **Task 3:** Preserve the noninteractive fail-closed contract by requiring an
   explicit choice for both capabilities, and ensure every configuration
   transition is validated before skills, agents, state, or config mutate.
4. **Task 4:** Update `src/skills/basix/SKILL.md` so an installed Basix project is
   told that `test-socket` permits tests to use exactly
   `<repopath>/test/test.sock`; update installation and architecture documentation
   to distinguish the two options and remove Playwright as the permission name.

**QS:**

- TTY and non-TTY flows independently enable or disable both capabilities and
  report their exact scopes without presenting Playwright as a permission class.
- `--test-socket` alone does not enable domain access, proxying, or local TCP port
  binding; `--local-network` alone does not permit any Unix socket.
- Dry-run predicts the same transitions without mutation, and uninstall needs no
  feature flags while removing all recognized Basix-owned permission regions.
- Global/plugin installation remains unchanged, and the copied Basix skill
  contains the exact one-socket testing rule.

**Learnings:**

## Phase 4

**Goal:** Prove naming migration, option independence, exact path scoping, and
installer lifecycle safety before committing the implementation.

**Work:**

1. **Task 1:** Replace and extend focused helper tests for the four capability
   combinations, absolute project paths, whitespace/quotes/backslashes,
   LF/CRLF/no-final-newline round trips, idempotency, selective removal, foreign
   overlaps, altered managed values, and exact legacy migration.
2. **Task 2:** Extend project-installer tests for TTY and non-TTY option matrices,
   canonical test-socket paths, independent reports, dry-run, uninstall,
   preflight rollback, removal of old CLI names, and installed Basix-skill text.
3. **Task 3:** Run syntax/static checks, focused helper and project-installer
   suites, setup-support and project-setup suites, then the full setup aggregate
   selected by `src/scripts/run-quality-gates.sh` for shared installer and
   configuration-contract impact.
4. **Task 4:** Freeze the result, obtain independent read-only verification of
   capability separation, legacy safety, exact socket scope, and ADR compliance;
   after any correction rerun affected gates and restart the frozen review.
5. **Task 5:** Populate phase learnings, record only qualifying durable memory,
   archive this completed plan, and commit only task changes as `codex` after all
   tests and verification are inactive and successful.

**QS:**

- Every selected command succeeds with recoverable logs and no running test or
  verifier remains.
- Frozen review finds no capability coupling, socket path broadening, legacy
  ownership ambiguity, partial mutation, documentation mismatch, or global
  installer regression.
- Repository search finds no obsolete public `--playwright`,
  `permissions.playwright`, or Playwright-managed marker contract outside explicit
  legacy-migration fixtures and compatibility code.
- The final diff contains only the successor ADR lifecycle, implementation,
  tests, documentation, archived completed plan, and any qualifying memory update.

**Learnings:**
