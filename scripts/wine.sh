#!/usr/bin/env bash
# Build the Amphora engine's Wine inside the BuildStream sandbox
# (element wine/wine.bst).
#
# Source: Valve's Proton Experimental Wine plus Amphora's patch stack
# (amphora:proton-wine.git), staged by BuildStream without .git. The unix side
# is aarch64 Android (Bionic, API 30, 16 KB pages, NDK clang); the PE side is
# aarch64 + arm64ec (ARM64X) + i386, built with llvm-mingw.
#
#   wine.sh build     generate sources, configure when needed, make
#   wine.sh install   make install into $INSTALL_ROOT and check the result
#
# `build` is incremental: in a BuildStream workspace the previous build tree is
# reused, so configure only reruns when its inputs change, and the generators
# leave unchanged outputs (and their mtimes) alone.
#
# Generated sources follow Proton (make/rules-wine-requests.mk and the
# .wine-post-source rule in Makefile.in): Valve's tree carries stale copies of
# the server protocol headers (protocol 930 while protocol.def is 931) and no
# syscall tables or Vulkan thunks. They are regenerated in this build copy every
# time and never committed to the Wine branch.
set -euo pipefail

: "${ANDROID_NDK_HOME:?BuildStream must provide ANDROID_NDK_HOME}"
: "${LLVM_MINGW_ROOT:?BuildStream must provide LLVM_MINGW_ROOT}"
: "${TARGET_SYSROOT:?BuildStream must provide TARGET_SYSROOT}"
: "${HOST_FREETYPE:?BuildStream must provide HOST_FREETYPE}"
: "${WINE_PREFIX:?BuildStream must provide WINE_PREFIX}"

SRC="$PWD"
# Build tree, inside the source tree as in `bst build` (where it is kept as the
# element's buildtree on failure). dev/wine.sh mounts its own tree here.
OUT="${AMPHORA_BUILD_DIR:-$SRC/_amphora}"
# Siblings: configure_flags passes the tools tree to the target tree as ../tools.
TOOLS="$OUT/tools"
BUILD="$OUT/wine"
JOBS="${JOBS:-$(nproc)}"
# project.conf target-triple, passed in by wine/wine.bst.
TARGET="${TARGET_TRIPLE:?BuildStream must provide TARGET_TRIPLE}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
HOST_PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- ccache --------------------------------------------------------------------
# Every compile goes through ccache. A `bst build` sandbox starts empty, so the
# cache directory travels through buildbox-casd: restored from CAS before the
# build and stored back after it (ccache-cas, scripts/ccache-cas.py, over the
# element's remote-apis socket), next to the element artifacts.
#
#   AMPHORA_CCACHE=sync     restore, build, store (default when the socket is there)
#   AMPHORA_CCACHE=restore  restore, build (dev/wine.sh: a persistent CCACHE_DIR
#                           that merges in what `bst build` stored)
#   AMPHORA_CCACHE=local    no CAS (default without the socket)
#   AMPHORA_CCACHE=off      no ccache
export AMPHORA_CAS_SOCKET="${AMPHORA_CAS_SOCKET:-/tmp/reapi.sock}"
CCACHE_MODE="${AMPHORA_CCACHE:-}"
if [ -z "$CCACHE_MODE" ]; then
  CCACHE_MODE=local
  [ -S "$AMPHORA_CAS_SOCKET" ] && command -v ccache-cas >/dev/null 2>&1 && CCACHE_MODE=sync
fi
case "$CCACHE_MODE" in
  sync|restore|local|off) ;;
  *) echo "wine.sh: AMPHORA_CCACHE=$CCACHE_MODE is not sync, restore, local or off" >&2; exit 2 ;;
esac
command -v ccache >/dev/null 2>&1 || CCACHE_MODE=off
# Name of the stored cache directory.
CCACHE_NAME=wine
# Compiler wrappers. The path ends up in the Makefiles and the configure
# fingerprint, so it is fixed rather than under the build tree (which differs
# between `bst build` and dev/wine.sh).
CCACHE_WRAP=/tmp/ccache-wrap
# Set by build() when the whole tree is compiled from scratch.
CCACHE_FRESH=""

# ccache_wrap NAME COMPILER [FILE...]: $CCACHE_WRAP/NAME runs COMPILER through
# ccache. BuildStream stages every file with the same mtime, so ccache's default
# compiler check (mtime and size) cannot tell two builds of a compiler apart;
# each wrapper identifies its compiler by the content of the binary and of the
# FILEs that also decide the output (gcc's cc1 and as, clang config files).
ccache_wrap() {
  local name="$1" id
  id="$(sha256sum "${@:2}" | sha256sum | cut -c1-32)"
  printf '#!/bin/sh\nCCACHE_COMPILERCHECK=string:%s exec ccache %s "$@"\n' "$id" "$2" > "$CCACHE_WRAP/$name"
  chmod +x "$CCACHE_WRAP/$name"
}

