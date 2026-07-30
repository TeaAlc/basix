# Agents

The native read-only agents are:

- `basix_researcher` uses `gpt-5.6-luna` with medium reasoning for general research. For
  web research and scraping it expects and may use the read-only Scrapling MCP tools. It checks
  the complete tool inventory, including deferred tools, and reports itself blocked when a task
  requires Scrapling but no Scrapling tool is available.
- `basix_file_explorer` uses `gpt-5.6-luna` with low reasoning for exhaustive local file
  discovery. It inventories all supported file types, verifies evidence with `rg` and targeted
  reads, and forbids Lumen, other MCP search tools, and web search.

Both managed communication blocks implement the versioned JSON handoff contract. Global setup
binds every `agents/native/*.toml` file to `$CODEX_HOME/agents/`; project setup binds all of them
to `.codex/agents/`.

For isolated explorer benchmarks, run:

```bash
./scripts/run-file-explorer-benchmark.sh --prompt "Find the relevant files" \
  --workdir /path/to/project --output result.txt --trace trace.jsonl
```

This runner extracts only the marked search instructions from the native TOML, ignores user
configuration and rules, disables web search, retains a read-only sandbox, and can save the JSONL
event trace for tool-policy audits.
