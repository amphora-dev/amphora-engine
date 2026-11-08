# 缓存

Wine 是这里唯一编译时间长的元素：约 1.2 万次编译调用，冷编时 Wine 元素在 GitHub runner 上 26:12，在 OrbStack amd64 上 40:01。所有缓存都在 BuildStream 自己的本地缓存（`~/.cache/buildstream`）里，不用沙箱外的 ccache，也没有远程缓存服务器。

| 缓存什么 | 什么时候命中 | 代价 |
|---|---|---|
| 元素产物 | 元素和它所有依赖的输入都没变 | 秒级；只重做下游，例如只改 `scripts/runtime.sh` 时只重新打包 |
| workspace 构建树（开发机） | 在 workspace 里改普通 `.c` | 约 5 分钟；`scripts/wine.sh` 只在 configure 的输入变了才重新 configure |
| 单次编译（recc） | 换 Wine ref、改 `configure.ac`、换分支：元素 key 变了，但大部分 `.o` 的输入没变 | 全部命中时 Wine 元素 7:06（GitHub runner），15:16（OrbStack） |

开发机靠本机磁盘就够了。CI 的 runner 每次都是空的，所以要把本地缓存的一部分带到下一次运行，见下面的“CI 快照”。

## recc 怎么接的

- `wine/wine.bst` 声明 `sandbox: remote-apis-socket`，buildbox-casd 在沙箱里的 `/tmp/reapi.sock` 提供 CAS 和 action cache；`action-cache-enable-update: True` 允许写入。
- `RECC_CACHE_ONLY=1`：不做远程执行，没命中就本地编译，再把结果上传（`RECC_CACHE_UPLOAD_LOCAL_BUILD=1`）。
- 本地落在 `~/.cache/buildstream/actioncache/objects/`（按 Action digest 存 `ActionResult`）和 `cas/objects/`（Action 本身和输出的 `.o`）。

## CI 快照

BuildStream 的设计是：每个元素的产物都进本地 CAS，按输入算出的 key 查找；源码按 `ref` 里的 sha256 校验。所以缓存只影响快慢，不影响结果，丢了就从源码重建。CI 上只带走重建起来贵的东西：

| 进快照 | 不进快照 |
|---|---|
| 本项目元素在当前 key 下构建成功的产物（Wine 约 2 GiB、freetype、recc、runtime） | SDK junction 的产物：宿主 SDK、NDK、llvm-mingw（约 3.4 GiB）。要用时 BuildStream 重新下载源码再导入，来源是 Google 和 GitHub Release，都按 sha256 校验 |
| recc 的编译结果和它们引用的 `.o`，最近用过的优先，最多 4 GiB | 源码、构建树；构建失败的产物 |

快照放在 GitHub Actions cache，key 是 `bst-v3-<runtime.bst 的完整 key>`。runtime.bst 的 key 覆盖了整个构建的所有输入，所以：

```text
key 精确命中    → 导入，什么都不用编（runtime 产物已在快照里）
只有前缀命中    → 导入最新一份，编变了的部分；Wine 的大部分编译命中 recc
都没有          → 冷编
main 上没精确命中 → 构建后导出并保存新快照（构建失败也存，key 加 -failed-<run>，
                    已经编好的 .o 下次还能用）；旧的删掉，只留最新一份
```

