#!/usr/bin/env bash
# Build DXVK or vkd3d-proton inside the BuildStream sandbox
# (elements dxvk/dxvk.bst and vkd3d-proton/vkd3d-proton.bst).
#
# Same build as Proton's Makefile.in at the tag the Wine follows (sections
# "dxvk" and "vkd3d-proton", make/rules-meson.mk): meson with buildtype plain,
# Proton's compiler flags, stripped on install, one tree per PE architecture:
#   i386       lib/wine/<project>/i386-windows      32-bit x86 (WoW64)
#   arm64ec    lib/wine/<project>/aarch64-windows   x86_64 programs (ARM64EC)
# Proton also builds x86_64 files for its x86_64 Wine; this Wine has none.
# Proton's -ggdb is left out: the files are stripped, and it does not change
# the code.
#
# One difference from the tag: its arm64ec files are ARM64X (-marm64x), which
# ARM64 processes can load as well. Linking those needs Valve's llvm-mingw:
# the same release with 13 LLVM patches and a C runtime rebuilt in ARM64X mode
# (Proton's docker/). The upstream release this project builds with has an
# ARM64EC-only C runtime, so the files here are ARM64EC, as in Proton 11.0's
# ARM64 build. Only programs that are themselves ARM64 notice.
#
#   d3d.sh dxvk|vkd3d-proton build     configure and build both trees
#   d3d.sh dxvk|vkd3d-proton install   install into $INSTALL_ROOT$D3D_PREFIX and check
set -euo pipefail

: "${LLVM_MINGW_ROOT:?BuildStream must provide LLVM_MINGW_ROOT}"
: "${D3D_PREFIX:?BuildStream must provide D3D_PREFIX}"

project="${1:-}"
SRC="$PWD"
OUT="$SRC/_amphora"
JOBS="${JOBS:-$(nproc)}"
export PATH="/opt/glslang/bin:$LLVM_MINGW_ROOT/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# project.conf exports the NDK compilers for every element; these are PE builds.
unset CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

# Proton's CFLAGS and its per-architecture flags (Makefile.in).
cflags="-O2 -fwrapv -fno-strict-aliasing -ffunction-sections -fdata-sections -fno-omit-frame-pointer"
i386_flags="-mstackrealign -march=nocona -mtune=core-avx2 -mfpmath=sse"
arm64ec_flags="-march=armv8.2-a -mtune=cortex-x3"

case "$project" in
  dxvk)
    : "${DXVK_COMMIT:?}" "${DXVK_DESCRIBE:?}"
    dlls=(d3d8 d3d9 d3d10core d3d11 dxgi)
    ;;
  vkd3d-proton)
    : "${VKD3D_COMMIT:?}" "${VKD3D_BUILD:?}" "${VKD3D_DESCRIBE:?}"
    dlls=(d3d12 d3d12core)
    ;;
  *) echo "usage: $0 dxvk|vkd3d-proton build|install" >&2; exit 2 ;;
esac

# meson list syntax for a string of flags.
quote() {
  local out="" f
  for f in "$@"; do out="$out${out:+, }'$f'"; done
  printf '%s' "$out"
}

# cross_file ARCH TRIPLE CPU FLAGS LINK_FLAGS
cross_file() {
  local arch="$1" triple="$2" cpu="$3" flags link
  # shellcheck disable=SC2086
  flags="$(quote $4)"
  # shellcheck disable=SC2086
  link="$(quote $5)"
  cat > "$OUT/cross-$arch.txt" <<CROSS
[binaries]
c = '$triple-clang'
cpp = '$triple-clang++'
ar = '$triple-ar'
strip = '$triple-strip'
windres = '$triple-windres'
widl = '$triple-widl'

[built-in options]
c_args = [$flags]
cpp_args = [$flags]
c_link_args = [$link]
cpp_link_args = [$link]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$cpu'
cpu = '$cpu'
endian = 'little'
CROSS
}

