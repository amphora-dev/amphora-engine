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
- 本地是 `~/.cache/buildstream/{cas,actioncache}`；配了远程缓存（`ci/setup/configure-remote-cache.sh`）时同一个服务器也存 action 结果。

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
