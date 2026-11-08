# ADR 0020: Project developer instructions

Status: Active

Context: Basix rules belong to the project.

Decision: Install full rules only as `.basix/developer_instructions.md`. Both installers put the mandatory user-worded reference in Codex `developer_instructions`. The router reads the project file at session start and after compaction.

Consequences: Project installation owns the Markdown file; global plugin installation only adds the reference. No migration or compatibility path exists.
