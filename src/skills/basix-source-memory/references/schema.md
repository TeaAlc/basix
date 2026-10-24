# Source-memory contract

## Identity and text

A key is a lowercase IDNA domain/subdomain plus an optional case-sensitive
stable path. HTTP(S) URLs and bare keys are accepted; the scheme is discarded.
Root and trailing slashes are removed. Subdomains and tenants remain separate;
no registrable-domain guessing occurs. Reject ports, credentials, query strings,
fragments, IPs, single-label hosts, dot segments, repeated internal slashes,
backslashes, and encoded dots/separators/percent/control bytes. Path keys require
a nonempty `scope` explaining why that stable section differs in subject,
source type, or scope. Do not store article URLs as source identities.

`find` explains locating information; `contains` explains its content. Each is
nonempty plaintext of at most 32 whitespace-separated words. Markup and control
characters are rejected. `source_type` is descriptive metadata, never a second
identity. `scope` is the actual assessment scope; use an explicit nonempty scope
for any assessed source. One key has one record.

## Categories

Both catalogs have integer `version = 1`, nonnegative integer `revision`, and an
array: `sources = [...]` or `categories = [...]`. Array entries are inline TOML
tables. Categories contain exactly `id` and `description`: lowercase slug IDs
are at most 16 characters and descriptions at most 16 whitespace words.
Source `categories` contains 1–5 distinct existing IDs. Facets overlap;
`computing` is optional. `guides` and `best-practices` apply across subjects,
including cooking, medicine, and software. The 37 shipped facets are defaults,
not a disjoint classification or a requirement to create narrow technology tags.

Creation requires an agent semantic overlap check. The helper rejects normalized
identical descriptions and incompatible same-ID definitions; it cannot establish
semantic uniqueness. Identical additions are idempotent. Initialization seeds
only missing IDs and preserves existing first-creator meanings, even if a seed
ID already has a different meaning. Inspect local definitions before tagging.

## Trust and assessment

`trustability` is exactly integer -1, 0, or 1; booleans are rejected. Unknown
sources start 0, `assessment_status = "unassessed"`, with no current assessment.
A reasoned neutral or opinion source is 0 and `assessed`.

| evidence_quality / accountability | traceable | unknown | deceptive |
|---|---:|---:|---:|
| strong | 1 | 1 | -1 |
| open | 0 | 0 | -1 |
| unreliable | -1 | -1 | -1 |

Strong requires representative independently verified evidence within the
recorded scope, rather than citations alone. Open means inconclusive evidence,
including unsupported or mixed claims. Unreliable requires positive evidence of
material uncorrected falsehood or systematic misleading presentation. Missing
evidence alone is not unreliability. Traceable means accountable authorship or
editorial responsibility; unknown includes pseudonyms or unclear identity;
deceptive requires evidenced identity/accountability deception. Unknown identity,
ads, opinions, or commercial interests alone never imply -1. Own-product
manuals can receive 1 when their scoped evidence supports it.

An `assessment` object has exactly: `date` (ISO YYYY-MM-DD, not future), `reason`
(nonempty plaintext), `evidence` (nonempty distinct exact HTTP(S) URLs),
`evidence_quality`, `accountability`, `scope`, and `trustability`. Scope must match
the source. Historical first assessments may predate entry creation; later reviews cannot
predate the previous review/history event. Current fields
are `assessment_status`, `assessment`, `last_reviewed`, and `trustability`.

Every initial assessment and every rating or assessed scope/type transition
appends a full compact `history` entry: assessment fields plus `old` rating,
`source_type`, and boolean `reset`. Changed ratings require a materially new explanatory reason and nonempty reviewed
evidence. The same URL may contain a correction, retraction, or ownership notice;
changed content at that URL can justify a new rating. The agent must independently
review the evidence and explain the change; the helper checks reason differences
and URL structure, not evidence freshness or semantic justification. An unchanged review updates current reason/evidence and
`last_reviewed` without appending history. History preserves its original
justification. Scope/type changes on an assessed source require explicit new
assessment or `reset` (same object shape, neutral matrix result and justified
reason/evidence); reset removes the current assessment and returns to unassessed.
Dates, chain continuity, current scope/rating, and matrix results are validated.

