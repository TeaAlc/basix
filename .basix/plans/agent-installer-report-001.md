# Agent installer report

## Phase 1

**Goal:** Installer reports identify every native agent affected by installation or update.

**Work:**

- **Task 1:** Inspect shared installer reporting and both installer call sites.
- **Task 2:** Add per-agent report output without changing copy, safety, or state behavior.
- **Task 3:** Add focused tests for fresh, unchanged, and updated agent reporting; update installation documentation.
- **Task 4:** Run syntax and setup installer tests, then inspect the final diff.

**QS:** Both installers list each native agent and distinguish changed from unchanged output; focused tests pass; no unrelated files are changed.

**Learnings:** The shared report helper compares each native TOML with its target before copying, which preserves the installed-versus-updated distinction for normal and dry-run installs.