# BuildStream stages the source without .git, so the version strings meson
# would take from `git describe` come from the element, as in Proton's
# post-source rules.
write_versions() {
  case "$project" in
    dxvk)
      sed -i "s#@VCS_TAG@#$DXVK_DESCRIBE#" version.h.in
      ;;
    vkd3d-proton)
      sed -i "s#@VCS_TAG@#$VKD3D_BUILD#" vkd3d_build.h.in
      sed -i "s#@VCS_TAG@#$VKD3D_DESCRIBE#" vkd3d_version.h.in
      ;;
  esac
}

build() {
  mkdir -p "$OUT"
  write_versions
  cross_file i386 i686-w64-mingw32 x86 "$i386_flags $cflags" ""
  cross_file arm64ec arm64ec-w64-mingw32 aarch64 "$arm64ec_flags $cflags" ""
  local arch pe
  for arch in i386 arm64ec; do
    pe=i386-windows
    [ "$arch" = arm64ec ] && pe=aarch64-windows
    meson setup "$OUT/$arch" "$SRC" \
      --prefix="$D3D_PREFIX" \
      --bindir="lib/wine/$project/$pe" \
      --libdir="lib/wine/$project/$pe" \
      --buildtype=plain \
      --cross-file="$OUT/cross-$arch.txt" \
      --strip
    ninja -C "$OUT/$arch" -j"$JOBS"
  done
}

install_tree() {
  : "${INSTALL_ROOT:?}"
  local arch
  for arch in i386 arm64ec; do
    DESTDIR="$INSTALL_ROOT" meson install -C "$OUT/$arch" --no-rebuild
  done

  local root="$INSTALL_ROOT$D3D_PREFIX" dir="lib/wine/$project" f format
  case "$project" in
    dxvk) printf 'DXVK_VERSION=%s\nDXVK_COMMIT=%s\n' "$DXVK_DESCRIBE" "$DXVK_COMMIT" ;;
    vkd3d-proton) printf 'VKD3D_VERSION=%s\nVKD3D_COMMIT=%s\n' "$VKD3D_DESCRIBE" "$VKD3D_COMMIT" ;;
  esac > "$root/amphora-$project.env"
  # Only the DLLs go into the runtime.
  find "$root/$dir" -type f ! -name '*.dll' -delete
  find "$root" -mindepth 1 -maxdepth 1 ! -name lib ! -name "amphora-$project.env" -exec rm -rf {} +
  for f in "${dlls[@]}"; do
    test -f "$root/$dir/i386-windows/$f.dll" || { echo "missing: $dir/i386-windows/$f.dll" >&2; exit 1; }
    test -f "$root/$dir/aarch64-windows/$f.dll" || { echo "missing: $dir/aarch64-windows/$f.dll" >&2; exit 1; }
    format="$(llvm-objdump -h "$root/$dir/aarch64-windows/$f.dll" | sed -n 's/.*file format //p')"
    [ "$format" = coff-arm64ec ] || { echo "$dir/aarch64-windows/$f.dll is $format, not ARM64EC" >&2; exit 1; }
    format="$(llvm-objdump -h "$root/$dir/i386-windows/$f.dll" | sed -n 's/.*file format //p')"
    [ "$format" = coff-i386 ] || { echo "$dir/i386-windows/$f.dll is $format, not i386" >&2; exit 1; }
  done
  # The version the element names must be the one that was built. DXVK logs its
  # version, so it is in the binary; vkd3d-proton only keeps the build number
  # (its shader cache is keyed on it), so look at the header meson generated.
  case "$project" in
    dxvk) grep -aq "$DXVK_DESCRIBE" "$root/$dir/aarch64-windows/d3d11.dll" ;;
    vkd3d-proton) grep -q "0x$VKD3D_BUILD;" "$OUT/arm64ec/vkd3d_build.h" ;;
  esac || { echo "$project: the version of the element is not the one that was built" >&2; exit 1; }
}

case "${2:-}" in
  build) build ;;
  install) install_tree ;;
  *) echo "usage: $0 dxvk|vkd3d-proton build|install" >&2; exit 2 ;;
esac
