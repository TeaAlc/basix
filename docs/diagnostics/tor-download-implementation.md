# Managed Tor binary acquisition

Implementation checkpoint, 2026-10-31. No host service was deployed, caller schema
refreshed or manufacturer endpoint contacted. Source tests do not establish the
state of the older installed service described by the Aqara diagnostic report.

## Contract and transport

Every tool requires a secure caller-generated canonical RFC 4122 UUID v4 capability.
It owns sessions/jobs/artifacts independently of opaque resource IDs. Never log
or put it in URLs/headers. The service remains trusted-loopback only; a UUID is
not remote-user authentication. Caller proxy/browser network overrides are
rejected. `list_sessions` has an explicit capability schema. Startup verifies
emitted schemas, after managed binary registration using upstream `add_tool`.

Tools: `download_start(client_id,url,expected_sha256?,maximum_bytes?,time_budget?,
idempotency_key?)`, `download_status(client_id,job_id)`,
`download_cancel(client_id,job_id)`, `artifact_info(client_id,artifact_id)` and
`artifact_export(client_id,artifact_id)`. Start enqueues; only terminal `completed`
means bytes exist. Status never restarts work. Cancellation is cooperative and
bounded by the operation deadline. Same client/idempotency key/payload returns the
same retained job; a changed payload fails. After expiry a key can be reused.
Resume, browser-assisted binary acquisition, arbitrary headers/cookies/auth,
caller file paths and base64 bodies are unsupported.

The dedicated transport sends Tor RESOLVE (0xF0), validates the resulting global
IP, then sends numeric CONNECT to precisely that address. No target DNS lookup or
hostname fallback occurs locally. Only the trusted managed alias uses system DNS,
preserving ADR 0007. Managed-alias libc resolution runs in a killable/reaped
short-lived helper; its timeout shares the connection deadline. The worker then
opens a numeric socket to that alias result, without a hostname retry or fallback.
Every redirect repeats validation/pinning; HTTPS retains the
original TLS hostname/certificate verification. Schemes are HTTP(S), ports 80/443;
private/loopback/link-local/multicast/reserved, alternate numeric and mapped/
transition IPv6 destinations are rejected. At most five redirects, no HTTPS
downgrade. No direct fallback exists. Public servers forwarding to private
resources and compromised host/kernel/Tor are outside the assurance boundary.

Managed Tor retains `SafeSocks 1`. Ordinary numeric CONNECT would be rejected:
remote RESOLVE caches a hostname-to-IP entry, which does not satisfy the numeric
SafeSocks addressmap check. ADR 0017 introduces a trusted gateway on sidecar port
9052, bound only to the uniquely identified private internal interface and loopback.
Non-internal peer sources are rejected before SOCKS negotiation; no listener binds
the egress interface. Ambiguous interface topology fails startup closed. It accepts only canonical validated public numeric CONNECT and ports 80/443.
Inside the sidecar, authenticated local control `MAPADDRESS 0.0.0.0=<numeric IP>`
allocates a virtual IPv4 alias. Connecting to that mapped alias through local
9050 passes SafeSocks, then Tor rewrites it to the validated numeric destination.
No hostname fallback exists. Existing browser/request traffic stays on 9050.

The control port binds only sidecar loopback, and its cookie is never mounted in
the worker or exposed by gateway protocol. Four active streams/mappings are the
maximum; shared targets have serialized reference counts. Final stream closure
unmaps `alias=alias`, including failures. Unknown mapping/control state marks the
gateway failed, rejects further streams and terminates Tor to clear all mappings.
Handshake, relay idle and total stream deadlines bound resource retention.

