kind: manual

description: |
  Turnip: Mesa 26.3.1's Vulkan driver for Adreno, on the KGSL kernel
  interface Android has, the only GPU driver the runtime uses. Built as an
  Android Vulkan HAL module (libvulkan_freedreno.so, the one export is
  HMI); Wine's Android driver opens it itself instead of the platform's
  libvulkan.so, so nothing sits between Wine and the driver.

  Proton has no Mesa pin (SteamOS ships Mesa); this follows Mesa's latest
  stable release.

  patches/gralloc-fallback-qcom-ubwc-without-gmsm.patch: Qualcomm's current
  gralloc no longer writes the 'gmsm' magic the fallback gralloc reader
  looks for, so the UBWC flag of an imported AHardwareBuffer was never
  read and the swapchain's buffers got the wrong layout. Carried from
  WinNative-Emu/Drivers (fix_gralloc_flushall.py); not upstream.

  The artifact is /opt/turnip/lib/libvulkan_freedreno.so, unstripped.

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: mesa/glslang.bst
  type: build

sources:
- kind: tar
  url: mesa:mesa-26.3.1.tar.xz
  ref: 4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961
- kind: patch
  path: elements/mesa/patches/gralloc-fallback-qcom-ubwc-without-gmsm.patch
# Again as files: their hash goes into the runtime's name (scripts/runtime.sh).
- kind: local
  path: elements/mesa/patches
  directory: .bst/patches
- kind: local
  path: scripts/turnip.sh
  directory: .bst/scripts

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  TURNIP_PREFIX: /opt/turnip
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"
  # Checked against the source's VERSION file.
  MESA_VERSION: 26.3.1

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/turnip.sh build
  install-commands:
  - bash .bst/scripts/turnip.sh install
  strip-commands: []
