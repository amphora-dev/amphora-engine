#!/usr/bin/env bash
# Build FEX's Wine modules inside the BuildStream sandbox (element fex/fex.bst).
#
# Wine on ARM64 runs x86 code through two PE modules it loads by name:
#   libarm64ecfex.dll   x86_64 processes (ARM64EC)
#   libwow64fex.dll     32-bit x86 processes (WoW64)
# plus one unix library per module (libarm64ecfex.so, libwow64fex.so) for the
# few calls that need Linux (TSO prctl, madvise, VMA names). Same build as
# Proton's Makefile.in (FEX section) at the Proton tag the Wine follows: the
# common CMake flags, Release, mingw toolchain from FEX's own toolchain file.
# Only the unix side differs: Android (NDK, Bionic, API from TARGET_TRIPLE)
# instead of glibc, with fex/patches/unixlib-android.patch.
#
#   fex.sh build     configure and build the three trees
#   fex.sh install   install into $INSTALL_ROOT$FEX_PREFIX and check the result
set -euo pipefail

: "${ANDROID_NDK_HOME:?BuildStream must provide ANDROID_NDK_HOME}"
: "${LLVM_MINGW_ROOT:?BuildStream must provide LLVM_MINGW_ROOT}"
: "${FEX_PREFIX:?BuildStream must provide FEX_PREFIX}"
: "${FEX_COMMIT:?BuildStream must provide FEX_COMMIT}"
: "${FEX_DESCRIBE:?BuildStream must provide FEX_DESCRIBE}"
TARGET="${TARGET_TRIPLE:?BuildStream must provide TARGET_TRIPLE}"

SRC="$PWD"
OUT="$SRC/_amphora"
JOBS="${JOBS:-$(nproc)}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$LLVM_MINGW_ROOT/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# project.conf exports the NDK compilers for every element; FEX's mingw
# toolchain file and the NDK's own pick their compilers themselves.
unset CC CXX AR RANLIB NM STRIP

# Proton's FEX_COMMON_CMAKE_ARGS. BuildStream stages the source without .git,
# so the version comes from fex/fex.bst (git describe --abbrev=7 there).
common=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_FEXCORE_PROFILER=True -DENABLE_LTO=False
  -DBUILD_TESTING=False -DTUNE_CPU=none -DRANGES_NATIVE=OFF
  -DBUILD_STEAM_SUPPORT=True
  -DENABLE_CCACHE=False
  -DOVERRIDE_VERSION="$FEX_DESCRIBE"
  -DOVERRIDE_HASH="${FEX_COMMIT:0:7}"
  -DCMAKE_INSTALL_PREFIX="$FEX_PREFIX"
)

build() {
  local triple
  for triple in aarch64-w64-mingw32 arm64ec-w64-mingw32; do
    cmake -S "$SRC" -B "$OUT/$triple" "${common[@]}" \
      -DCMAKE_TOOLCHAIN_FILE="$SRC/Data/CMake/toolchain_mingw.cmake" \
      -DMINGW_TRIPLE="$triple" \
      -DCMAKE_INSTALL_LIBDIR=lib/wine/aarch64-windows
    cmake --build "$OUT/$triple" -j"$JOBS"
  done

  cmake -S "$SRC/Source/Windows/UnixLib" -B "$OUT/unix" "${common[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-${TARGET##*android}" \
    -DANDROID_STL=c++_static \
    -DCMAKE_INSTALL_LIBDIR=lib/wine/aarch64-unix
  cmake --build "$OUT/unix" -j"$JOBS"
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  local tree
  for tree in aarch64-w64-mingw32 arm64ec-w64-mingw32 unix; do
    DESTDIR="$INSTALL_ROOT" cmake --install "$OUT/$tree"
  done

  local root="$INSTALL_ROOT$FEX_PREFIX" f
  printf 'FEX_VERSION=%s\nFEX_COMMIT=%s\n' "$FEX_DESCRIBE" "$FEX_COMMIT" > "$root/amphora-fex.env"
  for f in \
    lib/wine/aarch64-windows/libarm64ecfex.dll \
    lib/wine/aarch64-windows/libwow64fex.dll \
    lib/wine/aarch64-unix/libarm64ecfex.so \
    lib/wine/aarch64-unix/libwow64fex.so; do
    test -f "$root/$f" || { echo "missing from the FEX install: $f" >&2; exit 1; }
  done
  # The unix libraries are loaded into Wine's process: Bionic only, no C++
  # runtime of their own to clash with.
  for f in "$root"/lib/wine/aarch64-unix/*.so; do
    if "$NDK_BIN/llvm-readelf" -dW "$f" | grep NEEDED | grep -qv -e '\[libc\.so\]' -e '\[libdl\.so\]' -e '\[libm\.so\]'; then
      echo "${f#"$root"/}: unexpected NEEDED entries:" >&2
      "$NDK_BIN/llvm-readelf" -dW "$f" | grep NEEDED >&2
      exit 1
    fi
  done
}

case "${1:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 build|install" >&2; exit 2 ;;
esac
