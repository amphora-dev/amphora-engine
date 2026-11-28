kind: manual

description: |
  Experimental Lavapipe: Mesa 26.3.1's software Vulkan driver (llvmpipe +
  lavapipe) built as an Android aarch64 Vulkan HAL module (libvulkan_lvp.so
  and vulkan.lvp.so, exporting HMI) with static LLVM 20.1.8 and static
  libdrm. Not part of runtime.bst (Amphora's release runtime uses Turnip
  only, D4).

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: mesa/glslang.bst
  type: build
- filename: libs/llvm.bst
  type: build
- filename: libs/libdrm.bst
  type: build
  config:
    location: /opt/android-sysroot

sources:
- kind: tar
  url: mesa:mesa-26.3.1.tar.xz
  ref: 4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961
- kind: patch
  path: elements/mesa/patches-lvp/lavapipe-anb-alias-layout.patch
- kind: local
  path: scripts/lavapipe.sh
  directory: .bst/scripts

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LVP_PREFIX: /opt/lavapipe
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"
  MESA_VERSION: 26.3.1

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/lavapipe.sh build
  install-commands:
  - bash .bst/scripts/lavapipe.sh install
  strip-commands: []
