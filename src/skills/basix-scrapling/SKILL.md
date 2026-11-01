---
name: basix-scrapling
description: "Basix-Skill: Use before Scrapling web retrieval, browser research, or Tor binary acquisition and offline artifact handoff."
---

# Basix Scrapling

Read the complete `basix` router first; managed agents also follow its mandatory
management/Contract 2.0 boundary. For information research, load
`basix-source-memory` and preserve its source observations, independent discovery,
corroboration, use roles and authorized-writer persistence workflow.

## Discover and preserve the boundary

Inspect the complete available tool inventory, including deferred tool discovery,
and the actual input schemas before calling the `scrapling` MCP server. Resources
and resource templates do not establish tool availability. Names vary by caller;
use discovered tools rather than assuming older `get`/`fetch` names still exist.
The current binary API has exactly these five operations:

| Tool | Required inputs | Optional inputs |
| --- | --- | --- |
| `download_start` | `client_id`, `url` | `expected_sha256`, `maximum_bytes`, `time_budget`, `idempotency_key` |
| `download_status` | `client_id`, `job_id` | None |
| `download_cancel` | `client_id`, `job_id` | None |
| `artifact_info` | `client_id`, `artifact_id` | None |
| `artifact_export` | `client_id`, `artifact_id` | None |

If required tools are absent, declarations are stale, or schemas differ from the
needed contract, stop the affected operation and report the missing/stale API to
the spawning parent under Contract 2.0. Do not fall back to direct HTTP, another
browser or remote-code downloader, repair the service, or automatically install
or deploy it. The parent can arrange separately authorized installation using
Basix `install-scrapling-codex.sh` (requires Podman or Docker) and caller/schema refresh.

All Scrapling request, browser and binary traffic must use the managed Tor route.
Clients may share the managed proxy; client isolation does not require separate
Tor instances. Never supply proxy/network overrides or bypass failed Tor readiness.
ADR 0007 permits system resolution of the internal managed Tor alias: DNS metadata
may reach host resolvers. Application HTTP DNS uses SOCKS5h through Tor; the binary
transport uses Tor remote resolution and validated pinned destinations. Do not
claim every DNS lookup uses Tor, complete browser SSRF isolation, full strict
acceptance, a multi-day soak, or deployment based on source or isolated tests.

## Secret client capability and authority

The calling agent is the MCP client. Generate a canonical RFC 4122 UUID v4 from a
cryptographically secure system source, keep it private in caller memory, and
pass it as `client_id` on every Scrapling tool call. Reuse the same ID for related
sessions, jobs and artifacts. Never log it, embed it in URLs/headers, or expose it
in ordinary reports, files or examples. Never use `default`, a `session_id`, an
invented constant or server-generated placeholder. Opaque job/artifact IDs alone
do not grant access; the same owner capability is required.

Only deliberately authorized same-owner session sharing with the direct parent
may transfer that capability. Do not silently share capabilities between agents.
The capability is a trusted-local ownership boundary, not remote-user authentication.

This skill grants no write authority. The read-only `basix_researcher` may perform
its authorized retrieval/session research, but must not call `download_start`,
`download_cancel` or `artifact_export`, or write files. For binary collection,
request an authorized writable parent to acquire/export/copy the asset; return the
source URL, expected publisher checksum when available, byte/time requirements,
and offline destination requirements without a capability. It may inspect
`download_status` or `artifact_info` only when the same-owner capability was
deliberately shared and those inspections were authorized. Tool annotations do
not override the researcher's role boundary.

## Authorized binary collection

Extraction returns page content, not exact binary bytes. Use binary acquisition
for archives, firmware, images and other assets requiring preserved bytes. Never
reconstruct them from extracted text or use browser-assisted binary downloads,
remote code execution, resume/append, or arbitrary credentials/headers/cookies.

1. An authorized writable caller supplies an HTTP(S) `url` (ports 80/443). Set
   `expected_sha256` to the known publisher digest, exactly 64 lowercase hex
   characters, when available; otherwise omit it and report the authenticity gap.
   A self-computed hash proves consistency only. `maximum_bytes` is a positive
   integer, default 33554432 (32 MiB), clamped to the administrator cap.
   `time_budget` is an integer 1–300 seconds, default 120. These limits do not
   authorize larger administrator limits. Optional `idempotency_key` is a private
   1–128 character retry key: the same owner/key/identical payload returns the
   retained job; a changed payload conflicts. Expired keys can be reused.
2. Call `download_start` once and retain `job_id`. Start enqueues work; a returned
   job ID or `running` state is not a usable asset. Poll `download_status` at a
   modest interval with a finite caller deadline and poll count derived from the
   requested time budget plus bounded cancellation/transport cleanup. Status only
   observes; it never restarts or retries a transfer. Progress may include
   `bytes_received`. Do not automatically restart/retry on a status error, timeout,
   capacity error or a retryable failure; report it for an explicit parent decision.
3. Only terminal `completed` permits artifact use. Terminal `failed` or
   `cancelled` provides no usable bytes. An authorized caller may request
   `download_cancel`; cancellation is cooperative, and its response can still be
   `running`. Observe until terminal within the bounded observation window; if it
   remains running, report unresolved cancellation without claiming success or
   starting a replacement. A race may return `completed`; cancellation is not
   deletion and terminal states must be handled as returned.
4. With the returned `artifact_id`, inspect `artifact_info` under the same owner.
   Check `length`, `sha256` and available provenance/TLS metadata against the
   intended source and known digest. Failed, incomplete, expired or other-owner
   artifacts are unavailable. HTTP content encoding other than absent/identity is
   rejected; binary gzip/ZIP bytes without HTTP content encoding remain exact.
5. Call `artifact_export` only with `client_id` and `artifact_id`. It returns
   `filename`, `length`, `sha256`; the filename is relative to the administrator's
   fixed export root, not an arbitrary caller path or base64 body. Use the trusted
   local administrator-provided channel/root to access it; never infer a host path
   from a container path or let Content-Disposition select a destination.
6. Exports are service-owned temporary staging. Jobs/artifacts/exports expire after
   24 hours; repeated export returns the same retained filename. An authorized
   writer must verify local export size and SHA-256, copy it into consumer-owned
   durable asset storage before expiry, and reverify the copied size/hash. Give
   offline consumers that local asset and integrity metadata. Missing/expired
   assets must fail visibly; they never authorize implicit future network access.

The administrator bounds workers, retained jobs and storage. Capacity pressure,
Tor unavailability or cleanup failures are reasons to report a blocked collection,
not to weaken limits or repair/restart the host. No workflow here automatically
installs, deploys or claims host readiness.
