#!/usr/bin/env bash
# Point BuildStream at the shared remote cache: CAS, element artifacts,
# source cache and the action cache behind remote-apis-socket (recc).
# Without a token this is a no-op and builds use the local cache only.
#
# The default host is the origin A record, not the Cloudflare-proxied name.
# Orange-cloud stalls buildbox's long gRPC streams (ByteStream and Remote
# Asset): the client sits in "Pushing artifact" while the origin receives
# no bytes. Short requests through Cloudflare can still look fast.
set -euo pipefail

url="${BST_REMOTE_CACHE_URL:-https://cas.arm.512.pub}"
token="${BST_REMOTE_CACHE_TOKEN:-}"
action_cache_mode="${BST_ACTION_CACHE_MODE:-remote}"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
conf="$conf_dir/buildstream.conf"
token_file="$conf_dir/bst-remote-cache.token"

case "$action_cache_mode" in
    local|remote) ;;
    *)
        echo "BST_ACTION_CACHE_MODE must be 'local' or 'remote': $action_cache_mode" >&2
        exit 1
        ;;
esac

if [ -z "$token" ] && [ -s "$token_file" ]; then
    token="$(cat "$token_file")"
fi
if [ -z "$token" ]; then
    if [ "${BST_REMOTE_CACHE_REQUIRED:-false}" = true ]; then
        echo "BST_REMOTE_CACHE_TOKEN is required but empty" >&2
        exit 1
    fi
    echo "BST_REMOTE_CACHE_TOKEN not set; using the local BuildStream cache only" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::BST_REMOTE_CACHE_TOKEN is not set; building without the shared remote cache"
    fi
    exit 0
fi

mkdir -p "$conf_dir"
(umask 077 && printf '%s\n' "$token" > "$token_file")

# Per-RPC ceiling. A stalled stream fails here instead of holding the job
# until the workflow timeout. keepalive lets casd notice a dead connection.
#
# Element artifacts and sources always use the shared server. The action
# cache behind remote-apis-socket (recc) depends on the mode:
#   remote  casd proxies recc's action cache and CAS to the server. For a
#           machine without a local copy (runner without a snapshot, new
#           dev machine). BuildStream 2.7 then checks every hit over the WAN.
#   local   casd serves recc from the local cache only; hits never leave the
#           machine. For a restored GitHub snapshot or a dev machine's own
#           cache. `ci/cache/recc-cache.py push` writes new entries back.
#
# Only these keys are touched; mirrors, scheduler and other settings in an
# existing buildstream.conf are kept.
python="${BST_TOOLS_ROOT:-$HOME/.cache/amphora-buildstream/tools}/venv/bin/python"
"$python" -I - "$conf" "$url" "$token_file" "$action_cache_mode" << 'PY'
import sys
from pathlib import Path

from ruamel.yaml import YAML

conf, url, token, mode = sys.argv[1:]
yaml = YAML()
path = Path(conf)
data = (yaml.load(path) if path.exists() else None) or {}


def server(push=True):
    s = {"url": url}
    if push:
        s["push"] = True
    s["auth"] = {"access-token": token}
    s["connection-config"] = {"request-timeout": 900, "keepalive-time": 30}
    return s


data["artifacts"] = {"servers": [server()]}
data["source-caches"] = {"servers": [server()]}
cache = data.get("cache") or {}
if mode == "remote":
    cache["storage-service"] = server(push=False)
    data["remote-execution"] = {"action-cache-service": server()}
else:
    cache.pop("storage-service", None)
    data.pop("remote-execution", None)
if cache:
    data["cache"] = cache
else:
    data.pop("cache", None)
yaml.dump(data, path)
PY

echo "BuildStream remote cache: $url (action-cache=$action_cache_mode) -> $conf"
