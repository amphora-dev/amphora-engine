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

# --- recc (per-compile action cache through the sandbox remote-apis socket) ---
# Active only when the element provides recc and the socket is there (also in
# `bst shell --build`); otherwise every helper below is a no-op and the build is
# a plain local build.
RECC=""
if command -v recc >/dev/null 2>&1 && [ -n "${RECC_SERVER:-}" ] && [ -S "${RECC_SERVER#unix:}" ]; then
  RECC=recc
  # PATH is part of every action's key, so the shims live at a fixed path, not
  # under the build root (which differs between `bst build` and dev/wine.sh).
  RECC_WRAP=/tmp/recc-wrap
  export RECC_LOG_LEVEL=info RECC_LOG_DIRECTORY=/tmp/recc-logs
  # Paths under the source tree enter action keys relative to it. The sandbox
  # build root is /buildstream/<project>/<element>, so without this a renamed
  # element or project (or another checkout location) misses every action.
  export RECC_PROJECT_ROOT="$SRC"
  mkdir -p "$RECC_LOG_DIRECTORY"
fi

recc_report() {
  [ -n "$RECC" ] || return 0
  python3 - "$RECC_LOG_DIRECTORY" <<'PY'
import sys
from pathlib import Path
c = dict(hit=0, miss=0, updated=0, not_compiler=0)
for p in Path(sys.argv[1]).rglob("*"):
    if p.is_file():
        t = p.read_text(errors="replace")
        c["hit"] += t.count("Action Cache hit for [")
        c["miss"] += t.count("Action not cached and running in cache-only mode")
        c["updated"] += t.count("Action cache updated for [")
        c["not_compiler"] += t.count("Not a compiler command")
print("recc actions: " + " ".join(f"{k}={v}" for k, v in c.items()))
PY
}

# recc does not hash the compiler binary; put the hashes of every wrapped
# compiler in a platform property so a toolchain update cannot replay objects.
recc_setup() {
  [ -n "$RECC" ] || return 0
  local -a cc=(/usr/bin/gcc /usr/bin/g++ "$NDK_BIN/clang" "$NDK_BIN/clang++"
               "$LLVM_MINGW_ROOT/bin/clang" "$LLVM_MINGW_ROOT/bin/clang++")
  RECC_REMOTE_PLATFORM_toolchain="$(sha256sum "${cc[@]}" | sha256sum | cut -d' ' -f1)"
  export RECC_REMOTE_PLATFORM_toolchain
  # Wine's PE side runs bare `clang` from PATH; shim only llvm-mingw's.
  mkdir -p "$RECC_WRAP"
  local n
  for n in clang clang++; do
    printf '#!/bin/sh\nexec recc %q "$@"\n' "$LLVM_MINGW_ROOT/bin/$n" > "$RECC_WRAP/$n"
    chmod +x "$RECC_WRAP/$n"
  done
  echo "wine.sh: recc on (toolchain $RECC_REMOTE_PLATFORM_toolchain)" >&2
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
  export PATH="${RECC:+$RECC_WRAP:}$LLVM_MINGW_ROOT/bin:$NDK_BIN:$HOST_PATH"
  # --target goes into CC itself: Wine links with $(CC) $(LDFLAGS), without $(CFLAGS).
  # recc recognises compilers by basename, so call clang, not the NDK wrapper.
  export CC="${RECC:+recc }$NDK_BIN/clang --target=$TARGET"
  export CXX="${RECC:+recc }$NDK_BIN/clang++ --target=$TARGET"
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
  export PATH="$HOST_PATH"
  export CC="${RECC:+recc }/usr/bin/gcc" CXX="${RECC:+recc }/usr/bin/g++"
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
  recc_setup
  trap 'recc_report || true' EXIT
  generate
  local want have=""
  want="$(configure_fingerprint)"
  [ -f "$OUT/configure.sha256" ] && have="$(cat "$OUT/configure.sha256")"
  if [ "$want" != "$have" ] || [ ! -f "$BUILD/Makefile" ] || [ ! -f "$TOOLS/Makefile" ]; then
    echo "wine.sh: configuring (fingerprint $want)"
    configure_all
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
