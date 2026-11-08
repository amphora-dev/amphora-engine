#!/usr/bin/env bash
# Install pinned BuildStream on the host. BuildBox (casd, fuse, run) comes
# bundled in the BuildStream wheel (2.8.1: buildbox 1.4.25), so the three
# always match. ccache runs inside the sandbox and comes from elements/tools/ccache.bst.
set -euo pipefail

BST_VERSION="${BST_VERSION:-2.8.1}"
BST_CORE_PLUGINS_VERSION="${BST_CORE_PLUGINS_VERSION:-2.8.0}"
# The buildstream-sdk junction uses its zip source (the NDK). 2.5.0 changes what
# zip stages (keeps unix permissions and symlinks) without changing the source's
# cache key; take it together with a buildstream-sdk change that rekeys the NDK.
BST_PLUGINS_VERSION="${BST_PLUGINS_VERSION:-2.4.0}"
TOOLS_ROOT="${BST_TOOLS_ROOT:-$HOME/.cache/amphora-buildstream/tools}"
VENV="$TOOLS_ROOT/venv"
BIN="$TOOLS_ROOT/bin"

mkdir -p "$TOOLS_ROOT"

plugin_versions="$("$VENV/bin/python" -c \
    'from importlib.metadata import version; print(version("buildstream-plugins"), version("buildstream-plugins-community"))' \
    2>/dev/null || true)"
if [ ! -x "$VENV/bin/bst" ] ||
   [ "$("$VENV/bin/bst" --version 2>/dev/null || true)" != "$BST_VERSION" ] ||
   [ "$plugin_versions" != "$BST_CORE_PLUGINS_VERSION $BST_PLUGINS_VERSION" ]; then
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --disable-pip-version-check --quiet --upgrade pip
    "$VENV/bin/pip" install --disable-pip-version-check --quiet \
        "BuildStream==$BST_VERSION" \
        "buildstream-plugins==$BST_CORE_PLUGINS_VERSION" \
        "buildstream-plugins-community==$BST_PLUGINS_VERSION"
fi

# Earlier versions of this script put a separate BuildBox here; anything in
# $BIN comes first in PATH and would shadow the bundled one.
rm -rf "$BIN"

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$VENV/bin" >> "$GITHUB_PATH"
fi

printf 'BuildStream %s installed in %s\n' "$BST_VERSION" "$TOOLS_ROOT"
printf 'export PATH=%q:$PATH\n' "$VENV/bin"
