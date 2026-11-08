# amphora-engine

Amphora 引擎设备端运行时的构建项目：从源码构建 Wine（Valve Proton Experimental + 我们的补丁）和它在 Android 上要的原生库，打成 SDK 安装的 runtime 归档。只用 BuildStream 构建。

设计和进度在 [`amphora-dev/amphora`](https://github.com/amphora-dev/amphora)（本地 `~/co/github/amphora-steam`）：决策见其 `docs/research/12-REWRITE-DESIGN.md`，进度见 `docs/TRACKING.md`。旧产品（x86_64 Wine + Box64、imagefs rootfs、WCP 发布）的构建留在 [`amphora-dev/imagefs`](https://github.com/amphora-dev/imagefs)，不再开发；从那里搬什么、怎么改，见 [`docs/FROM-IMAGEFS.md`](docs/FROM-IMAGEFS.md)。

## 产物

`runtime.bst` → `/artifacts/`：

- `amphora-wine-<version>-<commit12>.tar.gz`：设备上的 runtime 根目录，带 `amphora-runtime.json`（SDK 安装器读这个）
- 同名 `.sha256`，以及 `runtime.env`（名字、sha256、大小，给 CI 和 manifest 用）

目标统一：aarch64 Bionic，**API 30**，16 KB 页；Wine 的 PE 侧是 ARM64X（aarch64 + arm64ec）+ i386。

## 元素

```text
runtime.bst                 打包、strip、校验、写 manifest（ci/runtime.sh）
├── wine/wine.bst           Wine 本体（ci/wine.sh），产物是未 strip 的 /opt/wine
│   ├── wine/script.bst     ci/wine.sh（单独成元素，workspace 里也拿得到）
│   ├── wine/host-freetype  构建期工具 sfnt2fon 用的宿主 FreeType
│   ├── libs/freetype.bst   目标 FreeType（Wine 只链它）
│   └── tools/recc.bst      单次编译缓存（docs/CACHE.md）
└── libs/freetype.bst
buildstream-sdk.bst         junction：宿主 SDK、NDK r29、llvm-mingw、meson profile
```

新库放 `libs/`，按里程碑加，跟着第一个用到它的元素进来（`project.conf` 的 alias 也一样）。

## 本地构建

需要 x86_64 Linux（宿主 SDK 是 Ubuntu Noble amd64）。Mac 上用 OrbStack 的 amd64 机器 `bst-amd64`，仓库目录直接挂进去。

```bash
sudo apt-get install bubblewrap fuse3 git lzip patch python3-venv xz-utils
bash ci/setup/install-buildstream.sh

./bst build runtime.bst
./bst artifact checkout runtime.bst --directory out/runtime
```

**没推送的提交**：Wine 分支和 SDK 分支在推到 GitHub 之前，用本地镜像或 workspace 构建。`~/.config/buildstream.conf`：

```yaml
projects:
  amphora-engine:
    mirrors:
    - name: local
      aliases:
        amphora:
        - file:///Users/sky/.cache/amphora-mirrors/
    default-mirror: local
```

Wine 源码平时开 workspace（改 `.c` 走增量构建）：

```bash
./bst workspace open --no-checkout --directory ~/co/github/wine-ws wine/wine.bst
```

## 缓存

三层：元素产物（CAS）、workspace 构建树、单次编译（recc，经沙箱里的 `remote-apis-socket` 进同一个 CAS / action cache）。共享远程缓存：`BST_REMOTE_CACHE_TOKEN=... bash ci/setup/configure-remote-cache.sh`。细节和数字见 [`docs/CACHE.md`](docs/CACHE.md)。

## 约定

- 元素里的 `*-commands` 由 `sh -c -e` 跑，SDK 的 `/bin/sh` 是 dash：inline 只写 POSIX sh，长逻辑放 `ci/*.sh`。`ci/lint/check-bst-inline-sh.py` 检查。
- API 水位只在 `project.conf` 的 `target-triple` 写一次，Wine 和 manifest 的 minSdk 都从它来；Wine commit 写在两处（BuildStream 不保留 `.git`），由 `ci/lint/check-pins.py` 对齐。
- 不在 BuildStream 外维护平行的构建配方、共享 staging 或完成标记；ccache 这类沙箱外缓存也不用，单次编译缓存走 recc + CAS。