Contradictions, retractions, and relevant ownership/editorial/security/scope
changes trigger reassessment. Staleness indicates a review need; it does not
change trust automatically. Ratings never inherit across keys. `show --lookup`
permits longest segment-boundary matches; output exposes requested and matched
keys, `exact`, and `trust_applies_to_requested=false` for a parent match. The
returned rating describes only the matched record, never an unseen narrower key.

Evidence preserves harmless query parameters such as versions. Credentials,
fragments, whitespace, and known secret parameter names (token, access_token,
api_key, password, secret, authorization, credential, signature, key) are rejected.
Callers must redact personal data and other secrets; validation is not a secret
scanner. Error messages do not echo rejected input URLs.

## Usefulness and persistence

`helpful=true` requires a stable logical `task_id`, shared across retries and
child observations. SHA-256 of the JSON-encoded `[task_id, canonical_source]`
pair becomes the `id` in `usage_events`; raw task IDs/content are not persisted.
Each event is exactly `{id, roles, use_note}`. `roles` is a sorted distinct nonempty
array from the roles below. `use_note` is non-sensitive plaintext of at most 32
words stating the specific claim or purpose, without quotations or personal data.
`helpful=true` requires singular input `use_role` and `use_note` as well as task ID.
Retries union roles deterministically and retain the original note; they never
silently rewrite the historical purpose. `usefulness` equals the number of
distinct event IDs: helpful first use starts at 1,
otherwise 0. One task/source counts once; another logical task can increment.
Never infer trust from this count. Counters and events replace together atomically. This unreleased version 1 uses
`usage_events`; legacy `usage_hashes` is not accepted or silently migrated.

| Role | Meaning |
|---|---|
| support | Supports a specific factual claim after appropriate verification. |
| object | Artifact being studied, including a falsehood or its mechanism. |
| lead | Unverified starting point for further investigation. |
| position | Documents the author’s own claim or position, without establishing its truth. |

At current trust -1, adding NEW support to an event or creating a support event
fails without a write. Other roles remain useful and allowed. Historical support
survives a later downgrade; an identical existing task/source support retry remains
idempotent and is not a renewed endorsement. Validation never judges old usage
against current trust. Ratings and usefulness remain independent. All trust
ratings are visible by default; `list --role object` filters historical roles, not
credibility. Results include `use_roles`; `show --usage` exposes purposes and roles
without event IDs and warns that historical uses do not imply current trust.

Sources also contain ISO `created` (actual entry creation date) and `updated`
(most recent record date) dates. A historical assessment does not backdate creation. Unknown keys, invalid
TOML/types/references/revisions/dates/history fail without repair or overwrite.
Optional `expected_revision` on an observation rejects stale source revisions.
There is no category revision precondition; immutable additions merge under lock.

`init`, `record`, and `add-category` validate before creating directories/locks.
Only successful mutation initializes catalogs. `list`, `show`, and `validate`
never create anything. Writes reject symlinked project ancestors, `.basix`,
catalog directories/files, and lock files, plus hardlinked catalog files.
Use a trusted project directory: POSIX advisory flock protects cooperating
writers, not hostile concurrent directory replacement. The helper is local,
stdlib-only, and uses no network. Linux/POSIX Python 3.11+ is required.

Under `.lock`, each write reloads and validates both catalogs, preserving
unrelated concurrent updates. Each file uses fsynced temporary-file replacement.
Categories are replaced before sources: the pair is not jointly atomic. An
interruption may leave unused valid categories, never newly dangling source
references. Category-only recovery states are accepted; missing category data
for an existing sources file fails closed. No guessed repairs, journals,
archives, databases, or third durable catalog. A crash can leave an unused
`.source-memory-*` temporary file; it is not authoritative catalog data.

