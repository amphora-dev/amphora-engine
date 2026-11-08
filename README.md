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
runtime.bst                 打包、strip、校验、写 manifest（scripts/runtime.sh）
├── wine/wine.bst           Wine 本体（scripts/wine.sh），产物是未 strip 的 /opt/wine
│   ├── wine/script.bst     scripts/wine.sh（单独成元素）
│   ├── wine/host-freetype  构建期工具 sfnt2fon 用的宿主 FreeType
│   ├── libs/freetype.bst   目标 FreeType（Wine 只链它）
│   └── tools/ccache.bst    ccache 和 ccache-cas：单次编译缓存（docs/CACHE.md）
├── libs/freetype.bst
└── sdk/toolchain.bst       stack：宿主 SDK + NDK r29 + llvm-mingw（换版本只改这里）
buildstream-sdk.bst         junction：上面三样和 meson profile
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

**没推送的提交**：Wine 分支和 SDK 分支在推到 GitHub 之前，用本地镜像构建。`~/.config/buildstream.conf`：

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

改 Wine 源码用 `dev/wine.sh`，不用 BuildStream workspace（workspace 每次都要把整棵构建树重新存进 CAS，慢）：

```bash
dev/wine.sh build     # 在 wine.bst 自己的构建沙箱里增量编译；源码默认是旁边的 ../wine-arm64ec（WINE_SRC 可改）
dev/wine.sh mark      # 记下时间点
dev/wine.sh changed   # 列出之后变了的、要推到设备上的文件
```

它把 `WINE_SRC` 同步到 `~/.cache/amphora-dev/wine/src`，构建树在旁边的 `build/`，ccache 目录在 `ccache/`；每次构建前先并入最近一次 `bst build` 存下的 ccache（同一份只并一次），所以第一次也几乎全部命中。之后改一个 `.c` 约 10 秒。要先 `./bst build runtime.bst` 一次（或 `ci/cache/pull-ci.sh`），让 wine.bst 的构建依赖都在缓存里。

## 缓存

都在 BuildStream 的本地缓存里：元素产物，和 Wine 的 ccache 目录（整个目录打成一个 tar，经沙箱里的 `remote-apis-socket` 存进 CAS）。没有远程缓存服务器。CI 把本项目的元素产物和这份 ccache 存成 GitHub Actions cache 快照，下一次运行导入；SDK 不进快照，要用时重新下载。细节和数字见 [`docs/CACHE.md`](docs/CACHE.md)。

## 约定

- 元素里的 `*-commands` 由 `sh -c -e` 跑，SDK 的 `/bin/sh` 是 dash：inline 只写 POSIX sh，长逻辑放 `scripts/*.sh`（沙箱里跑的构建脚本；`ci/` 只放宿主上跑的 CI 工具）。`ci/lint/check-bst-inline-sh.py` 检查。
- API 水位只在 `project.conf` 的 `target-triple` 写一次，Wine 和 manifest 的 minSdk 都从它来；Wine commit 写在两处（BuildStream 不保留 `.git`），由 `ci/lint/check-pins.py` 对齐。
- 不在 BuildStream 外维护平行的构建配方、共享 staging 或完成标记。ccache 只在沙箱里用，它的目录也存在 BuildStream 的 CAS 里，不挂沙箱外的目录（`dev/wine.sh` 除外，它本来就不是发布路径）。
