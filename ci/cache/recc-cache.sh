#!/usr/bin/env bash
# ci/cache/recc-cache.py with the BuildStream venv's python (grpc, REAPI protos).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "${BST_TOOLS_ROOT:-$HOME/.cache/amphora-buildstream/tools}/venv/bin/python" -I "$here/recc-cache.py" "$@"
