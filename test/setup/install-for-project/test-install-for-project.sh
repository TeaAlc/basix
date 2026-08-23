#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bash -n "$ROOT/src/setup/install_for_project.sh"
"$(dirname "${BASH_SOURCE[0]}")/test-install-copy.sh"
"$(dirname "${BASH_SOURCE[0]}")/test-playwright-sandbox.sh"
