#!/usr/bin/env bash
# Import the build cache of a CI run into the local BuildStream cache: element
# artifacts at that run's keys and its stored ccache directory (which replaces
# this machine's). CI uploads it only on request:
#
#   gh workflow run build.yml -f upload-cache=true     # or "[upload-cache]" in a commit message
#   bash ci/cache/pull-ci.sh [RUN_ID]                  # default: newest run that has it
#
# Needs gh (logged in) and zstd; with aria2c and unzip it downloads over 16
# connections (several times faster than gh's single stream). Safe to repeat;
# files already present are kept.
# From the Mac: GH_TOKEN=$(gh auth token) orb -m bst-amd64 bash ci/cache/pull-ci.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${AMPHORA_ENGINE_REPO:-amphora-dev/amphora-engine}"

run="${1:-}"
if [ -z "$run" ]; then
  run="$(gh api "repos/$repo/actions/artifacts?name=bst-cache&per_page=20" \
    --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .workflow_run.id // empty')"
  [ -n "$run" ] || { echo "no bst-cache artifact; run: gh workflow run build.yml -R $repo -f upload-cache=true" >&2; exit 1; }
fi

tmp="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/amphora-pull.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
echo "pull-ci: run $run" >&2
mkdir "$tmp/snapshot"
if command -v aria2c >/dev/null && command -v unzip >/dev/null; then
  id="$(gh api "repos/$repo/actions/runs/$run/artifacts" --jq '.artifacts[] | select(.name == "bst-cache") | .id')"
  [ -n "$id" ] || { echo "run $run has no bst-cache artifact" >&2; exit 1; }
  # The API answers with a short-lived signed blob URL that serves byte ranges.
  url="$(curl -fsS -o /dev/null -w '%{redirect_url}' \
    -H "Authorization: Bearer ${GH_TOKEN:-$(gh auth token)}" \
    "https://api.github.com/repos/$repo/actions/artifacts/$id/zip")"
  aria2c -q -x16 -s16 -k4M --file-allocation=none -d "$tmp" -o bst-cache.zip "$url"
  unzip -p "$tmp/bst-cache.zip" bst-cache.tar.zst | zstd -dc | tar -C "$tmp/snapshot" -xf -
else
  gh run download "$run" -R "$repo" -n bst-cache -D "$tmp"
  zstd -dc "$tmp/bst-cache.tar.zst" | tar -C "$tmp/snapshot" -xf -
fi
bash "$here/snapshot.sh" import "$tmp/snapshot"

ci_key="$(cat "$tmp/snapshot/KEY")"
local_key="bst-v3-$("$here/../../bst" --no-colors show --deps none --format '%{full-key}' runtime.bst 2>/dev/null)"
if [ "$ci_key" = "$local_key" ]; then
  echo "pull-ci: same inputs as this checkout; runtime.bst is cached" >&2
else
  echo "pull-ci: CI built other inputs ($ci_key); Wine compiles that did not change will hit ccache" >&2
fi
