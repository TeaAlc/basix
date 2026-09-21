---
name: basix-subagent-efficiency
description: "Basix-Skill: Analyze delegated task success across repeated attempts, including first-shot success, retry coverage, recovery, failure causes, interventions, cost, and latency. Use for subagent call efficiency and multi-shot success analysis."
---

# Task-Level Multi-Shot Success Analysis

Analyze **per delegated task**, never per subagent, process, session, or
conversation. Optimize reliable completion while minimizing avoidable attempts,
recovery cost, latency, and persistent failure. This skill analyzes observed work;
it does not authorize executing retries or impose a universal retry limit.

Load the Basix router and follow its applicable runtime instructions. Use this
skill for task recovery metrics; use `basix-experience` for a broader session
review when requested. A session token total alone cannot establish task outcomes
or attribute costs to individual attempts.

## Establish the evidence

Use supplied assignments, traces, returned results, parent feedback, acceptance
checks, and available usage records. State the observation window, cutoff,
configured maximum attempt depth K (if any), and evidence coverage. Inspect only
the evidence needed for the requested analysis. Cite trace locations or stable
event identifiers without reproducing secrets or unrelated private content.

If evidence is unavailable, identify the missing artifacts and report the limits;
never invent attempts, acceptance decisions, costs, or timestamps. Distinguish
agent self-reported completion from demonstrated acceptance. Keep observed facts,
inferences, and recommendations distinguishable.

## Task and attempt boundaries

A **task** is a distinct delegated objective with relevant context, expected
output, and completion or acceptance criteria. A materially new or independent
objective starts a new task, even on a persistent subagent.

An **attempt** is one execution cycle toward that objective. It ends when the
task succeeds, a returned result fails acceptance, the agent reports inability,
execution fails and another attempt is required, or the parent initiates
corrective instructions or a restart. A corrective instruction must materially
redirect the execution cycle; routine information exchange is not a retry.

Internal tool calls, searches, tests, debugging, self-correction, inspection,
revision before return, and internal verification stay within the same attempt.
Apply these boundary rules in order:

1. New or materially changed objective → new task and Attempt 1.
2. Repair of an incomplete, incorrect, or rejected result toward the original
   objective → next attempt of the same task.
3. Clarification requested and received before a failed return may remain in the
   current attempt.
4. Corrective work after a returned result fails acceptance → next attempt.
5. Reusing or replacing a subagent does not determine task identity.

Diagnosing a timeout and then implementing the diagnosed fix are separate tasks.
Implementing function X, failing requirement Y, and correcting Y are two attempts
of one task. Shot n means Attempt n after all earlier attempts failed. There is
no later attempt after success; subsequent independent work is a new task.

Basix agent identity, `cycle_revision`, messages, and `final_result` statuses are
evidence, not task IDs, attempt counters, or automatic acceptance verdicts.
A replacement agent can retry the same analytical task; a persistent agent can
execute multiple tasks. Do not change runtime communication rules to fit the
analytical model.

## Normalize and score

Create one row per **observed attempt**, using this canonical table as the source
of aggregates:

```text
Task ID | Task | Subagent | Attempt Number | Result
Primary Cause | Secondary Cause | Retry Intervention
Cost | Latency | Model | Tool Usage | Evidence
```

Use stable task IDs and evidence-backed attempt numbers. Never create rows for
unexecuted attempts or hard-code three attempts as a maximum. Preserve unknown
boundaries explicitly rather than guessing. Use one outcome per row:

| Result | Meaning |
|---|---|
| Success | Acceptance criteria are satisfied. |
| Failure | Attempt ended without satisfying acceptance; more work is needed. |
| Unscorable | Necessary criteria, output, trace, or acceptance evidence is missing. |

An attempt still in progress at cutoff is Unscorable, not a demonstrated failure.
Keep all rows, including Unscorable, in the normalized table. For the default
aggregate cohort, include only tasks with a known, contiguous sequence from
Attempt 1, scorable observed outcomes, and no ambiguous intervening attempts.
Report excluded tasks and unscorable attempts separately, with reasons. A task
with a known failed attempt and no retry is scorable and unresolved.

Use this same fixed cohort for all primary metrics. If reporting usable portions
of excluded tasks, show them separately with explicit denominators; do not silently
mix cohorts. A later known success after an unscorable attempt does not establish
the first successful attempt. State potential bias from evidence exclusions.

Optional derived task summary:

```text
Task ID | Final Result | Success Attempt | Attempts Executed
Final Failure Cause | Recovery Intervention | Total Cost | Total Latency
Evidence | Preventable By
```

## Compute the recovery curve

For the scorable cohort, define T = total tasks, A_n = tasks reaching Attempt n,
S_n = tasks first succeeding on n, F_n = tasks failing n, and
C_n = S_1 + ... + S_n. Check A_1 = T, A_n = S_n + F_n, and
A_(n+1) ≤ F_n; equality in the last relation requires every failure to be retried.

| Metric | Formula |
|---|---|
| 1st-Shot Success | S_1 / T |
| Cumulative Success by n | C_n / T |
| Retry Coverage n, n ≥ 2 | A_n / F_(n-1) |
| Recovery Rate n, n ≥ 2 | S_n / A_n |
| End-to-End Recovery n, n ≥ 2 | S_n / F_(n-1) |
| Marginal Shot Value n | S_n / T |
| Unresolved Rate by n | (T - C_n) / T |
| Retry Efficiency through observed depth D | (S_2 + ... + S_D) / (A_2 + ... + A_D) |

Use D as the maximum observed attempt depth in the fixed scorable cohort at the
cutoff, independently of configured K. With no retries, Retry Efficiency is N/A.
Report numerator and denominator alongside percentages. A zero denominator means
N/A, never zero success or perfect success. For defined terms,
End-to-End Recovery_n = Retry Coverage_n × Recovery Rate_n. This separates
whether retries occurred from whether executed retries worked.

