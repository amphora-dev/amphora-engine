#!/usr/bin/env bash
# Fast Wine edit-compile loop for development, outside `bst build`.
#
# `bst build wine/wine.bst` is what CI and releases use. For each run it imports
# the source tree into CAS, restores the previous build tree, runs `make` and
# `make install` over the whole tree, and commits the result back to CAS. That
# is minutes even when one .c file changed. This script keeps the same inputs
# (the element's sandbox: SDK, NDK, llvm-mingw, staged libraries, scripts/wine.sh)
# but keeps the source copy and build tree on local disk between runs. recc
# uses the same local action cache as `bst build`, and the tree is laid out the
# same way (build tree at <source>/_amphora), so the first build here reuses
# compile results from the last `bst build` and the other way round:
#
#   dev/wine.sh build      sync $WINE_SRC into the copy, then scripts/wine.sh build
#   dev/wine.sh changed    built files newer than the last `mark`, as runtime paths
#   dev/wine.sh mark       remember "now" for `changed`
#
# Not a release path: nothing here is cached or reproducible. Anything that
# leaves this machine is built with `./bst build runtime.bst`.
#
# Environment:
#   WINE_SRC          Wine checkout to build (default: ../wine-arm64ec next to this repo)
#   AMPHORA_DEV_DIR   state directory on a local Linux filesystem
#                     (default: ~/.cache/amphora-dev/wine)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SRC="${WINE_SRC:-$(cd "$ROOT/.." && pwd)/wine-arm64ec}"
STATE="${AMPHORA_DEV_DIR:-$HOME/.cache/amphora-dev/wine}"
SRC="$STATE/src"
BUILD="$STATE/build"
# Files the build writes into its source copy (autoreconf, make_requests,
# make_specfiles, make_vulkan). Syncing must neither revert nor delete them,
# or every incremental build would regenerate them and rebuild most of Wine.
GENERATED="$STATE/generated.list"

sync_src() {
  test -f "$WINE_SRC/configure.ac" || { echo "WINE_SRC=$WINE_SRC is not a Wine tree" >&2; exit 1; }
  mkdir -p "$SRC" "$BUILD"
  touch "$GENERATED"
  rsync -a --delete --exclude=/.git --exclude=/_amphora --exclude-from="$GENERATED" "$WINE_SRC/" "$SRC/"
}

# After a build, whatever differs between the checkout and the copy (outside
# the known list) was written by the build: remember it.
record_generated() {
  rsync -a --delete --dry-run --itemize-changes --exclude=/.git --exclude=/_amphora --exclude-from="$GENERATED" \
      "$WINE_SRC/" "$SRC/" |
    sed -n -e 's#^\*deleting \(.*[^/]\)$#/\1#p' -e 's#^>f[^ ]* \(.*\)$#/\1#p' >> "$GENERATED"
  sort -u -o "$GENERATED" "$GENERATED"
}

build() {
  sync_src
  local start=$SECONDS
  # The element's own build sandbox; scripts/ is mounted from this checkout so an
  # edited scripts/wine.sh is used without rebuilding wine/script.bst. Its build
  # dependencies must be cached (any earlier `./bst build runtime.bst`).
  # The build tree goes where `bst build` has it (wine.sh's default
  # $SRC/_amphora): action keys hold paths relative to the source tree.
  # RECC_USE_LOCALCAS is off because it has casd read input files by path, and
  # casd cannot see into these mounts; recc then sends the files itself.
  "$ROOT/bst" shell --build wine/wine.bst \
    --mount "$SRC" /src --mount "$BUILD" /src/_amphora --mount "$ROOT/scripts" /dev-scripts \
    -- bash -c 'unset RECC_USE_LOCALCAS && cd /src && bash /dev-scripts/wine.sh build'
  record_generated
  echo "dev/wine.sh: built in $((SECONDS - start)) s ($(wc -l < "$GENERATED") generated files kept)"
}

# Map build-tree outputs to their place in the runtime archive (scripts/runtime.sh):
#   <dir>/<name>.so                    -> lib/wine/aarch64-unix/<name>.so
#   <dir>/aarch64-windows/<file>       -> lib/wine/aarch64-windows/<file>
#   <dir>/i386-windows/<file>          -> lib/wine/i386-windows/<file>
#   loader/wine, server/wineserver     -> lib/wine/aarch64-unix/wine, bin/wineserver
changed() {
  local stamp="$STATE/mark"
  test -f "$stamp" || { echo "no mark yet; run: dev/wine.sh mark" >&2; exit 1; }
  ( cd "$BUILD/wine" &&
    find dlls programs loader server -type f -newer "$stamp" \
      \( -name '*.so' -o -path '*-windows/*' -o -path loader/wine -o -path server/wineserver \) \
      ! -name '*.o' ! -name '*.a' ! -name '*.spec.*' ! -name '*.fake' 2>/dev/null ) |
    sed -e 's#^server/wineserver$#bin/wineserver#' \
        -e 's#^loader/wine$#lib/wine/aarch64-unix/wine#' \
        -e 's#^.*/\(aarch64-windows\|i386-windows\)/\([^/]*\)$#lib/wine/\1/\2#' \
        -e 's#^\(dlls\|programs\)/.*/\([^/]*\.so\)$#lib/wine/aarch64-unix/\2#' |
    grep '^\(bin\|lib\)/' | sort -u
}

case "${1:-}" in
  build) build ;;
  changed) changed ;;
  mark) mkdir -p "$STATE" && touch "$STATE/mark" ;;
  *) echo "usage: $0 build|changed|mark" >&2; exit 2 ;;
esac
