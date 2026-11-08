#!/usr/bin/env bash
# Package the device runtime archive the Amphora SDK installs
# (element runtime.bst).
#
# Input: the Wine install tree (wine/wine.bst, staged at $WINE_ROOT) and the
# target FreeType (libs/freetype.bst, staged at $TARGET_SYSROOT).
# Output in $OUTPUT_DIR:
#   amphora-wine-<version>-<commit12>.tar.gz   ustar, sorted, fixed mtime/owner
#   amphora-wine-<version>-<commit12>.tar.gz.sha256
#   runtime.env                                 name/sha256/size for CI and manifests
#
# Archive layout (paths relative to the runtime root on the device):
#   amphora-runtime.json          what this is, for the SDK installer
#   bin/wineserver
#   lib/libfreetype.so            on LD_LIBRARY_PATH
#   lib/wine/aarch64-unix/        wine (loader), ntdll.so, ... (no preloader)
#   lib/wine/aarch64-windows/     ARM64X PE files
#   lib/wine/i386-windows/        32-bit PE files (WoW64)
#   share/wine/                   nls, fonts, wine.inf
# Executables need no exec bit on the device: the SDK and Wine start them
# through /system/bin/linker64.
set -euo pipefail

: "${WINE_ROOT:?}" "${TARGET_SYSROOT:?}" "${OUTPUT_DIR:?}" "${ANDROID_NDK_HOME:?}" "${LLVM_MINGW_ROOT:?}"
: "${WINE_COMMIT:?}" "${WINE_UPSTREAM_TAG:?}"

NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
STAGE=/tmp/amphora-runtime

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"
cp -a "$WINE_ROOT/bin/wineserver" "$STAGE/bin/"
cp -a "$WINE_ROOT/lib/wine" "$STAGE/lib/"
cp -a "$WINE_ROOT/share/wine" "$STAGE/share/"
cp -L "$TARGET_SYSROOT/usr/lib/libfreetype.so" "$STAGE/lib/libfreetype.so"

# Development-only files: import libraries for winegcc and Wine's own symlinks.
find "$STAGE/lib/wine" -name '*.a' -delete
find "$STAGE" -type l -delete

# Strip everything; the unstripped tree stays in the wine/wine.bst artifact.
find "$STAGE" -type f -print0 | while IFS= read -r -d '' f; do
  case "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" in
    7f454c46) "$NDK_BIN/llvm-strip" --strip-unneeded "$f" ;;      # ELF
    4d5a*)  # MZ: PE images only; .fon files are NE and must stay untouched
      pe_off="$(od -An -tu4 -j60 -N4 "$f" | tr -d ' ')"
      if [ "$(od -An -tx1 -j"$pe_off" -N4 "$f" 2>/dev/null | tr -d ' \n')" = 50450000 ]; then
        "$LLVM_MINGW_ROOT/bin/llvm-strip" --strip-unneeded "$f"
      fi ;;
  esac
done

# 16 KB page devices: every ELF we ship needs 16 KB LOAD alignment (wine.sh
# checks Wine's own; this covers the libraries next to it).
find "$STAGE" -type f -print0 | while IFS= read -r -d '' f; do
  "$NDK_BIN/llvm-readelf" -h "$f" >/dev/null 2>&1 || continue
  if "$NDK_BIN/llvm-readelf" -lW "$f" | awk '$1 == "LOAD" { print $NF }' | grep -qv '^0x4000$'; then
    echo "${f#"$STAGE"/}: LOAD segments are not 16 KB aligned" >&2
    exit 1
  fi
done

# Wine's soname for FreeType must be what we ship.
want_soname="$("$NDK_BIN/llvm-readelf" -dW "$STAGE/lib/libfreetype.so" |
  sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
if [ "$want_soname" != libfreetype.so ]; then
  echo "unexpected FreeType soname '$want_soname'" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$WINE_ROOT/amphora-wine.env"
version="${WINE_VERSION:?amphora-wine.env has no WINE_VERSION}"
commit12="$(printf '%s' "$WINE_COMMIT" | cut -c1-12)"
name="amphora-wine-${version}-${commit12}"

files="$(find "$STAGE" -type f | wc -l)"
bytes="$(find "$STAGE" -type f -printf '%s\n' | awk '{ s += $1 } END { print s }')"
cat > "$STAGE/amphora-runtime.json" <<JSON
{
  "format": 1,
  "name": "$name",
  "abi": "arm64-v8a",
  "minSdk": 30,
  "wine": {
    "version": "$version",
    "commit": "$WINE_COMMIT",
    "upstreamTag": "$WINE_UPSTREAM_TAG",
    "archs": ["aarch64", "arm64ec", "i386"]
  },
  "loader": "lib/wine/aarch64-unix/wine",
  "server": "bin/wineserver",
  "libraryPath": ["lib"],
  "files": $files,
  "bytes": $bytes
}
JSON
python3 -m json.tool "$STAGE/amphora-runtime.json" >/dev/null

mkdir -p "$OUTPUT_DIR"
archive="$OUTPUT_DIR/$name.tar.gz"
( cd "$STAGE" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort ) > /tmp/amphora-runtime.list
tar --format=ustar --no-recursion --numeric-owner --owner=0 --group=0 \
    --mode='u+rwX,go+rX,go-w' --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE" -T /tmp/amphora-runtime.list -cf - |
  gzip -n -9 > "$archive"
( cd "$OUTPUT_DIR" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )
sha="$(cut -d' ' -f1 "$archive.sha256")"
size="$(stat -c%s "$archive")"
cat > "$OUTPUT_DIR/runtime.env" <<ENV
RUNTIME_NAME=$name
RUNTIME_ARCHIVE=$name.tar.gz
RUNTIME_SHA256=$sha
RUNTIME_SIZE=$size
RUNTIME_FILES=$files
RUNTIME_BYTES=$bytes
WINE_VERSION=$version
WINE_COMMIT=$WINE_COMMIT
ENV
echo "runtime: $archive ($size bytes, $files files, $bytes bytes unpacked, sha256 $sha)"