Primary sources establish intended behavior; these sources share Tor authorship
and are not independent runtime corroboration:
[Tor SOCKS extensions](https://spec.torproject.org/socks-extensions.html),
[MAPADDRESS control specification](https://spec.torproject.org/control-spec/commands.html#mapaddress),
[SafeSocks parser](https://tpo.pages.torproject.net/core/doc/tor/proto__socks_8c_source.html#l1310),
[control implementation](https://tpo.pages.torproject.net/core/doc/tor/control__cmd_8c_source.html#l632),
[virtual mapping allocation](https://tpo.pages.torproject.net/core/doc/tor/addressmap_8c_source.html#l1944),
[address rewrite](https://tpo.pages.torproject.net/core/doc/tor/connection__edge_8c_source.html#l3802).
Existing request/browser paths do not inherit the downloader's pinned SSRF or
rebinding assurance; complete browser subresource/redirect SSRF isolation remains
unproven.

## Exact bytes, state and export

Fresh local readiness and neutral external `IsTor=true` evidence precede job
acceptance. Body streaming uses bounded chunks and a shared absolute deadline
across proxy connect, SOCKS, TLS, headers and reads. Only absent/identity HTTP
Content-Encoding is allowed; transfer chunk framing is removed, content bytes
are preserved. Gzip/ZIP files without HTTP content encoding remain unchanged.
Ambiguous lengths/framing, truncation, byte-cap excess, wrong expected SHA-256 and
failed transfers never publish completed artifacts. A self-computed SHA-256 proves
consistency, not publisher authenticity.

Administrator defaults: 32 MiB/artifact, two active workers, maximum 300 seconds
(default 120), 128 retained jobs, a 128-MiB data-storage bound, and 24-hour artifact expiry.
Admission counts actual retained originals/exports plus each active job’s requested
cap (clamped to 32 MiB), replacing its partial-byte count with that reservation.
Export admission also reserves the full temporary copy before writing; publication
uses a hard link, so temporary and final names share one allocation.
Manifests have a separate 16-KiB/job read limit. Cleanup is lazy at startup/start/resource
access, excludes active jobs and serializes with exports. `bytes_received` reports
progress. No response body is retained in an unbounded in-memory buffer.

Private state is `/var/lib/basix-acquisition`, backed by administrator-owned mode
0700 `scrapling-artifacts` beside installed support. The runtime UID must own it.
Use a dedicated trusted local filesystem; administrators/same-UID processes must
not replace its directories during operation. Sensitive URLs live only in worker
memory. Manifests persist owner hashes, opaque IDs, hashes/sizes/timestamps, policy
version, TLS state and origin-only provenance. Paths/queries, capability and raw
idempotency values are absent. Origin-only provenance intentionally omits even
potentially useful path version identifiers to prevent secret-bearing path leaks.

Private `.part` files publish using atomic no-clobber hard links after hash checks.
Startup marks interrupted work failed and removes partial/orphan publications;
a crash between data and manifest publication sacrifices the artifact safely.
Browser sessions remain in memory. Terminal download state survives restart.

Export is restricted to fixed `export/` through O_NOFOLLOW directory/file
descriptors, opaque generated names, regular single-link source validation,
rehashing, private staging and atomic no-clobber publication. Neither a caller
path nor Content-Disposition chooses filenames. Repeated export returns the same
name, bounding storage. Exports are not overwritten. Returned filenames are
relative to this administrator root; consumers read local completed exports and
verify recorded length/hash before offline use.

## Compatibility and deployment

The reviewed upstream contracts are Scrapling 0.5 (16 methods) and 0.5.1
(17 methods). Each must match its exact reviewed parameter-name inventory before
policy configuration. Ten retrieval/session tools remain public in 0.5;
0.5.1 additionally exposes `browser_observe`. `browser_save_state`,
`browser_load_state`, `browser_actions`, `browser_evaluate`,
`browser_network_requests` and `browser_network_request` are removed using the
public synchronous MCP `remove_tool` API. This avoids exposing arbitrary disk
state, JavaScript/actions or unreviewed captured response history. All public tools
require caller capabilities. TLS verification, safe request redirects, five
redirects, one request attempt and disabled HTTP/3 are administrator-controlled.
The 0.5.1 observer samples an existing owned page for 100–5000 milliseconds and
2–20 maximum frames, with limits enforced by both schema and policy. It shares
the session lock, owner validation, administrator deadline and timeout poisoning.
It never retries capture or recreates a session after a capture error. Screencast
frames travel over the local browser connection; page traffic retains the
browser's forced Tor proxy and WebRTC/QUIC controls.

Remote sessions and login-context reuse remain unavailable: `cdp_url` and the
new `new_context` input are hidden and rejected. Upstream documents that a
borrowed default context can ignore the requested proxy. The removed CDP input
on `browser_fetch_once` is recognized only in the exact 0.5.1 contract.
Mouse dragging and other action chains remain disabled along with arbitrary
JavaScript, state files and network history. Enabling actions needs a separate
review of navigation/local-resource effects and non-replayable partial effects;
the existing retrieval retry wrapper is unsuitable for action chains.
The prior 13-tool reviewed contract is retained for older images; unknown inventory
or new current parameter names fail closed. The real installer executes the shared
assertion in an isolated image before managed service mutation.

Reviewed primary source:
[Scrapling v0.5 server](https://raw.githubusercontent.com/D4Vinci/Scrapling/v0.5/scrapling/core/ai/server.py),
[Scrapling v0.5.1 release](https://github.com/D4Vinci/Scrapling/releases/tag/v0.5.1),
[Scrapling v0.5.1 server](https://github.com/D4Vinci/Scrapling/blob/v0.5.1/scrapling/core/ai/server.py),
[dependency declaration](https://raw.githubusercontent.com/D4Vinci/Scrapling/v0.5/pyproject.toml),
[MCP SDK v2.0.0 public registration API](https://raw.githubusercontent.com/modelcontextprotocol/python-sdk/v2.0.0/src/mcp/server/mcpserver/server.py).
Tagged source proves the minimum dependency API, not the floating image contents;
the mandatory isolated runtime gate must corroborate the exact installed versions,
immutable image identity and emitted tools/list schema. Previously verified 0.5 image:
`docker.io/pyd4vinci/scrapling@sha256:1d876879813759959bc4ba6fbb1ce8247ebbc2b67eee77b140baf7c80af6ae6b`.
The successful isolated runtime reported Scrapling **0.5**, MCP SDK **2.3.0**
and Debian Tor package **0.4.9.11-0+deb12u1**. The Tor image is built locally and
pinned by its runtime image ID; build output records that ID. The complete
`tools/list` schema is retained as `Runtime schema snapshot:` in
`/tmp/basix-tor-acquisition/release-gate-final-retry.log` and extracted as
`/tmp/basix-tor-acquisition/runtime-schema.json` (15 tools). The cycle1 Tor image ID
was `06260549138c0611007bb450946a85c44aa161e39202994c81478c745a782bf3`.
The cycle1 unchanged retry passed after an external canary TLS connection failure
in `release-gate-final-reviewed.log`; no TLS settings, fallback or restart policy
were weakened. This target failure was not evidence of global Tor unavailability.

The successful real gate proved clean installation, deletion of owned retired
stdio/HTTP/Tor resources, strict replacement/reinstallation, Tor-address drift,
Tor child exit and hung MCP child recovery. It observed managed-alias SOCKS
reachability, blocked direct TCP and no direct UDP DNS reply. A neutral HTTPS
acquisition completed and its local export matched length/SHA-256. Actual Tor
SafeSocks numeric CONNECT, concurrent shared MAPADDRESS retention, final unmapping
and worker exclusion from the control cookie/port passed. Public endpoints still
do not establish controlled observer, authoritative DNS or adversarial fixtures.

Only the strict current runtime is supported (ADR 0018). Before mutation, the
installer proves ownership from image, command, mounts, environment, security,
network and port invariants; labels alone are insufficient. Positively identified
owned retired Tor/Scrapling resources are removed. Exact current configurations
may be reused by the launcher. Retired services are never snapshotted or restored.
Foreign containers and foreign network attachments fail closed before removal.

Deployment requires a successful real gate and parent review. When separately
authorized:

1. Run the deterministic suite followed by isolated `release-gate-podman.sh`;
   select a reviewed immutable `SCRAPLING_RELEASE_IMAGE` when needed. Retain logs.
2. Run installer `--dry-run`, then `--runtime podman --image <tested-digest> --force`.
   Review the removal of positively identified owned retired containers.
3. Restart Codex/MCP registration. Run installed `health_check.py` against loopback;
   compare actual tools/list and caller declarations to the release snapshot.
4. Acquire a neutral fixture, verify export locally, then give the offline consumer
   only the local asset. Missing files must never trigger implicit network access.

Recovery removes failed newly created resources and reinstalls reviewed current
code/image as required. Codex configuration bytes are restored on registration
failure. Retired runtime containers are not restored; reviewed support files and
private acquisition state remain for diagnosis and reinstallation. No remote
request already sent can be rolled back. No host deployment was performed here.

## C01–C16 acceptance

Logs: `/tmp/basix-tor-acquisition/`. Deterministic command:
`./test/setup/install-scrapling-codex/test-install-scrapling-codex.sh`.
Final deterministic log: `sustained-final-deterministic.log` (container14, Codex6,
health9, supervisor8, policy27, binary26, gateway8 and 44 installer cases passed).
Full setup aggregation: `final-setup.log` passed; subsequent local runtime changes
were checked by the entire affected suite and final isolated release gate.
Protocol/lifecycle fixtures: `test_binary_acquisition.py`. The mandatory isolated
real gate is `release-gate-podman.sh`. A neutral public smoke is corroboration,
not tester-controlled authoritative DNS, observer or firewall evidence.

| ID | Deterministic evidence | Live/unmet/N/A |
|---|---|---|
| C01 | Capability, invalid/missing/version UUID; health schema inventory | Isolated live schema verified; host caller refresh remains external |
| C02 | Session/job/artifact cross-client ownership | Live two-client lifecycle not established |
| C03 | All downloader sockets target managed proxy | Strict criterion unmet: ADR 0007 host DNS; controlled observer absent |
| C04 | Proxy failure/reset, no fallback/publication, bounded cancel | Live supervisor recovery passed; acquisition midstream fixture absent |
| C05 | Explicit override refusal and mount/network policy | Browser complete bypass coverage unproven; DNS exception |
| C06 | All bytes, NUL/non-UTF8, 256-KiB stream, chunked, encoded rejection, gzip file | Neutral HTTPS body/export consistency passed; controlled exact fixtures absent |
| C07 | Wrong hash/truncation/transport failure cleanup | Controlled live reset absent |
| C08 | Byte/job/storage caps, missing/false length, disk error, absolute reader deadline | Controlled slow/endless public fixture absent |
| C09 | Cross-origin redirect, loop and cap; no credentials accepted | Live controlled A/B and downgrade fixture absent |
| C10 | Prohibited/encoded/mapped addresses, private remote DNS result, numeric pinning, default TLS/SNI | Live numeric SafeSocks pinning passed; strict DNS unmet; controlled rebinding/certificate absent; browser SSRF unproven |
| C11 | Fixed-root ownership, symlink/hardlink/path and no-clobber tests | Same-UID administrator tampering excluded; adversarial race evidence limited |
| C12 | Concurrent idempotency, cancel, interrupted restart, retained state | Live active-job crash-window evidence absent |
| C13 | No resume or append implementation | N/A: explicitly unsupported |
| C14 | URL/error secrets absent from manifests/status/export | Caller capability values never intentionally logged |
| C15 | Upstream inventory/signature and startup emitted-schema checks | Isolated 15-tool schema verified; host caller refresh only after authorized deployment |
| C16 | No Aqara source modified | External offline bulb-app gate remains unmet |

This checkpoint does not satisfy full strict P0 or C01–C16 acceptance. Residual strict criteria remain separate from successful transport delivery;
ADR 0007 accepts system DNS metadata and does not waive every-DNS-through-Tor
acceptance or establish controlled observer evidence.

## Continuous operation

Managed Tor and Scrapling containers use `--log-driver=none`: container stdout and
stderr have zero retention, including while stopped. Tor emits notices to stdout
and has no file-log sink. Runtime healthchecks discard all output; health status
and timestamps remain available. Explicit launcher status/readiness probes provide
current diagnostics on demand. Prior owned logging configurations are replaced
only after full ownership and security validation. This log policy is separate
from the 24-hour artifact/export TTL below.

The service retains at most 128 jobs and two active download workers, with a
128-MiB data bound across original bytes, active reservations and managed export staging. Each job is
bounded by 32 MiB and 300 seconds; cancellation cooperates with bounded socket,
resolver and gateway deadlines. Cancellation shuts down registered sockets to wake
SOCKS, TLS, header and body waits promptly, then joins the worker before deleting
partials or releasing its reservation. Cancellation before the manager coroutine's
first step persists a cancelled result and releases its unused reservation through
an idempotent completion callback. Executor completion is consumed directly after
a cancellation-safe wait, avoiding abandoned shield futures and unhandled errors.
Requested cancellation takes precedence over
transport/timeout errors from the interrupted I/O. The managed-alias resolver and
initial proxy connect precede socket registration and retain their existing shared
10-second maximum (or shorter remaining absolute deadline); cancellation during
that phase finishes only after it returns. No capacity is released while that
worker can still write. The event loop owns one retention task, started
by initial managed MCP traffic; it expires terminal jobs and their staging every
minute after the 24-hour TTL. Startup reconciles orphan partials and publications. The periodic task also retries
orphan temporary-file cleanup and positively identified failed export deletions;
pending failed-export cleanup blocks further exports until recovered.
Export filenames refer to **service-owned temporary staging**, not consumer-owned
storage. Consumers must copy verified exports into their own asset directory
before TTL expiry. The service never traverses or cleans consumer directories.

Readiness resolves the managed alias in an asynchronous subprocess with a one-second
deadline; cancellation and timeout kill and reap the helper. Numeric socket probes
are asynchronous, so stalled DNS cannot block unrelated MCP work.

Session creation is serialized and capped at 16. A single maintenance task closes
unlocked sessions after 30 minutes idle; active locked sessions are skipped.
Every retrieval operation has an administrator 60-second deadline, independent of
caller null or large timeouts. Per-session and creation lock waits are capped at
two seconds; close is capped at ten seconds without holding a global lifecycle
lock. Unknown upstream work poisons its session, retains its slot and is cancelled;
cancellation-suppressing tasks are capped globally at 32. They cannot spawn
unbounded replacements. A separate one-second health task signals the trusted local
supervisor when 32 cancellation-suppressing tasks (or all16 session slots
poisoned by such outstanding work) persist for 60 seconds, or
immediately when session creation enters irreversible unknown-allocation poison.
The signal contains no request data or credentials. The supervisor replaces the
whole child process group, retaining its existing three-restarts/600-second budget
and 30-second cooldown. Signal handling takes at most the current five-second
probe plus three-second stop grace and cooldown (a configured budget of
40 seconds before child launch, including process reaping and polling);
MCP readiness can then take the configured 120-second startup grace. Saturation
detection adds at most 61 seconds. Ordinary individual timeouts, temporary capacity
pressure, target TLS failures and Tor outages do not send this signal. Other
clients can still open/list/close within the remaining capacity. Failed upstream
closure retains the slot and retries after a minute once outstanding work settles. Session creation
has a 60-second deadline; an unknown timed-out allocation blocks further opens
until supervised replacement rather than accumulating possible upstream resources. Process
restart loses in-memory sessions and capabilities must reopen them. Download
manifests survive restart; interrupted jobs fail and must be explicitly retried.
Storage failures are redacted, do not release unaccounted capacity, and remove
uncommitted manifest/export staging where storage permits. A failed export commit
can be retried without accumulating duplicate copies.

The gateway caps four streams/mappings, reference-counts shared targets, and
unmaps when the last stream closes. Unknown mapping state poisons the gateway
and terminates Tor, clearing mappings before supervised restart. Ordinary target
connection failure releases its mapping without restarting healthy Tor. Gateway
handshake/connect/idle/total deadlines are 5/10/15/310 seconds. Supervisors probe
local SOCKS/gateway/control and MCP health every 15 seconds, allow 120 seconds
startup, and restart after three failed probes with 30-second cooldown. They
allow three child restarts per 600 seconds before exiting for container restart;
persistent outages remain failed readiness without direct fallback. Operators
should monitor repeated supervisor exits, local health, failed jobs, free disk,
state ownership and retained staging; logs intentionally omit caller capabilities
and target query secrets. Container restart policy continues recovery attempts;
it does not make an unavailable Tor network healthy.

Repeated-cycle deterministic tests exercise session cap/expiry, download/export
retention, failed storage commits, and 32 failed gateway connections with zero
retained mappings/stream slots. These bounded fixtures are not a multi-day soak
or controlled network-outage acceptance test.


Cycle2 review remediation verified the final current source with
`cycle2-deterministic-final.log`: container14, Codex6, health9, supervisor8,
policy30, binary26, gateway9 and installer44 passed. Policy regressions include
stuck resolver timeout/cancellation with child reaping, null/huge caller timeout,
cancellation-suppressing session work, stuck close and independent client progress.
`cycle2-release-gate.log` completed successfully with isolated Podman storage.
It repeated worker exact-byte HTTPS acquisition/export, live SafeSocks pinning and
shared mapping cleanup, and proved an unrelated egress-bridge peer cannot negotiate
port9052 on either Tor address. Worker control-cookie/port isolation also passed.
No external canary retry was needed in cycle2. Current runtime schema is retained
as `cycle2-runtime-schema.json` (15 tools), under `/tmp/basix-tor-acquisition/`.
Cycle2 Tor image ID was
`6a9a8608016d977c5e8070476f5eca3dd2f42c43a42967fd6cd7425533d28b8c`;
Scrapling/MCP/Tor package versions and pinned upstream digest remain as above.
Source/payload policy identity is recorded in `cycle2-runtime-source-sha256.log`.
All started tests finished; isolated scratch was removed. These checks do not
supply the missing controlled observer/DNS fixtures or change C03/C10/C16 status.


The maintained [actual runtime schema](tor-download-runtime-schema.json) contains
only the reviewed15-tool metadata and input schemas, with no client capabilities,
session values or request content. Its adjacent version context is Scrapling0.5,
MCP SDK2.3.0 and the immutable upstream digest
`sha256:1d876879813759959bc4ba6fbb1ce8247ebbc2b67eee77b140baf7c80af6ae6b`.
The final cycle3 gate below corroborates that snapshot against actual tools/list.


Cycle3 final review remediation connects irrecoverable policy health to the
existing bounded supervisor recovery. Unknown session creation fails immediately;
32 abandoned upstream tasks, or all16 session slots poisoned by abandoned work,
fail after60 seconds. A separate one-second watcher detects saturation even while
expiry cleanup is busy. Cancellation accounting remains effective if upstream
suppresses cancellation and calls Task.uncancel(). Ordinary individual timeouts,
temporary capacity pressure, external target errors and Tor outages do not trigger
this signal. Recovery retains the existing finite restart budget.

The frozen-source deterministic aggregate completed successfully in
`/tmp/basix-tor-acquisition/cycle3-deterministic-final2.log`: container14, Codex6,
health9, supervisor9, policy32, binary26, gateway9 and installer44. The final isolated
real gate completed exit0 in `cycle3-release-gate.log`, including policy health
signal recovery without restarting its container, restored Tor-only requests,
577-byte verified binary export, shared mapping cleanup, worker control isolation
and egress-peer gateway rejection. Its actual tools/list produced the maintained
schema above, SHA256
`078dec19ceacbaf40b370001c491a0a54bb1e07d623925468ebf29e4cb929930`.
Tor image ID was
`74047c1f160747467c11106459e6927ffec39967f342ff9fe0aa87ad2b0266a8`;
package versions and pinned upstream digest remain as above. Matching final source
and installed policy/supervisor hashes are retained in
`cycle3-runtime-source-sha256.log`.

Two earlier real runs failed the neutral external IsTor canary after deliberate
child recovery (`cycle3-release-gate-initial.log` and
`cycle3-release-gate-frozen-failure.log`, exit9); an intermediate run passed
(`cycle3-release-gate-pre-final.log`). The final successful run was the single
parent-authorized unchanged retry of the frozen source: no TLS, routing, canary
or production recovery policy was weakened. Those target failures alone do not
prove a global Tor outage. All started tests finished and isolated scratch was
removed. Controlled observer/DNS acceptance and actual Aqara integration remain
unmet as identified above; this is not full P0 or multi-day soak evidence.

## Scrapling 0.5.1 verification (2026-11-05)

The focused deterministic aggregation
`bash test/setup/install-scrapling-codex/test-install-scrapling-codex.sh` passed,
including 35 policy tests, 10 MCP health tests and 44 installer scenarios.
`bash test/setup/install-scrapling-codex/release-gate-podman.sh` then passed against
Scrapling 0.5.1 and MCP SDK 2.3.0, with immutable upstream image
`docker.io/pyd4vinci/scrapling@sha256:5ed7aeef430515fd35f3d97f482da73fb1d519dc17b6cb28ea366869c8642d98`.
The final Tor image ID was
`0498f2f2e88663ad0207ff597d36c13bce3dbe7e3157eee94eb52da92b9d92f9`.

The live gate verified the 16 public tool schemas, HTTP and browser IsTor
responses, bounded observation of the existing Tor-loaded page, foreign-owner
denial, direct TCP/UDP isolation, restart/IP-drift recovery, log non-retention,
numeric SafeSocks mapping cleanup and control/gateway access restrictions.
A static page was sufficient for the screencast API smoke; this does not prove
every animation or challenge workflow. Evidence logs are under
`/tmp/basix-scrapling-051-checks/`: `deterministic-final.log` and
`live-gate-retry.log` (including the complete emitted runtime schema).
The older checked-in schema snapshot remains the historical 0.5 baseline.

The initial gate failed because the proposed data-URL test page was rejected;
the test now observes the existing Tor-loaded page. The next gate failed an
external IsTor canary after child recovery. The final unchanged retry passed;
no TLS, Tor routing, canary or recovery conditions were weakened. The official
release notes and tagged implementation were checked against the real image;
third-party release listings were discovery leads, not independent security
evidence. These are isolated runtime results, not a host deployment or a soak.
ADR 0007's system-DNS exception and the existing acceptance gaps remain.