ccache_start() {
  [ "$CCACHE_MODE" != off ] || return 0
  export CCACHE_DIR="${CCACHE_DIR:-/tmp/ccache}"
  # Absolute paths under the source tree are hashed relative to the working
  # directory, so `bst build` (/buildstream/<project>/<element>) and dev/wine.sh
  # (/src) share results. Target compiles pass -fdebug-compilation-dir=., which
  # keeps the directory out of the hash already; the host tools are not
  # shipped, so their debug info may name another directory.
  export CCACHE_BASEDIR="$SRC" CCACHE_NOHASHDIR=1
  mkdir -p "$CCACHE_WRAP" "$CCACHE_DIR"
  ccache_wrap gcc /usr/bin/gcc "$(gcc -print-prog-name=cc1)" "$(command -v "$(gcc -print-prog-name=as)")"
  ccache_wrap g++ /usr/bin/g++ "$(g++ -print-prog-name=cc1plus)" "$(command -v "$(g++ -print-prog-name=as)")"
  ccache_wrap android-clang "$NDK_BIN/clang"
  ccache_wrap android-clang++ "$NDK_BIN/clang++"
  # Wine runs llvm-mingw's compiler as plain `clang` from PATH, which loads the
  # <triple>.cfg next to it.
  local -a cfg
  mapfile -t cfg < <(find "$LLVM_MINGW_ROOT/bin" -maxdepth 1 -name '*.cfg' | sort)
  ccache_wrap clang "$LLVM_MINGW_ROOT/bin/clang" "${cfg[@]}"
  ccache_wrap clang++ "$LLVM_MINGW_ROOT/bin/clang++" "${cfg[@]}"
  case "$CCACHE_MODE" in
    sync|restore) ccache-cas restore "$CCACHE_DIR" "$CCACHE_NAME" ;;
  esac
  # Recount after a merge and keep within max_size, then count this build only.
  ccache --cleanup >/dev/null
  ccache --zero-stats >/dev/null
  CCACHE_T0=$SECONDS
  echo "wine.sh: ccache $CCACHE_MODE, $CCACHE_DIR, $(ccache_stat files_in_cache) files"
}

ccache_stat() {
  ccache --print-stats | awk -F'\t' -v k="$1" '$1 == k { print $2; found = 1 } END { if (!found) print 0 }'
}

# Report; in sync mode, store the cache when this build compiled something new.
# After a successful build of a fresh tree, entries the build did not use belong
# to older sources: they are evicted first, so the stored cache stays the size
# of one Wine build. A build with no misses is not stored: what it would add
# are direct-mode manifests for compiles of randomly named temporary files
# (winebuild), which only ever hit in preprocessed mode, and the stored copy
# already holds every result. Runs on exit, also after a failed build (its
# compile results are still good). Never fails.
ccache_finish() {
  local status="$1" hit direct miss files evicted=0
  [ "$CCACHE_MODE" != off ] || return 0
  direct="$(ccache_stat direct_cache_hit)"
  hit=$((direct + $(ccache_stat preprocessed_cache_hit)))
  miss="$(ccache_stat cache_miss)"
  if [ "$CCACHE_MODE" = sync ] && [ "$status" = 0 ] && [ -n "$CCACHE_FRESH" ]; then
    files="$(ccache_stat files_in_cache)"
    ccache --evict-older-than "$((SECONDS - CCACHE_T0 + 60))s" >/dev/null
    evicted=$((files - $(ccache_stat files_in_cache)))
  fi
  ccache --show-stats
  printf 'ccache stats: hit=%s (direct %s) miss=%s evicted=%s, %s files, %s MiB\n' \
    "$hit" "$direct" "$miss" "$evicted" "$(ccache_stat files_in_cache)" "$(($(ccache_stat cache_size_kibibyte) / 1024))"
  if [ "$CCACHE_MODE" = sync ]; then
    if [ "$miss" -gt 0 ]; then
      ccache-cas save "$CCACHE_DIR" "$CCACHE_NAME"
    else
      echo "ccache-cas: no new compile results; the stored cache is kept"
    fi
  fi
}

