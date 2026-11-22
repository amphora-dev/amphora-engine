kind: manual

description: |
  glslang at the commit Proton's tag experimental-11.0-20261027b pins
  (submodule glslang, df7fec2), built for the build machine. DXVK,
  vkd3d-proton and Turnip compile their GLSL shaders with it.

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build

sources:
- kind: git
  url: github:KhronosGroup/glslang.git
  track: main
  ref: df7fec2cfa966919172ee83bfcae6c9c9b3f91b8
  checkout-submodules: false

environment:
  JOBS: "%{max-jobs}"
environment-nocache:
- JOBS

config:
  build-commands:
  - |
    set -eu
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin CC=/usr/bin/gcc CXX=/usr/bin/g++
    unset AR RANLIB NM STRIP
    # ENABLE_OPT needs SPIRV-Tools, which Proton's build does not have either.
    cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/glslang \
      -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build _build -j"$JOBS"
  install-commands:
  - |
    set -eu
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    DESTDIR="%{install-root}" cmake --install _build --strip
    # Only the compiler is used; this glslang still calls it glslangValidator.
    rm -rf "%{install-root}/opt/glslang/include" "%{install-root}/opt/glslang/lib"
    "%{install-root}/opt/glslang/bin/glslangValidator" --version
  strip-commands: []
