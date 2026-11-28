kind: meson

description: |
  Static libdrm 2.4.134 for Android aarch64 (API 30). Mesa's llvmpipe /
  Lavapipe gates PIPE_CAP_DMABUF (and thus AHardwareBuffer import) on
  HAVE_LIBDRM, so we build a minimal static libdrm with no hardware drivers
  and link it into libvulkan_lvp.so without adding a runtime libdrm.so.2
  dependency.

depends:
- filename: profiles/android-cross-files.bst
  junction: buildstream-sdk.bst
  type: build
  config:
    location: /opt/amphora-sdk/profiles
- filename: sdk/toolchain.bst
  type: build

sources:
- kind: tar
  url: dri:libdrm/libdrm-2.4.134.tar.xz
  ref: ac5e74d157830eb8bee44c6a6bf3ad49774ef0dd2a72bdad74a8f20308b52a95

variables:
  meson-local: >-
    -Ddefault_library=static
    -Dintel=disabled
    -Dradeon=disabled
    -Damdgpu=disabled
    -Dnouveau=disabled
    -Dvmwgfx=disabled
    -Domap=disabled
    -Dexynos=disabled
    -Dfreedreno=disabled
    -Dtegra=disabled
    -Dvc4=disabled
    -Detnaviv=disabled
    -Dcairo-tests=disabled
    -Dman-pages=disabled
    -Dvalgrind=disabled
    -Dtests=false
    -Dudev=false
    -Dinstall-test-programs=false

config:
  strip-commands: []