- 只有 main 写快照；PR 和其他分支能读 main 的，不写。
- 构建失败的产物不进快照：BuildStream 也缓存失败的构建，带过去的话，同一个 key 重跑会直接报失败，不再重试。
- “最近用过”看输出 `.o` 的 mtime：casd 每次读 CAS 里的 blob 都会更新它的 mtime，action cache 文件写入后就不再动。Wine 编译一次后，没被这次用到的旧结果排在后面，超出预算时先丢它们。
- GitHub 每个仓库的 cache 上限 10 GB，7 天没被访问就淘汰。workflow 每周一、四定时跑一次：输入没变时精确命中、什么都不编，只为了让快照保持被访问。
- 开发机读不到 Actions cache（GitHub 没有下载接口）。要用 CI 的构建，就让 CI 把快照另外传成 workflow artifact（`bst-cache`，约 1 GB，保留 7 天），只在要的时候传：手动跑 `gh workflow run build.yml -f upload-cache=true`，或者提交信息里写 `[upload-cache]`。本地用 `bash ci/cache/pull-ci.sh` 下载并导入（Mac 上：`GH_TOKEN=$(gh auth token) orb -m bst-amd64 bash ci/cache/pull-ci.sh`）。输入和 CI 那次一样时 `runtime.bst` 直接是已缓存；不一样时，没变的编译命中 recc。

实测（2026-11-08，ubuntu-24.04 runner）：

| 情况 | 整个 job | `bst build` | 其中 |
|---|---|---|---|
| 冷编（没有快照） | 31:35 | 29:49 | Wine 26:12，Wine 源码 clone 约 2 分钟，SDK 下载加导入约 1 分钟，打包 1:24 |
| 精确命中 | 1:53 | 1 秒 | 恢复快照 29 秒，导入 2 秒 |
| 只改 Wine 的 key（recc 全部命中） | 11:56 | 10:29 | Wine 7:06，Wine 源码 clone 1:46，SDK 约 1 分钟，打包 1:30 |

快照压缩后 1.02 GiB（产物 2.22 GiB + recc 1.59 GiB），导出 6 秒，保存 18 秒。

`ci/cache/snapshot.sh`（用 BuildStream venv 的 python 跑 `snapshot.py`）：

```bash
bash ci/cache/snapshot.sh export DIR [--target runtime.bst] [--recc-budget GiB]  # 硬链接到 DIR
bash ci/cache/snapshot.sh import DIR                                            # 链回本地缓存
```

## 正确性

action 的 key 必须包含所有会影响 `.o` 的输入，否则会拿旧的目标文件：

- **绝对路径下的头文件**：`RECC_DEPS_GLOBAL_PATHS=1`，NDK sysroot 和 `/opt/android-sysroot` 里的头文件也算进 key，换库版本不会复用旧对象。
- **编译器本身**：recc 不哈希编译器二进制。`scripts/wine.sh` 把宿主 gcc、NDK clang、llvm-mingw clang 的 sha256 合起来写进平台属性 `RECC_REMOTE_PLATFORM_toolchain`，换工具链就整体冷启动一次。
- **目标三元组**：unix 侧 `CC` 调真正的 `clang --target=aarch64-linux-android30`（recc 按文件名认编译器，不认 NDK 的 `aarch64-linux-android30-clang` 包装脚本）；`--target` 写在 `CC` 里，因为 Wine 链接时只用 `$(CC) $(LDFLAGS)`。
- **PE 侧**：Wine 直接从 PATH 调 llvm-mingw 的 `clang`，`scripts/wine.sh` 只给这两个入口放 recc 包装脚本。

## 不缓存的部分

imagefs 时期在 x86_64 Wine 上量过（`imagefs/docs/WINE-RECC-CACHE.md`，有 CI 运行记录）：链接、`.spec.s` 汇编、configure 探测这些 recc 不缓存的调用加起来只占约 30 秒，缓存链接或汇编得不偿失。

全部命中时 Wine 元素仍要 7 分钟（GitHub runner；OrbStack 上 15 分钟）。时间多半花在 recc 每次命中的固定开销上（先跑一遍预处理算依赖、哈希输入、查 casd，1.2 万次），其次是 make 本身和 configure；还没细拆。

## 构建日志里看命中

`wine.sh` 结束时打印：

```text
recc actions: hit=… miss=… updated=… not_compiler=…
```

`miss` 是本地编译的次数，`updated` 是新写进 action cache 的结果，`not_compiler` 是有意直接执行的调用（链接、汇编、configure 探测）。
