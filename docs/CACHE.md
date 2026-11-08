# 缓存

Wine 是这里唯一编译时间长的元素：在 OrbStack amd64（Rosetta）上全量编译约 30 分钟，约 1.2 万次编译调用。缓存分三层，都在 BuildStream 的 CAS 里，不用沙箱外的 ccache。

| 层 | 什么时候命中 | 代价 |
|---|---|---|
| 元素产物 | 元素和它所有依赖的输入都没变 | 秒级；只重做下游，例如只改 `ci/runtime.sh` 时重打包约 3 分钟 |
| workspace 构建树 | 在 workspace 里改普通 `.c` | 约 5 分钟；`ci/wine.sh` 只在 configure 的输入变了才重新 configure |
| 单次编译（recc） | 换 Wine ref、改 `configure.ac`、换分支：元素 key 变了，但大部分 `.o` 的输入没变 | 每次编译查一次 action cache |

## recc 怎么接的

- `wine/wine.bst` 声明 `sandbox: remote-apis-socket`，buildbox-casd 在沙箱里的 `/tmp/reapi.sock` 提供 CAS 和 action cache；`action-cache-enable-update: True` 允许写入。
- `RECC_CACHE_ONLY=1`：不做远程执行，没命中就本地编译，再把结果上传（`RECC_CACHE_UPLOAD_LOCAL_BUILD=1`）。
- 本地落在 `~/.cache/buildstream/actioncache/objects/`（按 Action digest 存 `ActionResult`）和 `cas/objects/`（Action 本身和输出的 `.o`）。

## 两级缓存

元素产物和源码只走远程（Phoenix，`https://cas.arm.512.pub`）。recc 的 action cache 分两级：

| | 放什么 | 在哪 | 谁用 |
|---|---|---|---|
| 本机 | 全部 | `~/.cache/buildstream` | 构建本身 |
| L1 | action 结果 + 它们引用的 blob，最新的 4 GiB | GitHub Actions cache（`recc-v2-linux-*`，保留最新两份） | CI |
| L2 | 同上，不限 | Phoenix 的 action cache + CAS | 开发机、没有 L1 的 CI |

BuildStream 2.7 不能让 casd 先查本地、未命中再查远程：配了 `remote-execution.action-cache-service`，每次命中都要过一次 WAN（imagefs 时期在美东 runner 上量过，Wine 全命中 13:28，本地快照 6:31）。所以两级在 workflow 里接：

```text
wine/wine.bst 产物在 Phoenix？  是 → 拉产物，不碰 recc
L1 快照在？  是 → recc-cache.sh import，action cache 用 local 模式（命中不出本机）
             否 → remote 模式，casd 把 action cache 代理到 Phoenix（L2 当种子）
构建
local 模式下有新编译的结果 → recc-cache.sh push 写回 L2
main 上编过 Wine → recc-cache.sh export，存新快照
```

快照不再是整个 `cas/`：`export` 只挑 action 结果和它们指向的 blob（硬链接，不额外占盘）。开发机上 CAS 有 18 GB，其中 recc 只占 1.9 GiB（两条 Wine 线，约 1.6 万条），gzip 后约 0.7 GB。SDK、源码、元素产物、构建树都不进快照。

`ci/cache/recc-cache.sh`（用 BuildStream venv 的 python 跑 `recc-cache.py`）：

```bash
bash ci/cache/recc-cache.sh export DIR [--budget GiB]   # 最新的条目 + blob 硬链接到 DIR
bash ci/cache/recc-cache.sh import DIR                  # 链回本地 cache
bash ci/cache/recc-cache.sh push                        # 把 L2 还没有的条目传上去
bash ci/cache/recc-cache.sh check --limit 200           # 抽查 L2 有没有本地的条目
```

`~/.cache/amphora-recc-known.txt` 记已经在 L2 的条目（导入的快照条目、push 过的），`push` 跳过它们。

开发机：action cache 用 local 模式（本机磁盘就是第一级），元素产物和源码走 Phoenix。新机器第一次用 remote 模式编一遍，之后切回 local。`configure-remote-cache.sh` 只改 `artifacts`、`source-caches`、`cache.storage-service`、`remote-execution` 这几项，镜像和调度设置不动：

```bash
BST_REMOTE_CACHE_TOKEN=... BST_ACTION_CACHE_MODE=local bash ci/setup/configure-remote-cache.sh
# 之后 token 存在 ~/.config/bst-remote-cache.token（0600），再跑不用带
```

## 正确性

action 的 key 必须包含所有会影响 `.o` 的输入，否则会拿旧的目标文件：

- **绝对路径下的头文件**：`RECC_DEPS_GLOBAL_PATHS=1`，NDK sysroot 和 `/opt/android-sysroot` 里的头文件也算进 key，换库版本不会复用旧对象。
- **编译器本身**：recc 不哈希编译器二进制。`ci/wine.sh` 把宿主 gcc、NDK clang、llvm-mingw clang 的 sha256 合起来写进平台属性 `RECC_REMOTE_PLATFORM_toolchain`，换工具链就整体冷启动一次。
- **目标三元组**：unix 侧 `CC` 调真正的 `clang --target=aarch64-linux-android30`（recc 按文件名认编译器，不认 NDK 的 `aarch64-linux-android30-clang` 包装脚本）；`--target` 写在 `CC` 里，因为 Wine 链接时只用 `$(CC) $(LDFLAGS)`。
- **PE 侧**：Wine 直接从 PATH 调 llvm-mingw 的 `clang`，`ci/wine.sh` 只给这两个入口放 recc 包装脚本。

## 不缓存的部分

imagefs 时期在 x86_64 Wine 上量过（`imagefs/docs/WINE-RECC-CACHE.md`，有 CI 运行记录）：链接、`.spec.s` 汇编、configure 探测这些 recc 不缓存的调用加起来只占约 30 秒，缓存链接或汇编得不偿失。全部命中时剩下的大头是 make 本身在每次查缓存前做的依赖扫描。

## 构建日志里看命中

`wine.sh` 结束时打印：

```text
recc actions: hit=… miss=… updated=… not_compiler=…
```

`miss` 是本地编译的次数，`updated` 是新写进 action cache 的结果，`not_compiler` 是有意直接执行的调用（链接、汇编、configure 探测）。