# shellcheck disable=SC2054 # --enable-archs takes a comma separated list
configure_flags=(
  --host="$TARGET"
  --prefix="$WINE_PREFIX"
  # Android's configure default puts binaries under $prefix/arm64-v8a; keep the
  # standard bin/ lib/ share/ layout that ntdll's relative path logic expects.
  --exec-prefix="$WINE_PREFIX"
  --enable-archs=arm64ec,aarch64,i386
  --with-mingw=clang
  # Relative (to $BUILD, where make runs): no build-root path in any command.
  --with-wine-tools=../tools
  --disable-tests
  --disable-win16
  # amd_ags_x64 needs libdrm.
  --disable-amd_ags_x64
  --enable-wineandroid_drv
  --with-freetype
  --without-alsa --without-capi --without-coreaudio --without-cups --without-dbus
  --without-ffmpeg --without-fontconfig --without-gettext --with-gettextpo=no
  --without-gnutls --without-gphoto --without-gssapi --without-gstreamer
  --without-inotify --without-krb5 --without-netapi --without-opencl --without-oss
  --without-pcap --without-pcsclite --without-piper --without-pulse --without-sane
  --without-sdl --without-udev --without-unwind --without-usb --without-v4l2
  --without-vosk --without-vulkan --without-wayland --without-x
)

target_env() {
  local wrap="" cc="$NDK_BIN/clang" cxx="$NDK_BIN/clang++"
  if [ "$CCACHE_MODE" != off ]; then
    wrap="$CCACHE_WRAP:" cc="$CCACHE_WRAP/android-clang" cxx="$CCACHE_WRAP/android-clang++"
  fi
  export PATH="$wrap$LLVM_MINGW_ROOT/bin:$NDK_BIN:$HOST_PATH"
  # --target goes into CC itself: Wine links with $(CC) $(LDFLAGS), without
  # $(CFLAGS). Plain clang, not the NDK's <triple>-clang wrapper script.
  export CC="$cc --target=$TARGET" CXX="$cxx --target=$TARGET"
  export AR="$NDK_BIN/llvm-ar" RANLIB="$NDK_BIN/llvm-ranlib" STRIP="$NDK_BIN/llvm-strip"
  export DLLTOOL="$LLVM_MINGW_ROOT/bin/llvm-dlltool"
  # Wine's configure only looks for $host-pkg-config when cross compiling;
  # name the plain one and confine it to the target sysroot.
  export PKG_CONFIG=pkg-config PKG_CONFIG_PATH=''
  export PKG_CONFIG_SYSROOT_DIR="$TARGET_SYSROOT"
  export PKG_CONFIG_LIBDIR="$TARGET_SYSROOT/usr/lib/pkgconfig:$TARGET_SYSROOT/usr/share/pkgconfig"
  # -fdebug-compilation-dir=.: debug info records no build-root path either, so
  # the objects themselves do not depend on where the tree was built.
  export CFLAGS="-O2 -g -fdebug-compilation-dir=. -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES"
  export CROSSCFLAGS="-O2 -g -fdebug-compilation-dir=."
  export LDFLAGS="-Wl,-z,max-page-size=16384"
}

host_env() {
  export PATH="$HOST_PATH" CC=/usr/bin/gcc CXX=/usr/bin/g++
  if [ "$CCACHE_MODE" != off ]; then
    export CC="$CCACHE_WRAP/gcc" CXX="$CCACHE_WRAP/g++"
  fi
  unset AR RANLIB STRIP DLLTOOL CFLAGS CROSSCFLAGS LDFLAGS PKG_CONFIG PKG_CONFIG_SYSROOT_DIR
  export PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR="$HOST_FREETYPE/lib/pkgconfig"
  export LD_LIBRARY_PATH="$HOST_FREETYPE/lib"
}

# make_vulkan rewrites its outputs unconditionally; keep the old file (and
# mtime) when the content is the same so incremental builds stay incremental.
run_make_vulkan() {
  local outputs=(
    include/wine/vulkan.h
    dlls/winevulkan/vulkan_thunks.h dlls/winevulkan/vulkan_thunks.c
    dlls/winevulkan/loader_thunks.h dlls/winevulkan/loader_thunks.c
    dlls/winevulkan/winevulkan.json dlls/winevulkan/winevulkan.spec
    dlls/vulkan-1/vulkan-1.spec
  )
  local keep="$OUT/make_vulkan.prev" f
  rm -rf "$keep"
  mkdir -p "$keep"
  for f in "${outputs[@]}"; do
    if [ -f "$f" ]; then
      mkdir -p "$keep/$(dirname "$f")"
      cp -p "$f" "$keep/$f"
    fi
  done
  dlls/winevulkan/make_vulkan -x vk.xml -X video.xml
  for f in "${outputs[@]}"; do
    test -f "$f" || { echo "make_vulkan did not write $f" >&2; exit 1; }
    if [ -f "$keep/$f" ] && cmp -s "$keep/$f" "$f"; then
      cp -p "$keep/$f" "$f"
    fi
  done
  rm -rf "$keep"
}

generate() {
  (
    export PATH="$HOST_PATH"
    cd "$SRC"
    tools/make_requests
    tools/make_specfiles
    run_make_vulkan
  )
}

