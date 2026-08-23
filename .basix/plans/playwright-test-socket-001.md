# Project Playwright test socket permission

## Overall goal

Extend the optional project Playwright sandbox so an installed Basix project may
use exactly the absolute Unix socket `<repopath>/test/test.sock` for tests, while
preserving the existing ownership, rollback, and foreign-TOML safety guarantees.

## Phase 1

**Goal:** Bind the socket permission to an explicit, reviewable policy and define
its path and ownership invariants.

**Work:**

1. **Task 1:** Confirm the ADR lifecycle change required to supersede ADR 0003;
   this is a dependency for Task 2 and all implementation phases.
2. **Task 2:** Create the next globally numbered ADR stating that project
   `--playwright` installation additionally allows only the canonical absolute
   `<repopath>/test/test.sock` Unix socket, then archive ADR 0003 and update both
   ADR indexes atomically.
3. **Task 3:** Define the configuration contract: the project installer supplies
   its already canonicalized target root, the helper derives the absolute socket
   path without requiring the socket to exist, and global/plugin installation is
   unchanged.

**QS:**

- The successor decision preserves the project-only, opt-in Playwright model and
  names the exact socket boundary.
- The derived path is absolute, remains lexically under the canonical project
  `test/` directory, and is independent of the current working directory.
- ADR files and active/archive indexes satisfy numbering, status, length, and
  link requirements.

**Learnings:**

## Phase 2

**Goal:** Generate, validate, and remove the exact Unix-socket permission as part
of the Basix-owned Playwright configuration.

**Work:**

1. **Task 1:** Extend `src/setup/lib/manage_developer_instructions.py` so every
   Playwright check/add/remove operation receives the canonical project root and
   renders `[permissions.playwright.network.unix_sockets]` with exactly one
   `"<absolute-repopath>/test/test.sock" = "allow"` assignment; depends on Phase
   1.
2. **Task 2:** Update effective-value validation, marker ownership checks,
   idempotent updates, and removal so stale/modified managed blocks and foreign
   socket-table overlap fail before any installer payload mutation.
3. **Task 3:** Update `src/setup/install_for_project.sh` to pass its canonical
   `TARGET` to every Playwright preflight and apply action, including dry-run,
   disable, and uninstall paths.
4. **Task 4:** Add concise English guidance to `src/skills/basix/SKILL.md` that an
   installed project with this permission may use exactly
   `<repopath>/test/test.sock` for tests, and update installation/architecture
   documentation where the generated permission contract is described.

**QS:**

- Enabling produces parseable TOML whose `unix_sockets` mapping contains exactly
  the canonical project test socket and no broader Unix-socket allowance.
- Re-enabling is byte-stable; disabling or uninstalling removes only Basix-owned
  Playwright settings and preserves unrelated configuration byte-for-byte.
- Preflight rejects modified managed values, foreign overlapping tables, invalid
  roots, and incomplete markers before skills, agents, state, or config mutate.
- The global/plugin installer never writes the permission, and the installed
  Basix skill communicates the one-socket test constraint unambiguously.

**Learnings:**

## Phase 3

**Goal:** Prove exact path scoping, installer lifecycle safety, and installed-skill
guidance before committing the implementation.

**Work:**

1. **Task 1:** Extend the focused Python helper tests with absolute paths,
   whitespace/quotes/backslashes, LF/CRLF/no-final-newline round trips,
   idempotency, changed targets, foreign overlap, altered values, and removal.
2. **Task 2:** Extend the project-installer tests to assert the socket key equals
   the temporary project's canonical `test/test.sock`, remains absent under
   `--no-playwright`, dry-run does not mutate, preflight failures roll back, and
   the copied Basix skill contains the exact-use guidance.
3. **Task 3:** Run syntax/static checks, the focused helper and project-installer
   suites, then the setup-support, project-setup, and full setup aggregates selected
   by `src/scripts/run-quality-gates.sh` for installer/configuration impact.
4. **Task 4:** Freeze the result, obtain independent read-only verification of
   the exact socket boundary and lifecycle safety, rerun corrected gates if
   needed, record durable memory, archive this plan, and commit only the task
   changes after all tests and verification are inactive and successful.

**QS:**

- All selected commands complete successfully with recoverable logs and no
  running test remains.
- Frozen review finds no path broadening, foreign-TOML overwrite, partial
  mutation, documentation ambiguity, or global-installer regression.
- The final diff contains the successor ADR lifecycle, implementation, tests,
  documentation, archived completed plan, and any qualifying memory update only.
- The Conventional Commit is created by `codex` after the final frozen checks.

**Learnings:**
