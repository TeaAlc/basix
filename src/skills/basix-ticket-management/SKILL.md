---
name: basix-ticket-management
description: "Basix-Skill: Use at session startup and after compaction, and when creating, processing, closing, reopening, or recovering tickets in any service."
---

# Basix Ticket Management

Read the complete `basix` router first. This skill defines service-independent
rules; existing authorized tools provide service access. It installs no service
client, background worker, or retry scheduler.

At session start and after compaction, load this skill completely and silently
inspect project-local `.basix/tickets/open/` and `.basix/tickets/failed/` if they
exist. Report only relevant action needs, unresolved failures, or blockers. Do
not create storage merely to inspect it. A due retry is not permission to act.

## Ownership, context, and service workflow

- The coordinating agent is the sole writer of `.basix/tickets/`, including
  metadata and drafts for creation delegated to another agent. Delegates return
  creation results, confirmed identity and timestamps to that coordinator.
- Create storage on demand. `open/` and `closed/` contain only metadata for
  tickets created by the current project's agents. Processing somebody else's
  ticket requires no local record and must not add one to these directories.
- Use context and available service information to determine instance, scope,
  templates, required fields, language, workflow, and access route. Resolve
  operational questions through that context or in the existing ticket. Remote
  creation, comments, transitions and retries remain within the authorized task.
- Write service content in the service's default language; use English when it
  is unclear. Include the situation, relevant evidence, expected and actual
  behavior, reproduction or processing steps, and acceptance criteria as
  applicable. Follow service templates. A creator or later processor must be
  able to understand and act on the ticket without this conversation.
- Follow the service workflow for closure and reopening. After confirmed closure,
  move the local metadata unchanged from `open/` to `closed/`; after confirmed
  reopening, move it unchanged back to `open/`. An unreachable service or an
  unconfirmed transition does not change local state. Resolve ambiguous service
  outcomes before another transition. Hints may be updated independently.

## Service mapping

`.basix/tickets/systems.json` is a JSON object keyed by service abbreviations.
Each value has exactly four string fields: `service` (product), `instance`
(concrete installation), `scope` (project/account context), and `access`
(available tool or other authorized access route). Do not store credentials,
tokens, authentication headers, or secret access URLs.

Each abbreviation matches `[a-z0-9-]{1,16}`. Allocate separate keys for distinct
instances or scopes and preserve existing mappings used by records. Do not
reassign a key to another instance or scope. The pair `(system, id)` uniquely
identifies a created ticket across both metadata directories; reconcile existing
records instead of making a second record for the same pair.

```json
{
  "gh-shop": {
    "service": "GitHub",
    "instance": "https://github.com",
    "scope": "example/shop",
    "access": "Authorized GitHub connector"
  },
  "gh-internal": {
    "service": "GitHub Enterprise",
    "instance": "https://git.example.org",
    "scope": "platform/shop",
    "access": "Authorized enterprise service tool"
  }
}
```

## Created-ticket metadata

Use `open/<datetime>_<system>_<ticket_id>_<ticket_abbreviation>.json`, or the same
basename in `closed/`. The datetime segment is the literal UTC timestamp used in
the record, for example `2026-10-11T14:30:00Z`. `system` and the English topic
abbreviation each match `[a-z0-9-]{1,16}`. In the ticket ID segment preserve ASCII
letters, digits, dot and hyphen; percent-encode every other UTF-8 byte with
uppercase hexadecimal (including underscores and percent signs). For example,
ID `TEAM/42_ä` becomes `TEAM%2F42%5F%C3%A4`. Never decode this segment to infer
identity when the JSON ID is available.

Metadata has exactly these five keys:

- `id`: unchanged service ID as a string, retaining its case and formatting.
- `datetime`: confirmed creation time in UTC at second precision,
  `YYYY-MM-DDTHH:MM:SSZ`. Prefer the service creation timestamp; otherwise capture
  time immediately after confirmation. Convert service time to UTC and discard
  subsecond precision. Never replace it later, including after a later lookup.
- `url`: direct ticket URL, or the empty string if unavailable.
- `title`: the first at most 32 Unicode characters of the service title, without
  an added ellipsis. Count Unicode code points, not encoded bytes.
- `hints`: mutable array of short English strings with useful local processing
  notes; use an empty array when there are none.

Preserve the basename permanently, including after service title changes,
closure, reopening, or hint updates. Initial naming uses the immutable creation
time and a short English topic. Do not overwrite another record or silently
resolve a conflicting mapping. Write durable JSON safely, replacing a complete
record atomically where supported.

Example `open/2026-10-11T14:30:00Z_gh-shop_42_checkout.json`:

```json
{
  "id": "42",
  "datetime": "2026-10-11T14:30:00Z",
  "url": "https://github.com/example/shop/issues/42",
  "title": "Restore checkout availability",
  "hints": ["Check the payment gateway recovery."]
}
```

## Durable creation drafts

Before an initial creation call, capture its start time, generate a canonical
RFC 4122 UUID v4 from a cryptographically secure system source, and persist the
complete recoverable draft. Stop before the remote call if this cannot be saved.
The UUID is the draft's local `id`, not a service ticket ID. Use
`failed/<datetime>_<system>_<uuid>_<ticket_abbreviation>.json`; here `datetime`
is the initial attempt's start time in UTC seconds. Keep the UUID, timestamp and
basename unchanged through every recovery and retry. A pending draft is valid
in `failed/`; this directory stores creation recovery, not created metadata.

