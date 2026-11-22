#!/usr/bin/env bash
# Package the device runtime archive the Amphora SDK installs
# (element runtime.bst).
#
# Input: the Wine install tree (wine/wine.bst, staged at $WINE_ROOT), FEX's
# Wine modules (fex/fex.bst, at $FEX_ROOT), DXVK (dxvk/dxvk.bst, at
# $DXVK_ROOT), vkd3d-proton (vkd3d-proton/vkd3d-proton.bst, at $VKD3D_ROOT),
# Turnip (mesa/turnip.bst, at $TURNIP_ROOT) and the target FreeType
# (libs/freetype.bst, staged at $TARGET_SYSROOT).
# Output in $OUTPUT_DIR:
#   <name>.tar.gz          ustar, sorted, fixed mtime/owner; <name> is
#                          amphora-wine-<version>-<commit12>-fex-<fex commit7>-gfx-<graphics8>,
#                          where <graphics8> identifies the DXVK, vkd3d-proton
#                          and Mesa versions together
#   <name>.tar.gz.sha256
#   runtime.env                                 name/sha256/size for CI and manifests
#
# Archive layout (paths relative to the runtime root on the device):
#   amphora-runtime.json          what this is, for the SDK installer
#   bin/wineserver
#   lib/libfreetype.so            on LD_LIBRARY_PATH
#   lib/libvulkan_freedreno.so    Turnip, the Vulkan driver (an Android HAL
#                                 module, opened by Wine's display driver)
#   lib/wine/aarch64-unix/        wine (loader), ntdll.so, ... (no preloader),
#                                 libarm64ecfex.so, libwow64fex.so
#   lib/wine/aarch64-windows/     ARM64X PE files, libarm64ecfex.dll (x86_64),
#                                 libwow64fex.dll (32-bit x86)
#   lib/wine/i386-windows/        32-bit PE files (WoW64)
#   lib/wine/dxvk/                DXVK, laid out as in Proton: aarch64-windows
#                                 (ARM64EC) and i386-windows; the SDK links
#                                 them into prefixes
#   lib/wine/vkd3d-proton/        vkd3d-proton, likewise
#   share/wine/                   nls, fonts, wine.inf
#   share/fex-emu/Config.json     FEX defaults (FEX_APP_CONFIG_LOCATION)
# Executables need no exec bit on the device: the SDK and Wine start them
# through /system/bin/linker64.
set -euo pipefail

: "${WINE_ROOT:?}" "${FEX_ROOT:?}" "${DXVK_ROOT:?}" "${VKD3D_ROOT:?}" "${TURNIP_ROOT:?}" "${TARGET_SYSROOT:?}" "${OUTPUT_DIR:?}" "${ANDROID_NDK_HOME:?}" "${LLVM_MINGW_ROOT:?}"
: "${WINE_COMMIT:?}" "${WINE_UPSTREAM_TAG:?}" "${TARGET_TRIPLE:?}"
# Everything in the archive is built for this API level, so it is the floor.
min_sdk="${TARGET_TRIPLE##*android}"

NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
STAGE=/tmp/amphora-runtime

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"
cp -a "$WINE_ROOT/bin/wineserver" "$STAGE/bin/"
cp -a "$WINE_ROOT/lib/wine" "$STAGE/lib/"
cp -a "$WINE_ROOT/share/wine" "$STAGE/share/"
cp -L "$TARGET_SYSROOT/usr/lib/libfreetype.so" "$STAGE/lib/libfreetype.so"
for f in lib/wine/aarch64-windows/libarm64ecfex.dll lib/wine/aarch64-windows/libwow64fex.dll \
         lib/wine/aarch64-unix/libarm64ecfex.so lib/wine/aarch64-unix/libwow64fex.so; do
  cp "$FEX_ROOT/$f" "$STAGE/$f"
done
cp -a "$DXVK_ROOT/lib/wine/dxvk" "$VKD3D_ROOT/lib/wine/vkd3d-proton" "$STAGE/lib/wine/"
cp "$TURNIP_ROOT/lib/libvulkan_freedreno.so" "$STAGE/lib/libvulkan_freedreno.so"
# Proton's FEX_Config.json at the tag the Wine follows: FEX's global defaults.
# The SDK points FEX_APP_CONFIG_LOCATION here; per-game values go in FEX_APP_CONFIG.
mkdir -p "$STAGE/share/fex-emu"
cat > "$STAGE/share/fex-emu/Config.json" <<'JSON'
{
    "Config": {
        "ProfileStats": "1",
        "X87ReducedPrecision": "1",
        "TSOEnabled": "1",
        "VectorTSOEnabled": "0",
        "MemcpySetTSOEnabled": "0",
        "HalfBarrierTSOEnabled":"1",
        "MaxInst": "500",
        "Multiblock": "1"
    }
}
JSON

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

