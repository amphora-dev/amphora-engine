kind: manual

description: |
  glslang 16.5.0, built for the build machine: Mesa compiles Turnip's
  ray tracing (BVH) shaders with it and needs 12.2 or later. The glslang
  Proton's tag pins (tools/glslang.bst, for DXVK and vkd3d-proton) is older
  than that.

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build

sources:
- kind: git
  url: github:KhronosGroup/glslang.git
  track: "16.5.0"
  ref: a8d28bd082bff18ffbe80996e922b012f915cf07
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
    # ENABLE_OPT needs SPIRV-Tools; Mesa's shaders are compiled without it.
    cmake -S . -B _build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/glslang \
      -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build _build -j"$JOBS"
  install-commands:
  - |
    set -eu
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    DESTDIR="%{install-root}" cmake --install _build --strip
    # Only the compiler is used.
    rm -rf "%{install-root}/opt/glslang/include" "%{install-root}/opt/glslang/lib"
    "%{install-root}/opt/glslang/bin/glslangValidator" --version
  strip-commands: []
