#!/usr/bin/env bash
# Cross-compile static LLVM 20.1.8 (AArch64 target only) for Android aarch64
# inside the BuildStream sandbox (element libs/llvm.bst).
#
#   llvm.sh build     configure and build target static libs + host llvm-config
#   llvm.sh install   install to $INSTALL_ROOT$LLVM_PREFIX with target llvm-config wrapper
set -euo pipefail

: "${ANDROID_NDK_HOME:?BuildStream must provide ANDROID_NDK_HOME}"
: "${LLVM_PREFIX:?BuildStream must provide LLVM_PREFIX}"
TARGET="${TARGET_TRIPLE:?BuildStream must provide TARGET_TRIPLE}"

SRC="$PWD"
OUT="$SRC/_amphora"
JOBS="${JOBS:-$(nproc)}"
API="${TARGET##*android}"

export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# project.conf exports NDK compilers in the environment; unset them so LLVM's
# NATIVE sub-build uses host gcc/g++ while the target build uses the NDK
# CMake toolchain file.
unset CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

build() {
  mkdir -p "$OUT"
  cmake -S "$SRC/llvm" -B "$OUT/build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX" \
    -DCROSS_TOOLCHAIN_FLAGS_NATIVE="-DCMAKE_C_COMPILER=/usr/bin/gcc;-DCMAKE_CXX_COMPILER=/usr/bin/g++" \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_TARGET_ARCH=AArch64 \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET" \
    -DLLVM_HOST_TRIPLE="$TARGET" \
    -DLLVM_ENABLE_ZLIB=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_CURSES=OFF \
    -DLLVM_ENABLE_RTTI=OFF \
    -DLLVM_ENABLE_EH=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TOOLS=ON \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_OCAMLDOC=OFF \
    -DLLVM_OPTIMIZED_TABLEGEN=ON

  # Build target static libraries + headers, plus the host-runnable llvm-config
  # (configured with the same AArch64 target set via CrossCompile.cmake).
  cmake --build "$OUT/build" -j"$JOBS" --target llvm-libraries llvm-headers NativeLLVMConfig
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  DESTDIR="$INSTALL_ROOT" cmake --install "$OUT/build" --component llvm-libraries
  DESTDIR="$INSTALL_ROOT" cmake --install "$OUT/build" --component llvm-headers

  local root="$INSTALL_ROOT$LLVM_PREFIX"
  mkdir -p "$root/bin"
  test -x "$OUT/build/NATIVE/bin/llvm-config" || {
    echo "missing NATIVE/bin/llvm-config" >&2
    exit 1
  }
  cp -a "$OUT/build/NATIVE/bin/llvm-config" "$root/bin/llvm-config-raw"

  # Wrap host llvm-config so cross-compiling Meson gets Android target paths,
  # target system libs (no -lrt / -lpthread on Bionic), and maps `native` to
  # `aarch64` (since the host binary thinks native == x86_64).
  cat > "$root/bin/llvm-config" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
PREFIX="\$(dirname "\$SELF_DIR")"
RAW="\$SELF_DIR/llvm-config-raw"

args=()
want_system_libs=0
want_ldflags=0
want_cppflags=0
want_cflags=0
want_cxxflags=0
want_host_target=0

for a in "\$@"; do
  case "\$a" in
    native) args+=(aarch64) ;;
    --system-libs) want_system_libs=1; args+=("\$a") ;;
    --ldflags) want_ldflags=1; args+=("\$a") ;;
    --cppflags) want_cppflags=1; args+=("\$a") ;;
    --cflags) want_cflags=1; args+=("\$a") ;;
    --cxxflags) want_cxxflags=1; args+=("\$a") ;;
    --host-target) want_host_target=1; args+=("\$a") ;;
    *) args+=("\$a") ;;
  esac
done

# Single-flag overrides for target-specific queries.
if [ "\$#" -eq 1 ]; then
  if [ "\$want_system_libs" -eq 1 ]; then
    echo "-lm -ldl -lz"
    exit 0
  elif [ "\$want_ldflags" -eq 1 ]; then
    echo "-L\$PREFIX/lib"
    exit 0
  elif [ "\$want_cppflags" -eq 1 ]; then
    echo "-I\$PREFIX/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
    exit 0
  elif [ "\$want_cflags" -eq 1 ]; then
    echo "-I\$PREFIX/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
    exit 0
  elif [ "\$want_cxxflags" -eq 1 ]; then
    echo "-I\$PREFIX/include -std=c++17 -fno-exceptions -fno-rtti -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
    exit 0
  elif [ "\$want_host_target" -eq 1 ]; then
    echo "$TARGET"
    exit 0
  fi
fi

out="\$("\$RAW" "\${args[@]}")"
# Strip host-only system libraries when --system-libs is combined with other flags.
if [ "\$want_system_libs" -eq 1 ]; then
  out="\$(printf '%s\n' "\$out" | sed -E 's/(^| )-l(rt|pthread|tinfo|zstd|xml2|edit|curses|ncurses)( |\$)/ /g')"
fi
printf '%s\n' "\$out"
EOF
  chmod +x "$root/bin/llvm-config"

  # Smoke-test the exact queries Mesa 26.3.1's meson.build runs for Lavapipe.
  "$root/bin/llvm-config" --version
  "$root/bin/llvm-config" --targets-built
  "$root/bin/llvm-config" --has-rtti
  "$root/bin/llvm-config" --shared-mode
  "$root/bin/llvm-config" --link-static --libs bitwriter engine mcdisassembler core executionengine scalaropts transformutils instcombine coroutines native lto mcjit >/dev/null
  "$root/bin/llvm-config" --link-static --system-libs
}

case "${1:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 build|install" >&2; exit 2 ;;
esac
