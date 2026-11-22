#!/usr/bin/env bash
# Build Turnip, Mesa's Vulkan driver for Adreno, inside the BuildStream sandbox
# (element mesa/turnip.bst).
#
# An Android build of Mesa (meson system 'android', -Dplatforms=android), which
# is what gives the driver VK_ANDROID_external_memory_android_hardware_buffer:
# the swapchain in Wine's Android driver imports AHardwareBuffers. The result
# is an Android Vulkan HAL module whose only export is HMI; Wine's Android
# driver opens it and asks it for vkGetInstanceProcAddr, as the platform's
# loader would.
#
# Only the KGSL kernel interface (-Dfreedreno-kmds=kgsl): Android's Adreno
# kernel driver is KGSL, and without the DRM backend Mesa needs no libdrm.
#
#   turnip.sh build     configure and build
#   turnip.sh install   install into $INSTALL_ROOT$TURNIP_PREFIX and check the result
set -euo pipefail

: "${ANDROID_NDK_HOME:?BuildStream must provide ANDROID_NDK_HOME}"
: "${TURNIP_PREFIX:?BuildStream must provide TURNIP_PREFIX}"
: "${MESA_VERSION:?BuildStream must provide MESA_VERSION}"
TARGET="${TARGET_TRIPLE:?BuildStream must provide TARGET_TRIPLE}"

SRC="$PWD"
OUT="$SRC/_amphora"
JOBS="${JOBS:-$(nproc)}"
API="${TARGET##*android}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="/opt/glslang/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# project.conf exports the NDK compilers for every element; meson takes them
# from the cross file, and the generators it runs on the build machine must
# not pick them up.
unset CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
# No .pc file of the build machine may satisfy a dependency of the driver.
export PKG_CONFIG_LIBDIR="$OUT/no-pkgconfig"
unset PKG_CONFIG_PATH

build() {
  local have
  have="$(tr -d '\n' < "$SRC/VERSION")"
  [ "$have" = "$MESA_VERSION" ] || { echo "the source is Mesa $have, the element says $MESA_VERSION" >&2; exit 1; }

  mkdir -p "$OUT" "$PKG_CONFIG_LIBDIR"
  cat > "$OUT/cross.txt" <<CROSS
[binaries]
c = '$NDK_BIN/$TARGET-clang'
cpp = '$NDK_BIN/$TARGET-clang++'
ar = '$NDK_BIN/llvm-ar'
strip = '$NDK_BIN/llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
# Loaded into Wine's process, which has no C++ runtime: none is shipped.
cpp_link_args = ['-static-libstdc++']

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
    --prefix="$TURNIP_PREFIX" --libdir=lib \
    --buildtype=release --wrap-mode=nodownload -Db_ndebug=true \
    -Dplatforms=android \
    -Dplatform-sdk-version="$API" \
    -Dandroid-stub=true \
    -Dandroid-strict=false \
    -Dandroid-libbacktrace=disabled \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Dgallium-drivers= \
    -Dopengl=false -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Dgbm=disabled \
    -Dllvm=disabled -Dshared-llvm=disabled \
    -Dxmlconfig=disabled -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dperfetto=false -Dvideo-codecs= -Dbuild-tests=false
  ninja -C "$OUT/build" -j"$JOBS"
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  # Installed, not the build tree's file: that one has a RUNPATH into the build tree.
  DESTDIR="$INSTALL_ROOT" meson install -C "$OUT/build" --no-rebuild

  local root="$INSTALL_ROOT$TURNIP_PREFIX" so patches
  so="$root/lib/libvulkan_freedreno.so"
  test -f "$so" || { echo "missing from the Mesa install: lib/libvulkan_freedreno.so" >&2; exit 1; }
  find "$root" -mindepth 1 ! -path "$root/lib" ! -path "$so" -delete
  # The patches the element applied, by content: part of what the runtime is named after.
  patches="$(find "$SRC/.bst/patches" -type f -name '*.patch' | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-8)"
  printf 'MESA_VERSION=%s\nMESA_PATCHES=%s\n' "$MESA_VERSION" "$patches" > "$root/amphora-turnip.env"

  # What Wine's Android driver looks up.
  "$NDK_BIN/llvm-readelf" --dyn-syms -W "$so" | grep -q ' HMI$' ||
    { echo "libvulkan_freedreno.so does not export HMI" >&2; exit 1; }
  # Bionic and libraries every Android system image has; nothing of ours, no C++ runtime.
  if "$NDK_BIN/llvm-readelf" -dW "$so" | grep NEEDED | grep -qv \
      -e '\[libc\.so\]' -e '\[libdl\.so\]' -e '\[libm\.so\]' -e '\[liblog\.so\]' -e '\[libz\.so\]' \
      -e '\[libcutils\.so\]' -e '\[libhardware\.so\]' -e '\[libsync\.so\]' -e '\[libnativewindow\.so\]'; then
    echo "libvulkan_freedreno.so: unexpected NEEDED entries:" >&2
    "$NDK_BIN/llvm-readelf" -dW "$so" | grep NEEDED >&2
    exit 1
  fi
  if "$NDK_BIN/llvm-readelf" -dW "$so" | grep -q -e RUNPATH -e RPATH; then
    echo "libvulkan_freedreno.so has a RUNPATH" >&2
    exit 1
  fi
}

case "${1:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 build|install" >&2; exit 2 ;;
esac
