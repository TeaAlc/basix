#!/usr/bin/env python3
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
expected_name, effort, sandbox = sys.argv[2:5]
agent = tomllib.loads(path.read_text(encoding="utf-8"))
assert agent["name"] == expected_name
assert agent["model"] == "gpt-6-luna"
assert agent["model_reasoning_effort"] == effort
assert agent["sandbox_mode"] == sandbox
assert agent["description"].startswith("Basix-Agent: ")
instructions = agent["developer_instructions"]
assert "basix-agent-authoring:bootstrap:start" in instructions
assert "basix-agent-authoring:bootstrap:end" in instructions
assert "Read the complete available `basix` router skill." in instructions
print(f"ok - {expected_name} definition")
