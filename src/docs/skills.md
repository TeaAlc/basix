# Skills

The `basix` meta-skill documents how to maintain this collection. It intentionally contains no scraping, mirroring, or other domain workflow.

The `basix-agent-authoring` skill plans, creates, and updates native agent TOMLs. It classifies work as low, medium, or high complexity, applies the corresponding Luna reasoning default, inserts the managed communication contract, and validates both agent files and JSON message streams.

Add each future workflow under `skills/<name>/SKILL.md` with a specific trigger description. Put its scripts, references, and assets in that skill directory. Put only launchers shared by multiple skills or agents under top-level `scripts/`.