Use **Persistent Failure Rate = F_K / T** only when K is the configured maximum
attempt depth and every remaining failed task actually exhausted that path.
K counts total attempts, including Attempt 1; distinguish it from additional
retries. If failures stopped earlier or K is unknown, report Unresolved Rate at
the cutoff instead. Do not treat missing observations as exhausted retries.

Report average attempts to success among successful tasks; optionally median and
P90, naming the percentile convention. These are conditional on success and
exclude unresolved tasks. If none succeeded, use N/A. Label the observed maximum
depth separately from configured K; there need not be any retry cap.

## Classify each failed attempt

Assign exactly one primary cause and normally at most one secondary cause to
each Failure. Choose the **earliest meaningful evidenced cause in the causal
chain**. If a specific cause cannot be established, use the fallback label
`Undetermined / Evidence Gap` and explain the gap rather than inventing a cause.

| Category | Use when / boundary |
|---|---|
| Ambiguous Task Definition | Objective, terminology, instructions, ownership, or boundaries are unclear or contradictory. |
| Missing Context | Required files, state, constraints, rules, or decisions were unavailable to the attempt. |
| Poor Scope or Decomposition | Task is too broad, bundles independent objectives, or hides dependencies. |
| Undefined Success Criteria | Definition of done, output, validation, or quality threshold is unclear. |
| Reasoning or Solution Error | Information was sufficient, but approach, inference, diagnosis, or implementation was wrong. |
| Tool or Execution Failure | Tool, API, environment, permission, timeout, shell, browser, or file access blocks execution. |
| Retrieval Failure | Required information was accessible but not found or retrieved; distinguish unavailable context. |
| Output or Interface Failure | Solution is substantially correct but violates schema, JSON, patch, fields, format, or response contract. |
| Verification or Quality-Control Failure | Available, reasonable validation could have caught an error before return but was omitted or ineffective. |
| Orchestration or System Failure | Surrounding architecture, wrong agent/model, stale state, routing, ordering, conflicting work, or parent misuse caused failure. |

Missing required schema → incorrect code → omitted tests: primary Missing Context,
secondary Verification or Quality-Control Failure. If information was sufficient
but the solution wrong, primary Reasoning or Solution Error. Verification is
secondary when it merely missed an earlier root cause. Undefined criteria may
make an outcome Unscorable; do not invent Failure just to assign that category.

Optional groups: Input & Delegation (first four categories), Agent Capability
(Reasoning), Execution & Retrieval (Tool and Retrieval), Output, Quality & System
(last three). Causes are attempt-specific and can change across retries.

## Analyze interventions and impact

For every Attempt 2+, record the material change from the prior attempt, whether
it succeeded, whether the failure category changed, and its cost. Use applicable
labels (multiple when supported):

```text
Additional Context; Clarified Instructions; Reduced Scope; Alternative Reasoning;
Additional Tool Access; Additional Retrieval; Explicit Error Feedback;
Verification Feedback; Different Agent or Model; No Material Change
```

No Material Change requires evidence of repetition; for missing intervention
evidence use the fallback label `Unknown / Evidence Gap`.
Do not combine No Material Change with another material intervention. Reducing
scope while preserving the original acceptance objective can be an intervention;
replacing that objective follows the new-task rule.

Repeated Missing Context → Missing Context → Missing Context suggests the cause
was not addressed. Missing Context → Reasoning or Solution Error → Success
suggests one blocker was removed before another was exposed. Aggregate
cause-to-outcome transitions and intervention outcomes when sample size permits;
association alone does not demonstrate causal effectiveness.

Keep cost units explicit: executions, input/output/cached tokens, monetary
model/tool cost, parent intervention, and human intervention. Missing values are
unknown, not zero. Distinguish measured from estimated costs and disclose coverage
and allocation assumptions; never allocate whole-session usage to a task without
support. Separate summed attempt duration from end-to-end wall-clock latency,
waiting, and overlapping work. Avoid double-counting shared costs.

Prioritize by **Failure Impact = Failure Frequency × Average Recovery Cost**,
stating units and how recovery costs were attributed. Show unresolved costs and
incomplete follow-up separately so successful recoveries do not hide costly
abandonment. Compare models, tools, complexity, and routing only where evidence
supports comparable groups; report sample sizes and confounders.

Further retries depend on task value, marginal recovery, expected cost, latency,
failure severity, and a meaningful next intervention. Low first-shot success can
coexist with cheap recovery; high completion can conceal expensive retries.
Low retry coverage differs from ineffective retries. Repeated unchanged failures
suggest a weak retry strategy. Unresolved is not synonymous with exhausted.

## Deliver the analysis

1. Identify tasks and segment attempts with evidence for boundary decisions.
2. Score outcomes, classify failures, and record retry interventions.
3. Compute metrics from the normalized table and validate the count invariants.
4. Interpret the full task recovery curve, transitions, and available cost data.
5. Recommend specific interventions tied to evidenced causes and their impact.

The minimum report contains the scope and evidence limitations, normalized
attempt table, total scorable and unscorable/excluded tasks, A_n/S_n/F_n by attempt,
1st-Shot Success, Retry Coverage, Recovery Rate, End-to-End Recovery, Cumulative
Success, Marginal Shot Value, Retry Efficiency, Unresolved Rate at cutoff, and
Average Attempts to Success. Include failure causes, transitions, interventions,
and cost/latency where known; explicitly mark unavailable measures. Include
Persistent Failure Rate only under its exhaustion rule. Use tables and, when
helpful, a recovery curve visualization; do not invent data to fill a report.
