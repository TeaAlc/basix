# ADR 0005: Relative installer state

Status: Active

Context: Absolute state targets break when an install root moves.

Decision: Store `copy`, `dircopy`, and `dirfile` targets relative to each install root. Project installs may safely rebase legacy absolute records for known Basix trees.

Consequences: State survives project or CODEX_HOME moves; readers must resolve relative and legacy absolute records while preserving fail-closed checks.
