---
name: basix-adr
description: "Basix-Skill: Use before planning or implementation to check binding ADRs, and when creating, editing, superseding, merging, or archiving architecture decisions."
---

# Basix ADRs

Read the complete `basix` router first. For managed assignments, its mandatory
management boundary applies. If no active ADR index exists, do not create ADR
storage merely for this check; create it only when the first ADR is required.

- Before planning or implementation, read the active index `.basix/adrs/ADR.md`, then load only the active ADRs relevant to the work. Active ADRs are binding.
- Create an ADR only for a durable decision that is difficult to reverse, crosses subsystem boundaries, or creates a long-term architecture, security, data, or workflow commitment.
- Store ADRs as `.basix/adrs/ADR_NNNN_<descriptive-name>.md`. Use a descriptive English kebab-case name. Allocate one globally increasing number across active and archived ADRs, zero-padded to at least four digits, and never reuse a number.
- Every ADR must contain `Status`, `Context`, `Decision`, and `Consequences`. The entire file, including Markdown and whitespace, must not exceed 512 Unicode characters.
- `.basix/adrs/ADR.md` lists only active ADRs; each entry links to one ADR and has a description of at most 64 Unicode characters. `.basix/adrs/archive/ADR.md` lists only archived ADRs; each entry links to one ADR, states its status or successor, and has a description of at most 64 Unicode characters. The two index files are exempt from the 512-character limit.
- Editorial corrections may update an existing ADR. A new or changed decision requires a new ADR.
- Superseding, merging, or archiving without replacement requires prior user confirmation. A successor must name the ADR it supersedes. For a merge, allocate the next number to the new ADR, name every merged ADR, make only the new ADR binding, and move all source ADRs to the archive. Only the mandatory `Merged ADRs: ...` line in a merge ADR is exempt from the 512-character limit.
- Give every archived ADR an appropriate status and update both indexes atomically with the lifecycle change.
- If planned work conflicts with an active ADR, pause the affected implementation. A subagent reports an `issue` or `permission_request` exclusively to its direct parent under Contract 2.0; each parent independently evaluates and, when needed, newly authors an escalation to its own parent until `/root`, never skipping a level. Only `/root` presents the user-facing notice and requests confirmation: render the entire notice in red as `<div style="color:red">…</div>`. State the binding decision, planned deviation, exact conflict, and impact so the user need not read the ADR. Offer exactly three concrete options: comply with the ADR, replace it with a user-confirmed successor, or replan the scope to avoid the conflict. Resume conflicting implementation only after explicit user confirmation is conveyed through the parent chain.
- Agents create `.basix/adrs/` and its indexes when the first ADR is required. Basix installers must not create the directory, templates, or an initial ADR.
