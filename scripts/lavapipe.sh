#!/usr/bin/env bash
# Build Lavapipe, Mesa's software Vulkan driver (llvmpipe + swrast Vulkan),
# as an Android aarch64 Vulkan HAL module inside the BuildStream sandbox
# (element mesa/lavapipe.bst).
#
#   lavapipe.sh build     configure and build
#   lavapipe.sh install   install libvulkan_lvp.so and vulkan.lvp.so and check ELF
set -euo pipefail

: "${ANDROID_NDK_HOME:?BuildStream must provide ANDROID_NDK_HOME}"
: "${LVP_PREFIX:?BuildStream must provide LVP_PREFIX}"
: "${MESA_VERSION:?BuildStream must provide MESA_VERSION}"
TARGET="${TARGET_TRIPLE:?BuildStream must provide TARGET_TRIPLE}"

SRC="$PWD"
OUT="$SRC/_amphora"
JOBS="${JOBS:-$(nproc)}"
API="${TARGET##*android}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="/opt/glslang/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
# Only see target static libraries staged at /opt/android-sysroot (libdrm).
export PKG_CONFIG_SYSROOT_DIR=/opt/android-sysroot
export PKG_CONFIG_LIBDIR=/opt/android-sysroot/usr/lib/pkgconfig
unset PKG_CONFIG_PATH

build() {
  local have
  have="$(tr -d '\n' < "$SRC/VERSION")"
  [ "$have" = "$MESA_VERSION" ] || { echo "the source is Mesa $have, the element says $MESA_VERSION" >&2; exit 1; }

  mkdir -p "$OUT"
  cat > "$OUT/cross.txt" <<CROSS
[binaries]
c = '$NDK_BIN/$TARGET-clang'
cpp = '$NDK_BIN/$TARGET-clang++'
ar = '$NDK_BIN/llvm-ar'
strip = '$NDK_BIN/llvm-strip'
pkg-config = 'pkg-config'
llvm-config = '/opt/android-llvm/bin/llvm-config'

[built-in options]
c_link_args = ['-Wl,-z,max-page-size=16384']
cpp_link_args = ['-static-libstdc++', '-Wl,-z,max-page-size=16384']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
CROSS
  cat > "$OUT/native.txt" <<NATIVE
[binaries]
c = '/usr/bin/gcc'
cpp = '/usr/bin/g++'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
NATIVE

  meson setup "$OUT/build" "$SRC" \
    --cross-file "$OUT/cross.txt" --native-file "$OUT/native.txt" \
    --prefix="$LVP_PREFIX" --libdir=lib \
    --buildtype=release --wrap-mode=nodownload -Db_ndebug=true \
    -Dplatforms=android \
    -Dplatform-sdk-version="$API" \
    -Dandroid-stub=true \
    -Dandroid-strict=false \
    -Dandroid-libbacktrace=disabled \
    -Dvulkan-drivers=swrast \
    -Dgallium-drivers=llvmpipe \
    -Dopengl=false -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Dgbm=disabled \
    -Dllvm=enabled -Dshared-llvm=disabled \
    -Dxmlconfig=disabled -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dperfetto=false -Dvideo-codecs= -Dbuild-tests=false
  ninja -C "$OUT/build" -j"$JOBS"
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  DESTDIR="$INSTALL_ROOT" meson install -C "$OUT/build" --no-rebuild

  local root="$INSTALL_ROOT$LVP_PREFIX" so hal
  so="$root/lib/libvulkan_lvp.so"
  test -f "$so" || { echo "missing from the Mesa install: lib/libvulkan_lvp.so" >&2; exit 1; }
  find "$root" -mindepth 1 ! -path "$root/lib" ! -path "$so" -delete

  "$NDK_BIN/llvm-strip" --strip-unneeded "$so"

  # Provide a ready-to-drop-in Android vendor HAL copy with SONAME=vulkan.lvp.so.
  hal="$root/lib/vulkan.lvp.so"
  cp "$so" "$hal"
  patchelf --set-soname vulkan.lvp.so "$hal"

  "$NDK_BIN/llvm-readelf" --dyn-syms -W "$so" | grep -q ' HMI$' || {
    echo "libvulkan_lvp.so does not export HMI" >&2
    exit 1
  }
  if "$NDK_BIN/llvm-readelf" -dW "$so" | grep NEEDED | grep -qv \
      -e '\[libc\.so\]' -e '\[libdl\.so\]' -e '\[libm\.so\]' -e '\[liblog\.so\]' -e '\[libz\.so\]' \
      -e '\[libcutils\.so\]' -e '\[libhardware\.so\]' -e '\[libsync\.so\]' -e '\[libnativewindow\.so\]'; then
    echo "libvulkan_lvp.so: unexpected NEEDED entries:" >&2
    "$NDK_BIN/llvm-readelf" -dW "$so" | grep NEEDED >&2
    exit 1
  fi
  if "$NDK_BIN/llvm-readelf" -dW "$so" | grep -q -e RUNPATH -e RPATH; then
    echo "libvulkan_lvp.so has a RUNPATH" >&2
    exit 1
  fi

  {
    echo "MESA_VERSION=$MESA_VERSION"
    ls -lh "$so" "$hal"
    "$NDK_BIN/llvm-readelf" -dW "$so" | grep -E 'SONAME|NEEDED|RUNPATH|RPATH' || true
    "$NDK_BIN/llvm-readelf" --dyn-syms -W "$so" | grep ' HMI$' || true
  } > "$root/lavapipe-info.txt"
}

case "${1:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 build|install" >&2; exit 2 ;;
esac
