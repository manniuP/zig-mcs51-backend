# ZLS 与 VSCode 配置

> 目标：在 `zig-0.17` 仓库内获得完整的 Zig 语言服务：
> 补全、跳转、悬停、引用、重命名、语义高亮、inlay hints、格式化、诊断。
> 本文只描述仓库内配置；ZLS 二进制不入库。

---

## 1. 版本匹配

| 组件 | 版本 |
|---|---|
| 本仓库 Zig 源码 | 0.17.1 |
| 系统 Zig | 0.17.0 |
| ZLS | **0.17.0 release** |
| VSCode 扩展 | `ziglang.vscode-zig` |

**不要用 ZLS 的 `master`/dev 源码配合 Zig 0.17.0 release 构建。**
ZLS dev 分支要求 `0.17.0-dev.1936+`，而 release 版 0.17.0 的版本比较更小，
会直接触发 `build.zig` 的最低版本错误。

---

## 2. 安装 ZLS

推荐直接使用官方 0.17.0 release：

```text
https://github.com/zigtools/zls/releases/download/0.17.0/zls-x86_64-windows.zip
```

解压后把 `zls.exe` 放到 PATH 中的目录，例如：

```text
%USERPROFILE%\.local\bin\zls.exe
```

验证：

```bash
zls --version
zig version
```

两者都应输出 0.17.x。若 `zls` 不在 PATH，修改 `.vscode/settings.json` 的
`zig.zls.path` 为实际路径；不要把本机绝对路径提交到仓库。

---

## 3. 仓库内配置

### `.zigversion`

固定语言版本，避免 VSCode 扩展自动选择不匹配的 Zig：

```text
0.17.0
```

### `.vscode/settings.json`

- `zig.path = "zig"`：使用 PATH 中的 0.17 编译器；
- `zig.zls.enabled = "on"`；
- `zig.zls.path = "zls"`：在 PATH 中查找；
- `zig.formattingProvider = "zls"`；
- `zig.buildOnSaveProvider = "off"`：本仓库的 `build.zig` 会构建整个编译器，
  不适合每次保存都跑；
- Zig 文件保存时格式化、4 空格、LF；
- 排除 `.zig-cache`、`zig-out`、`.tools`、`build-*` 的搜索与监听。

### `zls.json`

项目级 ZLS 配置：

- `zig_lib_path = "lib"`：使用本仓库的 std/目标定义；
- `enable_build_on_save = false`；
- `semantic_tokens = "full"`；
- 变量类型、参数名、结构体字面量字段的 inlay hints 全开；
- 全局变量声明高亮、风格警告开启。

---

## 4. 打开与验证

1. VSCode 打开 `zig-0.17` 根目录（不是工作区根目录）。
2. 安装推荐扩展 `ziglang.vscode-zig`。
3. 打开任意 `.zig` 文件，等待状态栏出现 ZLS。
4. 检查：
   - 悬停 `std.Target.Cpu.Arch.mcs51` 能显示定义；
   - `grep` 任意函数可跳转；
   - 保存时自动格式化；
   - `Ctrl+Shift+B` 或“终端 → 运行任务”可执行仓库任务。

仓库任务：

| 任务 | 作用 |
|---|---|
| `Zig: 目标层探针` | 验证 `mcs51/mcs251` 目标与地址空间 |
| `Zig: mcs2 MIR → ihx/hex` | 跑 `tools/mcs2/verify.py` |
| `Zig: 类型检查 std` | 用本仓库 `lib` 编译 std |
| `Zig: 格式化 src/tools` | `zig fmt` |

---

## 5. 已知边界

- **ZLS 按宿主目标分析，不会自动按 `-target mcs51` 做目标特定检查。**
  目标常量、指针宽度、地址空间用仓库探针与构建任务验证，不要只依赖编辑器。
- **MCS 后端尚未接入 `src/target.zig` 的 `stage2_mcs2`。**
  因此 ZLS 能理解目标定义，但 `zig build-obj -target mcs51` 还不能出码；
  这是编译器工程进度，不是 ZLS 配置问题。
- **`.tools/` 被忽略**：不要把 ZLS 二进制放进仓库提交。
- **`buildOnSave` 关闭**：本仓库构建编译器很重；需要构建诊断时手动跑任务，
  或临时打开 `zig.buildOnSaveProvider`，用完再关。

---

## 6. 常见问题

### `zls` 找不到

- 确认 `where zls` 能找到；
- 或者在 `.vscode/settings.json` 中把 `zig.zls.path` 指向 `zls.exe` 的绝对路径；
- 重载窗口（`Developer: Reload Window`）。

### ZLS 版本不匹配

- `zls --version` 与 `zig version` 主次版本必须一致；
- 不要用 dev 版 ZLS 配 release 版 Zig，反之亦然；
- 本仓库固定 ZLS 0.17.0 release。

### 补全/跳转失效

- 确认打开的是仓库根目录，`build.zig` 在根；
- 删除 `.zig-cache/zls` 后重载；
- 检查 `zls.json` 的 `zig_lib_path` 是否为 `lib`。