configure_fingerprint() {
  {
    printf '%s\n' "${configure_flags[@]}"
    target_env
    for v in PATH CC CXX AR RANLIB STRIP DLLTOOL CFLAGS CROSSCFLAGS LDFLAGS \
             PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR; do
      printf '%s=%s\n' "$v" "${!v-}"
    done
    cat "$SRC/configure.ac" "$SRC/aclocal.m4"
    # A toolchain or sysroot change must reconfigure too.
    sha256sum "$NDK_BIN/clang" "$LLVM_MINGW_ROOT/bin/clang"
    find "$TARGET_SYSROOT" -type f -print0 | sort -z | xargs -0 sha256sum
  } | sha256sum | cut -d' ' -f1
}

configure_all() {
  ( cd "$SRC" && PATH="$HOST_PATH" autoreconf -fi && rm -rf autom4te.cache )

  rm -rf "$TOOLS" "$BUILD"
  mkdir -p "$TOOLS" "$BUILD"
  # Native build tools (widl, winebuild, wrc, sfnt2fon, ...) and NLS data.
  (
    host_env
    cd "$TOOLS"
    "$(realpath --relative-to="$TOOLS" "$SRC")/configure" --enable-win64 --without-x --without-gstreamer --without-vulkan \
      --without-wayland --without-pulse --without-alsa --without-sdl --disable-tests
  )
  (
    target_env
    cd "$BUILD"
    # A relative srcdir makes every source and -I path in the build relative.
    "$(realpath --relative-to="$BUILD" "$SRC")/configure" "${configure_flags[@]}"
  )
}

build() {
  mkdir -p "$OUT"
  ccache_start
  trap 'status=$?; ccache_finish "$status" || true; exit "$status"' EXIT
  generate
  local want have=""
  want="$(configure_fingerprint)"
  [ -f "$OUT/configure.sha256" ] && have="$(cat "$OUT/configure.sha256")"
  if [ "$want" != "$have" ] || [ ! -f "$BUILD/Makefile" ] || [ ! -f "$TOOLS/Makefile" ]; then
    echo "wine.sh: configuring (fingerprint $want)"
    configure_all
    CCACHE_FRESH=1
    echo "$want" > "$OUT/configure.sha256"
  else
    echo "wine.sh: configure inputs unchanged, building incrementally"
  fi
  ( host_env && make -C "$TOOLS" -j"$JOBS" __tooldeps__ nls/all )
  ( target_env && make -C "$BUILD" -j"$JOBS" )
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  ( target_env && make -C "$BUILD" -j"$JOBS" DESTDIR="$INSTALL_ROOT" install )

  local root="$INSTALL_ROOT$WINE_PREFIX" f version
  version="$(sed -n 's/^Wine version //p' "$SRC/VERSION")"
  test -n "$version"
  printf 'WINE_VERSION=%s\n' "$version" > "$root/amphora-wine.env"
  for f in \
    bin/wineserver \
    lib/wine/aarch64-unix/wine \
    lib/wine/aarch64-unix/ntdll.so \
    lib/wine/aarch64-unix/win32u.so \
    lib/wine/aarch64-unix/wineandroid.so \
    lib/wine/aarch64-windows/ntdll.dll \
    lib/wine/aarch64-windows/kernelbase.dll \
    lib/wine/aarch64-windows/wineandroid.drv \
    lib/wine/aarch64-windows/explorer.exe \
    lib/wine/i386-windows/ntdll.dll \
    lib/wine/i386-windows/kernelbase.dll \
    share/wine/wine.inf \
    share/wine/nls/l_intl.nls; do
    test -f "$root/$f" || { echo "missing from the Wine install: $f" >&2; exit 1; }
  done
  # Android runs app-private executables through /system/bin/linker64, which
  # cannot load a static binary; the Wine branch disables the preloader there.
  if [ -e "$root/lib/wine/aarch64-unix/wine-preloader" ]; then
    echo "wine-preloader was built; the Android preloader patch is missing" >&2
    exit 1
  fi
  # aarch64-windows must hold ARM64X images (aarch64 + arm64ec in one file).
  "$LLVM_MINGW_ROOT/bin/llvm-objdump" -h "$root/lib/wine/aarch64-windows/kernelbase.dll" |
    grep -q 'file format coff-arm64x' ||
    { echo "kernelbase.dll is not ARM64X" >&2; exit 1; }
  # 16 KB page compatibility: every unix ELF must use 16 KB LOAD alignment.
  find "$root/lib/wine/aarch64-unix" "$root/bin" -type f -print0 |
    while IFS= read -r -d '' f; do
      "$NDK_BIN/llvm-readelf" -h "$f" >/dev/null 2>&1 || continue
      if "$NDK_BIN/llvm-readelf" -lW "$f" | awk '$1 == "LOAD" { print $NF }' | grep -qv '^0x4000$'; then
        echo "$f: LOAD segments are not 16 KB aligned" >&2
        exit 1
      fi
    done
}

case "${1:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 build|install" >&2; exit 2 ;;
esac
