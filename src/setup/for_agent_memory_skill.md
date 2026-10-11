

- Apply entries to reduce effort and prevent repeated mistakes; reading alone is insufficient.
- Retain evidenced failure prevention, efficiency methods, stable repository knowledge, user instructions, and guidance. Write failures as prevention rules.
- Never store secrets, credentials, tokens, keys, private personal data, guesses, or transient status; without evidence, store nothing
- Do not run a memory-reflection round after every turn; write insights before a commit or compaction summary, at completion without a commit, or after a strong finding at risk of context loss.
- Before every commit or task completion, keep at most 64 `[[entries]]`; preserve active user instructions and indispensable contract rules, then merge or delete least important entries.
- Consider existing knowledge first. Keep the smallest useful set, not a fixed count.
- Keep this TOML contract:
  - Use `version = 1` and zero or more `[[entries]]` records.
- Records have exactly `date`, `category`, `insight`, and non-negative integer `usefulness`; `usefulness` starts at `0` for new entries. `Subagent Insight` also has `subagent_type`. Dates are quoted ISO 8601 `YYYY-MM-DD`.
  - `category` is one of `User Instruction`, `Repository`, `Data Discovery`, `Tooling`, `Verification`, `Agent Collaboration`, `Workflow`, `Subagent Insight`, or `Other`; use `Other` only if none fits.
- `subagent_type` is the exact native role, exclusive to `Subagent Insight`; `insight` is actionable, at most three sentences and 32 words.
- Evaluate proposals for evidence and utility; Root may shorten; stores accepted subagent insights separately.
- When merging insights, set merged `usefulness` to their arithmetic mean, rounded to the nearest non-negative integer (half up); do not otherwise increase it.
- At the final memory checkpoint before committing, or at task completion when no commit is made, Root increases an insight's `usefulness` exactly once by `+1` when useful or error-preventing; Multiple uses in one session count once; unused entries remain unchanged.
- Commit updates with task changes unless `.basix` is ignored. Before compaction, commit eligible updates after verification. Never override ignore rules.
- Keep the memory in english if the user does not state another language. If it already exists keep it in the language it is.