# Files that lost their content: a local build once staged 481 i386 DLLs as
# runs of zeros of the right size, and the strip loop above skips whatever is
# neither ELF nor MZ. Nothing we ship is all zeros, and everything Wine, FEX,
# DXVK and vkd3d-proton install into the PE directories starts with MZ,
# data-only modules such as .tlb included (fonts, NLS and other data go under
# share/). A file that is meant to be there without being PE needs an
# exception in the case below.
bad=/tmp/amphora-runtime.bad
find "$STAGE" -type f -print0 | while IFS= read -r -d '' f; do
  rel="${f#"$STAGE"/}"
  size="$(stat -c%s "$f")"
  if [ "$size" -gt 0 ] && cmp -s -n "$size" "$f" /dev/zero; then
    echo "$rel: all zero bytes"
    continue
  fi
  case "$rel" in
    lib/wine/*-windows/*)   # the * also match the / of lib/wine/dxvk/i386-windows
      if [ "$(head -c 2 "$f" | od -An -tx1 | tr -d ' \n')" != 4d5a ]; then
        echo "$rel: no MZ header (not a PE file)"
      fi ;;
  esac
done > "$bad"
if [ -s "$bad" ]; then
  echo "corrupt files in the runtime: $(wc -l < "$bad"), the first 20:" >&2
  head -n 20 "$bad" >&2
  exit 1
fi
rm -f "$bad"

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
# shellcheck source=/dev/null
. "$FEX_ROOT/amphora-fex.env"
: "${FEX_VERSION:?amphora-fex.env has no FEX_VERSION}" "${FEX_COMMIT:?amphora-fex.env has no FEX_COMMIT}"
# shellcheck source=/dev/null
. "$DXVK_ROOT/amphora-dxvk.env"
: "${DXVK_VERSION:?amphora-dxvk.env has no DXVK_VERSION}" "${DXVK_COMMIT:?amphora-dxvk.env has no DXVK_COMMIT}"
# shellcheck source=/dev/null
. "$VKD3D_ROOT/amphora-vkd3d-proton.env"
: "${VKD3D_VERSION:?amphora-vkd3d-proton.env has no VKD3D_VERSION}" "${VKD3D_COMMIT:?amphora-vkd3d-proton.env has no VKD3D_COMMIT}"
# shellcheck source=/dev/null
. "$TURNIP_ROOT/amphora-turnip.env"
: "${MESA_VERSION:?amphora-turnip.env has no MESA_VERSION}" "${MESA_PATCHES:?amphora-turnip.env has no MESA_PATCHES}"
# A release is named after its archive and recipes pin it by name and hash, so
# the name must change with anything that changes the content.
graphics="$(printf 'dxvk=%s\nvkd3d-proton=%s\nmesa=%s+%s\n' "$DXVK_COMMIT" "$VKD3D_COMMIT" "$MESA_VERSION" "$MESA_PATCHES" |
  sha256sum | cut -c1-8)"
name="amphora-wine-${version}-${commit12}-fex-$(printf '%s' "$FEX_COMMIT" | cut -c1-7)-gfx-${graphics}"

# The DLLs of a Direct3D implementation as a JSON list of names.
dll_names() {
  find "$1/aarch64-windows" -name '*.dll' -printf '%f\n' | LC_ALL=C sort |
    sed 's/\.dll$//; s/.*/"&"/' | paste -sd, - | sed 's/,/, /g'
}

files="$(find "$STAGE" -type f | wc -l)"
bytes="$(find "$STAGE" -type f -printf '%s\n' | awk '{ s += $1 } END { print s }')"
cat > "$STAGE/amphora-runtime.json" <<JSON
{
  "format": 1,
  "name": "$name",
  "abi": "arm64-v8a",
  "minSdk": $min_sdk,
  "wine": {
    "version": "$version",
    "commit": "$WINE_COMMIT",
    "upstreamTag": "$WINE_UPSTREAM_TAG",
    "archs": ["aarch64", "arm64ec", "i386"]
  },
  "fex": {
    "version": "$FEX_VERSION",
    "commit": "$FEX_COMMIT"
  },
  "dxvk": {
    "version": "$DXVK_VERSION",
    "commit": "$DXVK_COMMIT",
    "dir": "lib/wine/dxvk",
    "dlls": [$(dll_names "$STAGE/lib/wine/dxvk")]
  },
  "vkd3d": {
    "version": "$VKD3D_VERSION",
    "commit": "$VKD3D_COMMIT",
    "dir": "lib/wine/vkd3d-proton",
    "dlls": [$(dll_names "$STAGE/lib/wine/vkd3d-proton")]
  },
  "mesa": {
    "version": "$MESA_VERSION",
    "vulkanDriver": "lib/libvulkan_freedreno.so"
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
FEX_VERSION=$FEX_VERSION
FEX_COMMIT=$FEX_COMMIT
DXVK_VERSION=$DXVK_VERSION
DXVK_COMMIT=$DXVK_COMMIT
VKD3D_VERSION=$VKD3D_VERSION
VKD3D_COMMIT=$VKD3D_COMMIT
MESA_VERSION=$MESA_VERSION
ENV
echo "runtime: $archive ($size bytes, $files files, $bytes bytes unpacked, sha256 $sha)"
