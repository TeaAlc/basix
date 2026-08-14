---
name: basix-experience
description: "Basix-Skill: Write an evidence-based Markdown review of the current session. Use when the user requests session feedback, skill feedback, subagent feedback, token analysis, token-efficiency advice, or a review of the experience working with the available tools and agents."
---

# Basix Experience

Write a concise retrospective about the current conversation and its visible
execution evidence. Follow the language used by the user in the session; localize
headings, prose, satisfaction labels, and unavailable-value labels. Do not infer
hidden activity, reconstruct unavailable telemetry, or claim exhaustive coverage.

## Evidence rules

- Review only completed or attempted work visible in the conversation, tool
  results, or structured telemetry supplied to the session.
- Treat a skill or subagent as used only when its use is explicitly visible. Do
  not count a skill merely because it was available or mentioned.
- Exclude `basix-experience` itself from Skill feedback, including when
  its loading or invocation is visible.
- Identify a subagent by its visible task or agent name and its visible native
  role. Do not invent either value.
- Distinguish an explicit numeric zero from an unknown value everywhere.
- Never estimate exact token values or cache metrics from prose, message length,
  context size, tool output, elapsed time, or model behavior.
- The expirience report can be a chat message or a file, if saving it to a file
  use experience_<iso-datetime>.md as default filename.

## Collector-assisted telemetry

Before writing **Token usage**, resolve this skill's directory and attempt to run
its collector as:

`PYTHONDONTWRITEBYTECODE=1 python3 <skill-directory>/scripts/collect-token-usage.py --format json`

The collector is best-effort evidence and must never block or abort the report.
It discovers current thread identity and parent/child links from `session_meta`
and uses filename IDs plus `sub_agent_activity` only as a fallback for legacy
rollouts. Schema 2 preserves the generic `role` and adds the concrete metadata
`agent_role` for discovered subagents.

For schema-2-valid output whose `status` is `ok` or `partial`, use an aggregate
metric only when that individual field is non-null; such a value is complete
across every discovered thread. Map `reasoning_output_tokens` to reasoning tokens,
`output_tokens` to output tokens, `input_tokens` to input tokens, and
`cached_input_tokens` to the cache counter used for the derived hit rate.

Treat collector `error` output, invalid JSON, a missing Python interpreter, or an
unreadable or missing collector as unavailable telemetry. Structured telemetry
already supplied to the session remains a fallback. Select one complete source
for each report attempt: never add, merge, or fill fields across collector and
fallback sources. A failed collector does not change any other report section.

## Satisfaction scale

Choose one level for every evidenced skill and subagent. Translate the selected
label into the session language while preserving its meaning.

| Canonical level | Use when |
| --- | --- |
| `not at all satisfied` | It failed its purpose or caused serious harm, and produced no meaningful usable value. |
| `dissatisfied` | Material shortcomings outweighed its usable contribution or required substantial recovery. |
| `satisfied` | It met the core need, with ordinary limitations or some correctable friction. |
| `very satisfied` | It met the need reliably and efficiently, with only minor limitations. |
| `extremely satisfied` | It was exceptionally effective, materially improved the result, and showed no meaningful weakness in this session. |

Do not default to the highest level. Tie the rating to one to three concrete,
visible reasons.

## Report format

Return only a Markdown report with the following four top-level sections in this
order. Translate their displayed headings into the session language while keeping
the canonical meanings: **Task overview**, **Skill feedback**, **Subagent
feedback**, and **Token usage**.

### Task overview

Briefly summarize the session's material tasks and outcomes. Separate completed,
partial, and blocked outcomes when that distinction matters.

### Skill feedback

Cover every evidenced skill except this skill, once each. For every entry:

1. Start with a localized sentence equivalent to: `With skill <name>, I was
   <satisfaction>.`
2. Give one to three evidence-based reasons.
3. Emphasize exactly one most important strength or improvement, for example with
   bold text.

If no eligible skill is evidenced, state that no prior skill use is evidenced.
Optionally add one separate skill idea only when it would clearly help similar
future sessions. Keep the complete idea to at most 32 words; omit it otherwise.

### Subagent feedback

Cover every evidenced subagent once each. For every entry:

1. Start with a localized sentence equivalent to: `With agent <name> (<agent
   type>), I was <satisfaction>.`
2. Give one to three evidence-based reasons.
3. Emphasize exactly one most important strength or improvement.

If no subagent is evidenced, state that no subagent use is evidenced. Optionally
add one separate agent idea only when it would clearly help similar future
sessions. Keep the complete idea to at most 32 words; omit it otherwise.

**Example 1:**

I was satisfied with the work of <agent_name> (<agent_type>), he did his job and helped me with xyz.

- xyz was good
- abx helped me bacause ...
- def showed a shortcut to achive ...

What helped a lot was xyz.


**Example 2:**

I was not at all satisfied with the work of <agent_name> (<agent_type>), he did his job but made some errors and I had to do everything again.

- xyz was unclear
- abx was wrong because ...
- def was not what I asked for ...

The agent did not know his contract at all which made it hard to coordinate it. The agent would have been much better if he'd followed his instructions and knew his contract. 


### Token usage

Create a table with rows for input tokens, reasoning tokens, output tokens, and
cache hit rate. Use exact numbers only from accepted collector output or structured
telemetry supplied to the session. Render every absent or partial metric as a
localized equivalent of `not available`; never render an absent metric as zero.

Treat "thin tokens" as reasoning tokens only when that terminology is present in
the supplied telemetry or request. If both are present, do not combine them unless
the telemetry explicitly defines them as identical.

When `cached_tokens` and `input_tokens` are both available and input tokens are
greater than zero, derive the cache hit rate as
`cached_tokens / input_tokens × 100`, round to one decimal place, and label the
value as derived. When input tokens are exactly zero, report the rate as not
available and explain that division by zero prevents derivation. Preserve an
explicit zero for any other numeric metric.

Describe the largest token drivers qualitatively and only from visible evidence
unless step-level telemetry is supplied. Clearly label qualitative judgments as
such; do not assign token counts or percentages to individual steps without
structured step-level data.

Then add a table with exactly five concrete saving opportunities. Give each row a
unique rank from 1 through 5 and columns equivalent to **Cause**, **Action**, and
**Expected effect**. Base each opportunity on visible session evidence and use
qualitative effects unless telemetry supports exact values.

Finish with one prioritized improvement recommendation identifying the single
best next change for a similar session. Keep it evidence-based and do not repeat
all five table rows.
