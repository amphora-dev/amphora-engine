#!/usr/bin/env bash
# ci/cache/snapshot.py with the BuildStream venv's python (REAPI and BuildStream protos).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "${BST_TOOLS_ROOT:-$HOME/.cache/amphora-buildstream/tools}/venv/bin/python" -I "$here/snapshot.py" "$@"
