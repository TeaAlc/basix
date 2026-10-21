# Scrapling and Tor recovery

Overall goal: Diagnose the reported outage, provide verified automatic container recovery, and explicitly verify the requested Tor-only traffic boundary, resolving the evidenced DNS exception under the binding ADR workflow.

Estimated effort: medium, below 1 million input tokens. No efficiency report required.

## Phase 1: Establish failure evidence
**Goal:** Identify live failure state and source recovery gaps.
**Work:**
1. **Task 1:** Inspect live Podman state, logs and runtime prerequisites.
2. **Task 2:** Discover canonical runtime and test surfaces (Subagent Task: basix_file_explorer), independently of Task 1.
**QS:** Capture runtime evidence or explicit access limitations; identify source and test paths and causal confidence.
**Learnings:** Live Podman 4.9.3 reports both services running since September 19, no OOM or process failure. Tor health is a historical bootstrap grep; MCP has no healthcheck. HTTP and Chromium control requests succeed with IsTor=true; only the affected target fails. Raw SOCKS RESOLVE succeeds for the control and returns REP=4 for the target, proving target resolution/host reachability failure rather than a general proxy crash. Preserve target errors and avoid global restarts triggered by them.

## Phase 2: Repair and exercise recovery
**Goal:** Implement recovery and regression coverage; restore managed runtime.
**Work:**
1. **Task 1:** After Phase 1, implement container-local supervisors, current protocol health probes, safe legacy migration and documentation (Subagent Task: worker).
2. **Task 2:** Run deterministic setup checks and required isolated Podman release gate before host installation.
3. **Task 3:** Restore managed services and verify Tor routing and recovery where authorized runtime access permits.
**QS:** Relevant deterministic checks and mandatory live gate pass; runtime recovery is demonstrated or remaining blockers precisely evidenced.
**Learnings:** Full setup aggregation and the isolated Podman release gate passed. Tor SIGKILL and MCP SIGSTOP recover automatically; alias/IP drift preserves MCP identity. Podman serializes a multiargument container Entrypoint as a scalar string, so exact Path/Args and raw Cmd checks are required. Full Python stdlib and a build-time supervisor import check are necessary. Installed host services are healthy with the unchanged pinned Scrapling digest.

Affected source and test files (implementation ownership: container_selfhealing):
- `src/setup/scrapling-tor/Containerfile`: Add supervised Tor process.
- `src/setup/scrapling-tor/torrc`: Enable local readiness probe.
- `src/setup/scrapling-tor/launcher.sh`: Launch supervised services.
- `src/setup/scrapling-tor/container_policy.py`: Validate managed supervision.
- `src/setup/scrapling-tor/service_supervisor.py`: Probe and restart child process.
- `src/setup/install-scrapling-codex.sh`: Install support inventory.
- `test/setup/install-scrapling-codex/`: Recovery and migration coverage.
- `README.md`: Explain recovery boundaries.

Runtime evidence: diagnostic execs verified Tor alias 10.89.1.72 and successful HTTP/Chromium requests to check.torproject.org and example.com. Affected target returned SOCKS5 RESOLVE reply `05040000000000000000`; no secrets or client capability IDs retained. Logs/check artifacts for subsequent validation: `/tmp/basix-tor-selfhealing-checks/`.

## Phase 3: Review and delivery
**Goal:** Deliver reviewed changes and a clear incident explanation.
**Work:**
1. **Task 1:** Freeze result and request independent review (Subagent Task: basix_verifier).
2. **Task 2:** Resolve findings, update memory and archive plan.
3. **Task 3:** Commit task changes as codex with Conventional Commits message after all checks finish successfully.
**QS:** Accepted frozen review, no running/failed checks, scoped commit and concise user report.
**Learnings:**

Validation record: final deterministic setup aggregation passed (50 Python tests and 45 Scrapling installer cases plus the other setup suites). Uninterrupted real release gate passed, including legacy migration, drift, child termination/hang recovery and TCP/UDP/SOCKS/Tor checks after all four states. Independent verifier accepted the frozen result with no open findings. Host installation passed; HTTP make_request and Chromium fetch both returned IsTor=true. Direct TCP to 1.1.1.1/8.8.8.8:443 failed; direct UDP DNS received no reply. Evidence logs: `/tmp/basix-tor-selfhealing-checks/`.

## Phase 4: Resolve the explicit all-traffic requirement
**Goal:** Resolve the proven external DNS metadata exception with the user's ADR decision, then meet the approved traffic boundary.
**Work:**
1. **Task 1:** After Phase 2 tests, inspect the installed traffic boundary and compare system DNS with application HTTP/browser routing. Completed: external system DNS resolves example.com despite direct TCP/UDP isolation.
2. **Task 2:** Obtain the required user decision before replacing ADR 0007. Existing decision requires the managed dynamic alias with no explicit DNS upstream and permits external DNS answers. Offered exactly three options: confirm a successor and strict DNS isolation, comply with the existing exception, or replan DNS separately.
3. **Task 3:** Only after Task 2, plan and implement the approved DNS scope with corresponding regression, live traffic and independent verification checks.
**QS:** User's explicit decision recorded; approved scope verified without claiming the present exception is an absolute all-traffic guarantee.
**Learnings:**

Current status: Selfhealing implementation and host deployment complete. Phase 4 awaits the user's required ADR decision; do not archive this active plan or implement a conflicting DNS architecture before confirmation.
