#!/usr/bin/env bash
set -euo pipefail
"$(dirname "${BASH_SOURCE[0]}")/test-codex-plugin-compatibility.sh"
"$(dirname "${BASH_SOURCE[0]}")/test-codex-discovery.sh"