## CLI and observation examples

Set `HELPER` to this skill’s `scripts/source_memory.py` and use:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project list --category guides
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project list --text cooking
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project list --role object
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project show example.org/manual --lookup
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project show example.org --history
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project show example.org --usage
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project init
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project record --input observation.json
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project record --input - < observation.json
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project add-category geology "Earth materials, structure, geological processes, and planetary geological history."
PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" --project /project validate
```

`--project` defaults to cwd and precedes the subcommand. Successful output is
compact JSON with `ok:true`, source and category revisions; failures are JSON
`ok:false,error:{code:"catalog_error",message:...}`, exit 2. Argument syntax errors
use argparse stderr/exit 2. List/show omit usage events and omit trust history unless
`show --history`; `show --usage` separately includes historical usage purposes. Missing exact show matches return null, never inferred trust.

Minimal new observation (existing records allow partial updates):

```json
{"source":"recipes.example.org/learn","scope":"Stable cooking instruction section",
 "source_type":"practical guides","find":"Use the ingredient index and technique search",
 "contains":"Stepwise cooking methods and ingredient substitutions",
 "categories":["food","guides"],"helpful":true,"task_id":"recipe-research-001",
 "use_role":"lead","use_note":"Locate independent cooking technique evidence"}
```

Add `assessment` using the exact object schema above when independently justified;
do not supply one merely to fill fields. `new_categories` optionally contains
`[{"id":"geology","description":"..."}]` after semantic review. Other input
fields are `expected_revision`, `reset`, and partial source metadata fields.
Trust/counters/history/events cannot be directly overridden by observations.

## Read-only researcher handoff

Researcher final-result data carries `source_observations`, an array of proposed
observation objects using the `record` input schema. The direct authorized
parent checks scope, evidence, facets, and task identity, then merges each object
with the helper. Read-only researchers never initialize catalogs, add categories,
or run mutating commands. A proposal does not itself authorize a trust rating.

Final data also carries `research_coverage`. For substantive research use
`{mode, discovery_summary, new_independent_origins, dependencies, contradictions,
limitations}`: mode identifies substantive research; summary describes actual
outside-catalog discovery; origins records newly found independent origins;
dependencies records shared sources/syndication; contradictions records material
conflicts examined; limitations records missing independent evidence or other
bounds. Empty findings are honest when search effort found none, not a quota
failure. A narrow authoritative lookup may use `{mode:"lookup", reason:"..."}`.

## Research coverage scenarios

Consult the catalog first, then search outside remembered domains for substantive
research. Compare independent origins rather than counting republished articles.
Adapt corroboration to claim and risk; investigate material contradictions rather
than manufacturing false balance. The catalog must never monopolize discovery.

- Exact current API parameter lookup: an authoritative primary reference alone
  may suffice; report lookup mode and the narrow reason.
- Broad cooking guide or framework comparison: make an actual outside-catalog
  discovery effort, compare independent origins, and record new helpful sources.
- Disputed or high-impact claim: investigate independent supporting evidence and
  material contradictions; report remaining uncertainty, not a fixed source count.
- Fake-news mechanism analysis: retain the misleading site as an `object` (or
  its author’s `position`) while trust stays -1. Find independent evidence about
  the mechanism; studying the artifact does not make it factual support.
- Many syndicated articles: disclose the shared origin as a dependency, not
  multiple independent confirmations. If no independent origin can be found,
  report that limitation honestly.

## Design background

Broad-facet design drew inspiration from [IPTC Media Topics](https://iptc.org/standards/media-topics/)
and [IAB Content Taxonomy](https://iabtechlab.com/standards/content-taxonomy/).
The 37 Basix facets are an original local set, not an implementation of either
standard. [SIFT](https://hapgood.us/2019/06/19/sift-the-four-moves/)
informs source investigation; [IPTC trust and credibility guidance](https://iptc.org/std/guidelines/trust-and-credibility/)
informs the distinction between provenance signals and evidence of truth.
