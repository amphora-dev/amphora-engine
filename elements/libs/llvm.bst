kind: manual

description: |
  Static LLVM 20.1.8 (AArch64 target only) for Android aarch64 (API 30),
  used to build Mesa Lavapipe (software Vulkan JIT). Installs target static
  libraries, headers and a host-runnable target-aware llvm-config wrapper
  under /opt/android-llvm.

depends:
- filename: sdk/toolchain.bst
  type: build

sources:
- kind: tar
  url: llvm:llvmorg-20.1.8/llvm-20.1.8.src.tar.xz
  ref: e1363888216b455184dbb8a74a347bf5612f56a3f982369e1cba6c7e0726cde1
  directory: llvm
- kind: tar
  url: llvm:llvmorg-20.1.8/cmake-20.1.8.src.tar.xz
  ref: 3319203cfd1172bbac50f06fa68e318af84dcb5d65353310c0586354069d6634
  directory: cmake
- kind: tar
  url: llvm:llvmorg-20.1.8/third-party-20.1.8.src.tar.xz
  ref: 9a4e452a8163732d417db067a89190fcda823cb3aa33199e834ac7c028923f4b
  directory: third-party
- kind: local
  path: scripts/llvm.sh
  directory: .bst/scripts

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LLVM_PREFIX: /opt/android-llvm
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/llvm.sh build
  install-commands:
  - bash .bst/scripts/llvm.sh install
  strip-commands: []