The draft has required keys `id`, `datetime`, `title`, `hints`, `request`, `error`,
`initial_attempt`, and `retries`. `title` is the full proposed service title,
`hints` are short English strings, and `request` is an object containing the
complete service creation data, including destination and every required field.
Keep content in the service language. Exclude all authentication data; reconstruct
access through `systems.json` and authorized tools. `error` is a short English
summary of the latest problem, or empty while an attempt is pending.

`initial_attempt` and every `retries` element have exactly these keys:

- `attempt`: integer `0` for the initial attempt; retries numbered `1` through
  `5` without gaps or reuse.
- `started_at`: UTC seconds captured and durably persisted immediately before
  the remote creation call. A persisted started retry consumes its allowance
  even when the call fails, never reaches the service, or has an uncertain outcome.
- `finished_at`: UTC seconds captured after observing the outcome, or `null`
  while pending. Preserve recorded timestamps.
- `outcome`: `pending`, `failed`, `uncertain`, or `confirmed`.
- `error`: short English error, empty for pending or confirmed outcomes.

Append a retry with `pending` before its remote call, then update that same entry
with its outcome, finish time and error. Keep all previous entries. After an
interruption, treat a pending attempt as uncertain, never as unused. Search for
its service result; if the outcome remains uncertain, record the recovery
observation time as `finished_at`, `outcome: "uncertain"`, and a short error.
This conservatively starts the next delay at the recovery observation.

An optional `confirmed` object has exactly `id`, `datetime`, `url`, and `title`:
the unchanged service ID, immutable confirmed creation time, direct URL or empty
string, and full service title. Save it as soon as creation is confirmed so a
local metadata write failure can be recovered without another creation call.
The draft schema is deliberately different from the exact five-key metadata
schema. Never copy the whole draft into `open/`.

Example `failed/2026-10-11T14:30:00Z_gh-shop_550e8400-e29b-41d4-a716-446655440000_checkout.json`:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "datetime": "2026-10-11T14:30:00Z",
  "title": "Restore checkout availability after gateway outage",
  "hints": ["Search for an existing ticket before retrying."],
  "request": {
    "repository": "example/shop",
    "title": "Restore checkout availability after gateway outage",
    "body": "Checkout returns HTTP 503 after the gateway outage. Reproduce with a test cart. Restore successful checkout and verify gateway recovery.",
    "labels": ["bug"]
  },
  "error": "The retry response did not confirm creation.",
  "initial_attempt": {
    "attempt": 0,
    "started_at": "2026-10-11T14:30:00Z",
    "finished_at": "2026-10-11T14:30:10Z",
    "outcome": "failed",
    "error": "The service was unavailable."
  },
  "retries": [
    {
      "attempt": 1,
      "started_at": "2026-10-11T14:35:10Z",
      "finished_at": "2026-10-11T14:35:20Z",
      "outcome": "uncertain",
      "error": "The retry response did not confirm creation."
    }
  ]
}
```

## Bounded recovery and retries

1. Check a draft's confirmed identity first. If present, recover regular metadata
   and never recreate that confirmed ticket. For an uncertain or interrupted
   outcome, search the service for an already-created ticket before any further
   creation call; reconcile evidence against the instance, scope and request.
2. Before **each** retry, verify that the original problem still exists. If it is
   proven resolved, delete the unnecessary draft. If persistence cannot be
   verified, retain the draft and do not retry. Do not delete a confirmed identity
   before its metadata is saved; recovery of an already-created ticket takes
   precedence over deleting a now-unnecessary creation draft.
3. Permit at most five additional creation attempts after the initial attempt.
   Retry 1 waits at least 5 minutes, retry 2 at least 30 minutes, retry 3 at least
   2 hours, retry 4 at least 12 hours, and retry 5 at least 48 hours **after the
   previous attempt's `finished_at`**. If it is null, resolve the pending attempt
   as above first. These are minimum delays, not scheduled execution times.
4. Retry only during active, authorized work when the delay has elapsed and the
   problem is verified to persist. Do not start background activity or a wait
   loop. Recheck authorization, service access and available creation evidence.
   If existing creation remains unclear, another creation attempt may occur
   within that authorization and remaining budget. Reuse the same UUID as the
   idempotency key where supported; otherwise record possible duplicates in hints
   and search for them. An inconclusive search is not proof that creation failed.
5. Persist the started retry before calling the service. On success, preserve the
   confirmed service identity and creation time, then save regular five-key
   metadata in the appropriate directory (`open/` unless service state confirms
   closure). Only after verifying that durable metadata exists delete the draft.
   If a local write fails, retain the draft and its confirmed identity and report
   the recovery blocker. If identity cannot be persisted either, preserve it in
   the active result/context and report the storage blocker; never recreate it.
6. After the fifth unsuccessful or uncertain retry, retain the complete draft
   and report the blocker. Never reset its UUID, history, or retry allowance.
   Recovery searches and saving metadata for a later-confirmed ticket remain
   possible without another creation attempt.

Keep service-side processing notes in the ticket when needed by other processors;
local hints supplement them. Report meaningful ticket results and blockers with
direct links when available, without routine startup inspection announcements.
