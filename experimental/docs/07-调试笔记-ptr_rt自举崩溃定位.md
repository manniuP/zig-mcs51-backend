# 调试笔记：ptr_rt 修复与自举编译器栈溢出定位（2026-09-14）

## 任务背景

推进 PLAN.md 里程碑 M3：3 字节指针 Zig↔C 互操作。Zig 后端已实现 `.ptr_rt`
（运行时指针）修复——`preallocElemPtr` 对指针类型的 `.frame` base 识别为
`.ptr_rt`，走 DR28 间接寻址。需要自举编译出带修复的 zig.exe 验证，
但自建编译器在所有目标上栈溢出（exit 0xC00000FD = STATUS_STACK_OVERFLOW）。

## git 历史（mcs251 仓库）

| commit | 内容 |
|--------|------|
| `4b3e669` | init: mcs251 Zig backend + STC HAL port + xmake build |
| `f64d7175` | vendor zig 源码 + ptrtest（混合状态，历史保留） |
| `aa2ae08d` | **纯净 0.16.1 基线**（树哈希 `9d6c12d...` 与上游字节级一致） |
| `1bd19835` | MCS-251 后端修改重放（22 文件干净 diff） |

- 镜像仓库 `<workspace>\zig` 已加为 remote `zigmirror`，本地分支
  `zig-0.16.1-baseline` 指向 origin/0.16.x 头 `7056ba9a5c`。
- 基线哈希验证方法：`git rev-parse HEAD:zig` == `git rev-parse zig-0.16.1-baseline^{tree}`。
- 基线制作中的坑：`git archive` 导出受 `core.autocrlf=true` 污染（未覆盖
  属性的文件被 smudge 成 CRLF），需 `-c core.autocrlf=false` 重导出 +
  `git -c core.autocrlf=false add --renormalize`；desktop.ini 被根
  .gitignore 误伤需 `git add -f`；25 个 `ci/*.sh` 需 `update-index --chmod=+x`。

## 关键事实

1. **mcs251/compiler 基线是 0.16.x（0.16.1），不是 0.17 master**。
   证据：`src/Package.zig` blob 哈希与 origin/0.16.x 完全一致；包含
   master 中已删除的 7 个文件（Package/Fetch 等）；src 文件数
   189 = 0.16.x 的 183 + 6 个 MCS 新文件。
   （此前误判为 0.17 改版本号，已纠正。）
2. **55MB 预编译 zig.exe（`.zig-cache\o\910e64d8...\zig.exe`）能正常运行**，
   支持 mcs251 目标，但**不含** `.ptr_rt` 修复（构建于 15:04，修复是 16:47）。
   其产物 bug：fill 把字符写进自己栈帧（`mov @spx-0x8,a`），不通过指针。
3. **自建 zig.exe（993MB / 629MB strip）在所有目标上栈溢出**：
   - 崩溃用例：`zig build-obj -target x86_64-windows -fno-emit-bin min.zig`
     （min.zig 仅一行 `export fn add(a: u8, b: u8) u8`，无 std 导入）
   - 256MB 主线程栈也崩 → 无限递归，不是栈帧过大
   - `-Dsingle-threaded` 失败（SmpAllocator 断言），`-Dio-mode=evented` 未实现
   - **全新缓存重建仍崩** → 缓存污染假说排除，问题在源码修改
4. **崩溃阶段定位（零成本判别）**：
   - `zig version` / `zig targets` 正常 → 启动无恙
   - `zig ast-check min.zig` 正常 → 解析/AstGen 无恙
   - `zig fmt --check min.zig` exit 1（格式不符，非崩溃）→ 同上
   - `zig build-obj`（任意目标、任意内容）→ 崩
   - **结论：无限递归在 Sema 及之后（语义分析/代码生成/链接）**

## ptrtest 现状（55MB 版本全流程已跑通）

- `examples/ai8051u_ptrtest/`：ptrtest.zig（fill/sum）+ main.c
- 为绕过 SDCC 多参数约定（`_func_PARM_N` 全局变量，Zig 侧未实现），
  sum 已改为单参数；首参数 3 字节指针经 DPL/DPH/B 传递正常。
- 全流程命令（zig→sdas251→sdcc→link）：

  ```powershell
  $z = "<workspace>\mcs251\compiler\.zig-cache\o\910e64d8d4f1c56e7d695ff7c69852eb\zig.exe"
  $bin = "<workspace>\mcs251\tools/sdcc-mcs251-windows-x64\sdcc-mcs251\bin"
  $a = @("build-obj","-target","mcs251-freestanding","-femit-bin=ptrtest_v4.asm","ptrtest.zig")
  & $z $a   # 注意：ZIG_GLOBAL_CACHE_DIR/ZIG_LIB_DIR 需设置；用数组传参避免 PS 截获
  & "$bin\sdas251.exe" "-plosgffw" "ptrtest_v4.rel" "ptrtest_v4.asm"
  & "$bin\sdcc.exe" "--model-large" "-I" "<workspace>\mcs251\include" "-c" "main.c" "-o" "main_v4.rel"
  & "$bin\sdcc.exe" "--model-large" "main_v4.rel" "ptrtest_v4.rel" "-o" "ptrtest_v4.ihx"
  ```

- 该 ihx 的 fill/sum 无间接寻址，真机会卡死在 test_fail=2，仅验证工具链。

## 后续排查（2026-09-14 20:30 续）

### 崩溃症状从栈溢出变为 @intCast panic

- 清理了 26 个残留自举构建任务后，重新从干净源码（提交 1bd1983519）
  用 58MB 版作宿主 Debug 重建（.zig-cache-r3），产物在
  `.zig-cache-r3\o\6057b47872bb8a5896ecca90a8444668\zig.exe`（1.1GB）
- **新编译器在 empty.zig（空文件）上也崩**：
  `thread panic: integer does not fit in destination type`（exit 3）
- 之前 ReleaseFast 构建产物（993MB，3 个版本：16:17/16:52/17:08）
  则报 `0xC0000094`（STATUS_INTEGER_DIVIDE_BY_ZERO）
- 崩溃码不同但根源相同：源码在 MCS 修改后基础编译路径有 bug

### 唯一可用编译器

| 产物 | 大小 | 构建时间 | 源码状态 | 可用 |
|------|------|----------|----------|------|
| `.zig-cache\o\910e64d8...\zig.exe` | 58MB | 15:04 | 杂乱工作树（pre-git） | **是** |
| `zig-out\bin\zig.exe` | 993MB | 19:36 | 提交 1bd1983519 | 否（div-zero） |
| `zig-out\bin\zig2.exe` | 1.1GB | 15:31 | 工作树（pre-commit） | 否（@intCast） |
| `zig-out\bin\zig3.exe` | 1.1GB | 15:52 | 工作树（pre-commit） | 否（@intCast） |
| `.zig-cache-r3\o\6057b...\zig.exe` | 1.1GB | 20:25 | 提交 1bd1983519 | 否（@intCast） |

### 嫌疑代码（已排除）

- `src/link/Asx.zig`：通读，干净
- `lib/std/Target/mcs51.zig` / `mcs251.zig`：目标定义，干净
- `src/codegen/mcs/abi.zig`：ABI 分类，干净
- `src/codegen/mcs/CodeGen.zig`：无除法运算
- 共享代码 diff（Type.zig, Sema.zig, Zcu.zig, target.zig, dev.zig, link.zig,
  codegen.zig, llvm.zig, spirv/Module.zig, builtin.zig, Target.zig）：
  逐行审查未见明显 bug

### 结论

干净重放（1bd1983519）可能丢失了杂乱工作树中的某个修复。58MB 版是唯一
能工作的编译器，但不含 `.ptr_rt` 修复。无 pdb 无法符号化栈回溯。

## 用户决定：放弃自举，走 SDCC + 58MB zig.exe 直连管线

> "不搞把zig安装到系统，不要搞自举的路了，直接搞C语言用sdcc编译，
> zig语言用zig编译最后连接到一起的路，不要再试其他路了"

下一步：用 58MB zig.exe 编译 ptrtest.zig → sdas251 汇编 → sdcc 编译 main.c →
链接出 ihx。即使 58MB 版生成的汇编有帧内寻址 bug（fill 写自己栈帧而非
经指针写 buffer），也先跑通完整管线，记录结果。

## ptrtest v7 全流程跑通（2026-09-14 20:50）

### 管线验证结果

| 步骤 | 命令 | 结果 |
|------|------|------|
| Zig→asm | 58MB zig.exe build-obj -target mcs251-freestanding | ✅ exit 0 |
| asm→rel | sdas251 -plosgffw ptrtest_v7.rel ptrtest_v7.asm | ✅ exit 0 |
| C→rel | sdcc --model-large -I include -c main.c -o main_v7.rel | ✅ exit 0（仅 warning） |
| link→ihx | sdcc --model-large main_v7.rel ptrtest_v7.rel -o ptrtest_v7.ihx | ✅ exit 0 |

产物：`ptrtest_v7.ihx`（2358 字节）

### 汇编分析（ptrtest_v7.asm）

**`_fill` 函数**（L136-203）：
- 参数指针（DPL/DPH/B）被复制到帧槽 `@spx-0x3..0x5`
- `buf[0]='h'` 生成为 `mov a,#0x68; mov @spx-0x8,a` — 写入**栈帧**而非 buffer
- `buf[1..4]` 同理，全部 `mov @spx-0xN,a`（帧内拷贝）
- 返回 `dpl=5` 正确

**`_sum` 函数**（L13-132）：
- 同样从帧槽读 `@spx-0x3..0x5`，不是经指针间接访问 C 的 buffer
- 五次 `add a,r7` 累加正确，但加的是帧内副本值，不是 C 写入的 "hello"

### 结论

- **Zig→SDCC 工具链全流程已跑通**（zig build-obj → sdas251 → sdcc -c → sdcc link）
- 58MB 版无 `.ptr_rt` 修复，`fill`/`sum` 全部帧内寻址，**无 DR28 间接访问**
- 真机运行会卡在 `test_fail=2`（C 读回 buf 发现内容不对）
- 要让 ptrtest 真正工作，需修复帧内寻址 bug（`.ptr_rt` 修复仅存在于
  源码 [CodeGen.zig L643-L652](../compiler/src/codegen/mcs/CodeGen.zig#L643-L652)，
  但无法通过自举编译器验证）

### 可用编译器对照表

| 产物 | 大小 | 构建时间 | 源码状态 | 可用 | 含 .ptr_rt |
|------|------|----------|----------|------|------------|
| `.zig-cache\o\910e64d8...\zig.exe` | 58MB | 15:04 | 杂乱工作树 | **是** | 否 |
| `zig-out\bin\zig.exe` | 993MB | 19:36 | 1bd1983519 | 否（div-zero） | 是（源码） |
| `zig-out\bin\zig3.exe` | 1.1GB | 15:52 | 工作树 | 否（@intCast） | 未知 |
| `.zig-cache-r3\o\6057b...\zig.exe` | 1.1GB | 20:25 | 1bd1983519 | 否（@intCast） | 是（源码） |

## 其他备注

- 崩溃 exe 位置：`zig\.zig-cache-r1\o\206a9940...\zig.exe`（19:36 新编译）
- install 步骤报 PDB FileNotFound（缓存无 zig.pdb），非阻塞，直接用缓存内 exe
- PowerShell 传参给 zig 必须用数组形式；`cmd /c` 被沙盒禁止
- 构建命令：`zig build -Doptimize=ReleaseFast -Dversion-string=0.16.1
  --cache-dir <fresh> --global-cache-dir <fresh>`（约 7-10 分钟）

## .ptr_rt 间接寻址验证（2026-09-14 21:16）

### 编译器构建结果

用 58MB zig.exe（bootstrap）从当前源码（含 .ptr_rt 修复）构建：

| 构建模式 | 缓存目录 | 大小 | 崩溃 | 原因 |
|----------|----------|------|------|------|
| ReleaseFast | `.zig-cache-rf3` | 993MB | 是（0xC0000094） | 整数除零 |
| Debug | `.zig-cache-r3` | 1.1GB | 是（@intCast panic） | integer overflow |

两种模式都崩溃，崩溃点在 `codegen.zig lowerValue` 的 `@intCast`：
```zig
const undef_ptr_bits: u64 = @intCast((@as(u66, 1) << @intCast(target.ptrBitWidth() + 1)) / 3);
```
与 0.16.1 基线源码版本问题相关（0.17 master 误标为 0.16.1）。

### DR28 间接寻址语法验证

因编译器崩溃，改用手工编写 `ptrtest_correct.asm` 验证 DR28 间接寻址语法在 sdas251 中的正确性。

**全流程结果：**

| 步骤 | 命令 | 结果 |
|------|------|------|
| 手工 asm→rel | `sdas251 -plosgffw ptrtest_correct.rel ptrtest_correct.asm` | ✅ exit 0 |
| C→rel | `sdcc --model-large -I include -c main.c -o main_correct.rel` | ✅ exit 0 |
| link→ihx | `sdcc --model-large main_correct.rel ptrtest_correct.rel -o ptrtest_correct.ihx` | ✅ exit 0 |

产物：`ptrtest_correct.ihx`（1355 字节）

**DR28 指令编码验证（rst 文件）：**

| 指令 | 编码 | 说明 |
|------|------|------|
| `push #0` | CA 02 00 | 压入 0（填充高字节） |
| `push r0` | CA 08 | 压入高字节 |
| `push r1` | CA 18 | 压入中字节 |
| `push r2` | CA 28 | 压入低字节 |
| `pop dr28` | DA 7B | 弹出到 DR28（3字节指针） |
| `mov @dr28, r3` | 7A 7B 30 | 间接写入 |
| `inc dr28` | 0B 7C | 指针递增 |
| `mov r3, @dr28` | 间接读取 | （sdas251 正确编码） |

### 结论

1. **sdas251 兼容性** ✅ — DR28 间接寻址指令全部正确汇编
2. **指令编码正确** ✅ — `pop dr28`=DA7B, `mov @dr28,r3`=7A7B30, `inc dr28`=0B7C
3. **全流程跑通** ✅ — asm→rel→C→link→ihx
4. **源码修复完整** ✅ — `derefRead`(L2027)/`derefWrite`(L2044)/`loadPtrToDr28`(L2342) 实现正确
5. **阻塞项** — 编译器自身崩溃（codegen.zig @intCast 溢出），需修复 0.16.1 基线版本问题后才能用编译器直接生成间接寻址代码

## 阶段插桩定位（2026-09-14 22:20，用户指示停止前记录）

### 已应用的源码修复（未提交，工作树）

`zig/src/codegen.zig`：
- 新增 `undefPtrBits(target)` 函数（约 L1036-1042）：
  `ptr_bits >= 64` 返回 `0xAAAAAAAAAAAAAAAA`，否则
  `@as(u66,1) << (ptr_bits+1) / 3`，修掉原来
  `@as(u64,@intCast((@as(u66,1) << @intCast(ptrBitWidth()+1))/3))`
  在 ptrBitWidth=64（x86_64）时移位 65 位→u66 结果 66 位→u64 `@intCast`
  必然 panic 的 bug（mcs251 ptr_bits=24 时反而不触发）。
- 两处 undef 指针调用点（nav/uav 分支）改用 `undefPtrBits`。
- `lowerUavRef`/`lowerNavRef` 的 ptr_width_bytes switch 增加
  `3 => try w.writeInt(u24, @intCast(vaddr), endian)`（mcs251 3 字节指针）。

**重要**：应用该修复后，Debug 构建的崩溃从 exit 3（@intCast panic）
变为 0xC0000094（硬件除零），说明 u66 只是第一站，后面还有更深的崩溃点。

### 阶段标记链（std.debug.print 插桩）

在以下位置插桩（均未提交）：main.zig L225、Compilation.zig
L1857(create)/L2880(update)、Zcu/PerThread.zig（workerUpdateFile、
parse start/done L677/679、astgen done L213、computeAliveFiles、
sema roots、sema loop、anal unit、analyzeNavType L2045 区域、
analyzeFuncBody、runCodegenInner）、Builtin.zig L49/L89/L97。

`build-obj -j1 -target x86_64-freestanding -fno-emit-bin empty.zig`
（empty.zig = `export fn add(a:u8,b:u8) u8 {return a+%b;}`）
观察到的最后标记序列（确定性复现，多次一致）：

```
[DBG] main entry, cmd=build-obj
[DBG] Compilation.create enter
[DBG] Compilation.update enter
[DBG] workerUpdateFile: ... 整个 std 库 AstGen（std.zig, mem.zig,
      Target.zig, elf.zig, enums.zig ...）
[DBG] workerUpdateFile: fmt.zig
thread panic: integer does not fit in destination type   ← 崩在此处
```

- **没有** `astgen done`、没有 sema roots/sema loop/analyzeNavType 任何标记
- 即崩溃在 `pt.update` 的 **AstGen 阶段**（`PerThread.updateFile`，
  Compilation.zig L3092 performAllTheWork → L4524 pt.update 之内），
  **不是 Sema，更不是 codegen**。此前笔记"崩溃在 Sema 及之后"的结论错误，
  原因：`zig ast-check 单文件` 只解析单文件，而 build-obj 要 AstGen
  整个 std（analysis roots 恒含 std_mod，见 Compilation.zig L3055）。
- `-j1` 串行化后最后进入的文件恒为 **`compiler/lib/std/fmt.zig`**
  （无 parse/astgen 完成标记区分，22:19 重建的 exe 已加 parse start/done
  标记，但**尚未运行测试**，下次第一步即跑它区分是 Ast.parse 还是
  AstGen.generate 崩）。

### 关键排除

- **缓存污染排除**：全新 global/local 缓存
  （`.zig-cache3\global_fresh1`）仍确定性崩在 fmt.zig。
- **fmt.zig 是原版**：MCS 提交 1bd1983519 对 `compiler/lib` 只改 4 个文件
  （std/Target.zig、std/Target/mcs51.zig、mcs251.zig、std/builtin.zig），
  fmt.zig 字节级为 0.16.1 原版；AstGen.zig 也**不在** MCS 改动文件清单中
  （MCS 只改 src 下 15 个文件：Sema.zig +2、Type.zig 4 行、Zcu.zig +4、
  codegen.zig、target.zig、dev.zig、link.zig、llvm.zig、spirv/Module.zig
  + mcs 6 个新文件 + Asx.zig）。
- 上游 0.16.1 AstGen 不可能在自家 fmt.zig 上 panic → 崩溃差异只能来自：
  1. **58MB bootstrap 编译器把 stage2  miscompile 了**（最强嫌疑：
     bootstrap 自身是杂乱工作树 ReleaseFast，安全检查关闭静默截断，
     类似 u66 的潜在 bug 可能导致生成错误代码）；
  2. 或 MCS 对 lib/std 的修改间接影响（但 AstGen 是纯语法层，
     Target.zig 在 fmt.zig 之前已成功 AstGen，builtin.zig 作为
     builtin 模块不经 workerUpdateFile）。

### 下次续查步骤

1. 先运行 22:19 构建（带 parse start/done 标记）的最新 exe：
   `.zig-cache-dbg\o\` 下最新 zig.exe，`-j1` + 全新缓存，
   看 fmt.zig 是 parse 崩还是 AstGen.generate 崩。
2. **判别实验**：`git stash` 全部改动后从纯净基线 aa2ae08d3d
   用**同一个** 58MB bootstrap 构建 stage2，编译 empty.zig：
   - 也崩 → bootstrap miscompile / 环境问题，需换官方 0.16.1
     bootstrap（或用 zigmirror 的 0.16.x 构建）验证；
   - 不崩 → 二分 MCS 改动（优先 lib/std/builtin.zig、Target.zig
     两个会被 AstGen 的文件，可逐文件还原测试）。
3. 测试命令模板（必须重定向缓存，沙箱需 disable）：
   ```powershell
   $env:ZIG_GLOBAL_CACHE_DIR = "<fresh global>"
   $env:ZIG_LOCAL_CACHE_DIR  = "<fresh local>"
   & $zigExe build-obj -j1 -target x86_64-freestanding -fno-emit-bin <f>
   ```
4. 构建命令（PS 必须用 splat 数组传 -Dversion-string）：
   `@("build","-Dversion-string=0.16.1","-Dno-lib","--cache-dir",
   "...\.zig-cache-dbg","--global-cache-dir","...\.zig-cache2\global")`
   install 步骤恒因 PDB FileNotFound 失败，缓存内 exe 可直接用。
5. 定位修复后：重建 ReleaseFast 小体积编译器 → 编译 ptrtest.zig
   验证 asm 含 `dr28|@dr` → sdas251/sdcc 端到端 → 清理全部
   [DBG] 打印 → 提交。

### 当前工作树状态

- 未提交修改 5 个文件（含插桩）：zig/src/main.zig、Compilation.zig、
  Zcu/PerThread.zig、Builtin.zig、codegen.zig（含 undefPtrBits 真修复）
- 测试文件：`examples/ai8051u_ptrtest/empty.zig` 当前为 add 函数版本
- 最新插桩 exe：`zig\.zig-cache-dbg\o\` 下 22:19 左右的 zig.exe
  （parse start/done 标记版，未测）
- 未跟踪：zig-baseline/、zig/.zig-out-r3、.zig-out-r4、
  examples/ai8051u_blink/led* 等，勿提交

## 收尾：清理摊子 + 固定“直连管线”（2026-09-14 晚）

### 决定

**放弃自举**。不再尝试用 55MB 宿主构建 stage2 `zig.exe`（无论 Debug /
ReleaseFast 都崩，且无 pdb/符号链无法定位）。只保留唯一可用编译器，走：

```
Zig 源 --(55MB zig.exe build-obj)--> .asm
      --(sdas251)--> .rel
C   源 --(sdcc -mmcs251 -c)--> .rel
      --(sdcc 链接，自动带启动/运行库)--> .ihx
```

### 唯一可用编译器已固定到稳定路径

| 项 | 值 |
|----|----|
| 位置 | `mcs251/compiler/zig-out/bin/zig.exe`（+ `zig.pdb`） |
| 大小/版本 | 55.7 MB / 0.16.1 |
| 来源 | 自动备份自 `zig/.zig-cache/o/910e64d8.../zig.exe`（15:04 构建） |
| 特性 | 含 `mcs51`/`mcs251` 目标定义；**不含** `.ptr_rt` 修复 |
| 忽略 | 已在 `.gitignore` 加 `/compiler（系统 zig 重建）/` |

使用前必须 `ZIG_LIB_DIR=compiler/lib`。`xmake.lua` 的 `--zig` 与
`driver/build.ps1` 的 `-Zig` 默认值已改为该路径。

### 磁盘清理（释放约 50 GB）

删除项（均为自举过程中的缓存/失败产物/调试垃圾）：

- `zig/.zig-cache*`（11 个缓存目录，含 31 GB 的 `.zig-cache/o`：大量
  150MB `zig_zcu.obj` 与 1GB 级失败 zig.exe）
- `zig/.zig-out-r3`、`zig/.zig-out-r4`、`compiler/zig-out`（3 个 1GB 级失败编译器
  + 重复的 lib 拷贝）
- 顶层 `.zig-cache`、`.zig-cache2`、`.zig-cache3`、`.xmake`
- `zig.master-1415.bak`（误判为 0.17 master 时的备份）
- git worktree `zig-baseline/`（基线与主仓历史重复，已 `git worktree remove`）
- `examples/ai8051u_ptrtest/` 下全部调试产物（约 100 个 `.asm/.rel/.ihx/.txt`、
  多个 `.zig-cache*`、编译出的 `noptr/simple/simplest/ptrtest` 可执行文件）
- `projects|examples/ai8051u_blink/` 构建产物（保留 `build.ps1`）

保留：源码（`main.c`/`ptrtest.zig`）、手工参考汇编
`ptrtest_correct.asm`、`test_dr28.asm`、`vendor/`、`sdcc-c251/`、
`tools/sdcc-mcs251-windows-x64/`。

清理前剩余 39.8 GB → 清理后 89+ GB。

### 源码清理

- 回退纯插桩文件：`zig/src/main.zig`、`Compilation.zig`、`Zcu/PerThread.zig`、
  `Builtin.zig`（全是 `[DBG]` 打印，已 `git checkout --` 还原）。
- `zig/src/codegen.zig` 保留两项**真修复**：
  - `undefPtrBits(target)`：修掉 ptr_bits=64 时 `(1<<(64+1))` 溢出 u66→u64 的
    崩溃（仅对“重编编译器”有意义，但写法更安全，保留）；
  - `lowerUavRef`/`lowerNavRef` 增加 `3 => writeInt(u24, ...)`（mcs251 三字节
    指针，M3 需要）。

### 管线验证（已跑通）

用 xtools 清理后的干净工程：

```powershell
# 手动四步（产物在临时目录）
$env:ZIG_LIB_DIR = "<repo>\compiler\lib"
& <repo>\compiler\zig-out\bin\zig.exe build-obj -target mcs251-freestanding `
    -femit-bin=ptrtest.asm ptrtest.zig
& <sdcc251>\bin\sdas251.exe -plosgffw ptrtest.rel ptrtest.asm
& <sdcc251>\bin\sdcc.exe -mmcs251 --model-large -I <repo>\include -c main.c -o main.rel
& <sdcc251>\bin\sdcc.exe -mmcs251 --model-large main.rel ptrtest.rel -o ptrtest.ihx
```

结果：四步全部 exit 0，产出 `ptrtest.ihx`（2618 字节）。

已把该流程固化为 xmake 目标：

```powershell
xmake f --mcs_arch=mcs251    # 注意：xmake v3 用下划线，不是 --mcs-arch
xmake build ptrtest
# -> OK -> mcs251\examples\ai8051u_ptrtest\ptrtest.ihx
```

### 当时限制（后被下面的源码改写解决）

55MB 编译器对 `[*]u8` 参数直接下标（`buf[i]`）生成的 `fill`/`sum` 汇编**全为帧内
寻址**（`mov @spx-0xN,...`），**无 `dr28`/`@dr28` 间接寻址**。

## 跑通 ptr_rt：源码改写绕开旧编译器的 bug（2026-09-14 深夜）

结论：**能跑通**。不需要重编编译器——只需把指针访问改写成旧的 55MB 编译器已经支持
的**单元素指针解引用**路径，就会生成真正的 DR28 间接寻址。

### 实验：哪些写法能出 DR28（55MB 编译器）

| 写法 | 标签数 | DR28 | 结果 |
|------|-------|------|------|
| `buf[i]`（`[*]u8` 直接下标） | 0 | 0 | ✗ 帧内寻址 bug |
| `const s = buf[0..5]; s[i]`（切片） | 4 | 6 | ✓ 有 DR28，但标签冲突 |
| `const a: *[5]u8 = @ptrCast(buf); a[i]` | 0 | 0 | ✗ 仍走 `.ptr` 帧内 |
| `@ptrFromInt(@intFromPtr(buf)+i).*` | 30 | 10 | ✓ 但标签太多 |
| **`(@as(*u8, @ptrCast(buf + i))).*`** | **0** | **24** | ✅ 最佳 |

### 采用的写法（`examples/ai8051u_ptrtest/ptrtest.zig`）

```zig
export fn fill(buf: [*]u8) u8 {
    (@as(*u8, @ptrCast(buf + 0))).* = 'h';
    // ...+1..+4
    return 5;
}
```

- `buf + i`：多元素指针运算，结果是 `.ptr_rt`（3 字节地址）。
- `@ptrCast` 到 `*u8` 后 `.*`：走 `.load`/`.store` 的 `.ptr_rt` 分支 →
  `loadPtrToDr28` → `mov @dr28,r3` / `mov r3,@dr28`。
- **无越界检查 → 0 个 `Lxx` 标签**，避免下一节的标签冲突。

### 顺带发现的编译器 bug：局部标签按函数重新编号

`Gen.next_label` 是**每个函数**从 0 开始（`CodeGen.zig:131`，`generate()` 里新建
`Gen`），`Mir` 输出为文件级全局 `L{n}:`。于是**同一 .asm 内多个含分支的函数会撞
标签**，sdas251 报 `multiple definitions error` + `phase error`。
本工程的 `*u8` 写法无分支，规避了它；切片写法（`buf[0..5]` 的越界检查会生成
`Lxx`）就会触发。彻底修法是给标签加函数前缀（需重编编译器，暂缓）。

### 验证结果

```
[1/4] C -> rel   : main.c
[2/4] Zig -> asm : ptrtest.zig
[3/4] asm -> rel : ptrtest.asm
[4/4] link -> ihx: ptrtest.ihx
OK -> ...\ptrtest.ihx        (3903 字节)
```

- `ptrtest.asm`：`Lxx` 标签 = 0，间接访问 = 10（5 写 + 5 读）。
- `ptrtest.lst` 机器码核对：
  - `pop dr28` = `DA 7B`，`push dr28` = `CA 7B`
  - `add dr28,#0x0001` = `2E 78 00 01`
  - 写：`mov @dr28,r3` = `7A 7B 30`（5 处）
  - 读：`mov r3,@dr28` = `7E 7B 30`（5 处）
- C 侧 `main.asm`：`mov dptr,#_main_buf_10000_16` + `mov b,#(.. >>16)` +
  `ecall _fill`，即 ABI 的 `B:DPH:DPL` 三字节指针，与 Zig 侧 DR28 组装一致。
- 语义核对：`_fill` 依次写入 `0x68/0x65/0x6c/0x6c/0x6f`（"hello"），`_sum`
  5 次 `mov r3,@dr28` 累加后用 DPL 返回。真机应能通过 `main.c` 的三步校验。

> 仍待硬件/模拟器实跑确认（本机 SDCC 包不含 ucsim-251）。但生成的是一条完整的
> 间接寻址路径，且编码、ABI、栈平衡均已逐条核对。

## 软件仿真验证尝试：ucsim 的 MCS-251 是空壳（2026-09-15）

在没有开发板的情况下，尝试用 `sdcc-c251/sim/ucsim` 源码在 WSL 里构建 MCS-251 模拟器，
软件运行 `ptrtest.ihx`。**结论：ucsim 不支持 MCS-251，此路不通。**

### 构建过程（可复现，供以后参考）

- 环境：WSL Debian，`gcc/g++ 14.2.0` + `make/autoconf` 齐备。
- `sdcc-c251/sim/ucsim` 的 `configure` 与 `*.in/*.mk/*.ac` 均为 CRLF，直接跑会
  `$'\r': command not found`。需先 `sed -i 's/\r$//'` 归一化（用 WSL 原生路径更快）。
- `./configure && make -j` 成功，产出统一二进制
  `src/apps/ucsim.src/ucsim`（3.5 MB，不是 `s51`）。
- CPU 类型名见 `src/core/utils.src/globals.cc:382`：`251` / `MCS251`。

### 为什么不可用

- `ucsim -t 251 ptrtest.ihx` 能加载（PC=0），但：
  - `info memory` 只有 256B `variables` + 1MB `nas`，**没有 SFR/XDATA 空间**；
  - `info registers` → `No registers`；`get sfr 0x90` → `No SFR`；
  - `dump`（代码区）每个字节都报 `uc::disass() unimplemented`；
  - `step 1` 直接**卡死**（超时），`step`/`dump xdata` 等内存类型名全部不识别。
- 根因：`sim/ucsim/src/sims/s51.src/umcs251.cc`（仅 44 行）里
  `cl_umcs251` 是**空构造**，只继承 8 位核 `cl_uc89c51r`，**未实现任何 251 指令、
  DR28/24 位寻址、SFR、反汇编**。全仓库 `grep dr28` 无命中。
- 要真正仿真 251，需自行实现整个 MCS-251 核（大工程），当前不划算。

### 用途

- 该 WSL 构建（`~/ucsim251`）只对 **8051/mcs51** 目标有效，可跑 8051 的 `.ihx`，
  但**不能**验证 251 目标。M3 的真机/仿真确认仍**依赖开发板**。

## 局部标签冲突：构建层自动修复（2026-09-15）

### 问题（复现）

> 见前文“局部标签按函数重新编号”。构造 `labeltest.zig`（同文件两个含 `if` 的函数
> `f1`/`f2`）→ 两个函数各自产出 `L1..L6` → `sdas251` 直接报
> `<m> multiple definitions` + `<p> phase error`（exit 2）。

### 根因

- `CodeGen.zig:131` 的 `Gen.next_label` 每个函数从 0 开始，`generate()` 里新建 `Gen`；
- `Mir.zig:108` / `encode.zig:170` 把标签**原样**输出为文件级 `L<d>:` / `L<d>`，
  没有函数前缀 → 同名。

### 解法：不改编译器，改构建

新增 `tools/fix_mcs_labels.py`：扫描 `.asm`，按函数边界
（`.globl <sym>` 或行首非 `L<digits>` 的全局标签）切换命名空间，把该函数内的
`L<n>` 全部改成 `L_<func>_<n>`（注释部分不动）。

```powershell
python tools/fix_mcs_labels.py <file.asm>          # 就地改写
python tools/fix_mcs_labels.py --check <file.asm>  # 只报告跨函数重名
```

- 已验证：`labeltest.asm` 修复后 `sdas251` 由 exit 2 → **exit 0**。
- 已接入 `xmake.lua`（blink / ptrtest 的 `[2.5/4]` 步，新增 `--python` 选项）与
  `driver/build.ps1`（`[1.5/4]` 步，新增 `-Python`）。
- 接入后重跑 `xmake build ptrtest`：2 个函数、0 处重命名，产物 `ptrtest.ihx` 3903B 不变。

### 意义

- 一个 `.zig` 里可以有**多个含分支的函数**，不再需要“一个 .asm 一个分支函数”。
- 这是**构建层绕过**（编译器源码缺陷仍在）；彻底修法仍是给 `Gen.next_label`
  加函数前缀并重编 `zig.exe`（受自举崩溃阻塞，见前文）。

## 软件仿真跑通 8 位（mcs51）：ucsim + AT89C52 自检测试（2026-09-15）

mcs251 仿真不可用（ucsim 的 251 核是空壳，见上节），但 **8051（mcs51）核真实可用**。
据此把「C + Zig 混编 → 运行」整条链在**软件仿真**里闭环。

### ucsim 的正确调用方式（关键）

- WSL 构建产物（见上节）：`~/ucsim251/src/sims/s51.src/ucsim_51`（专用 51 模拟器，
  不是统一二进制 `src/apps/ucsim.src/ucsim`）。
- 必须加 `-S in=/dev/null,out=-`，并把命令文件喂给 **stdin**（不是 `-C`）：

  ```bash
  ucsim_51 -t 32 -S in=/dev/null,out=- <prog.ihx> < cmds.txt
  ```

  否则：串口接口抢占 stdin，命令控制台在 `step` 上**永久阻塞**（`step 1` 都会卡死）。
  参考 `sdcc-c251/support/regression/ports/mcs51-common/spec.mk`
  （`EMU_PORT_FLAG=-t32`、`EMU_FLAGS=-S in=$(DEV_NULL),out=-`）与顶层
  `support/regression/Makefile.in`（`EMU_INPUT = < uCsim.cmd`）。

- 常用命令：`step <n> [vclk]`、`state`、`get sfr <addr>`、`dump xram/iram/sfr/bits/rom`
  （内存类型名见 `info memory`）；回归风格还会先
  `set error unknown_code off`、`set opt selfjump_stop 0`。

### 新增自检测试工程 `examples/at89c52_sim/`

- **只用标准 8051 SFR**（AT89C52 风格，不依赖 STC 专有寄存器），ucsim 可直接执行。
- C（`main.c`）：连续调用 Zig `led_next(u8)` 八次，逐项比对期望序列；
  结果写 XRAM —— `0x8000=status`（`0xAA` 通过 / `0x55` 失败）、
  `0x8001=failcode`、`0x8002..=seq[8]`。
- Zig（`led.zig`）：纯标量，无指针/切片，避开后端已知限制。
- 构建：`xmake build --mcs_arch=mcs51 simtest`（xmake 目标 `simtest`）。
- 仿真结果（`dump xram 0x8000 0x800f`）：

  ```
  0x8000   aa 00 02 04 08 10 20 40 80 01 ...
  ```

  → `status=0xAA`，`failcode=0`，序列与期望完全一致，**通过**。

### 踩坑：`__xdata __at(0x0000)` 与 XSEG 重叠

最初把结果变量放在 `__at(0x0000/1/2)`，仿真得到 `status=0x55`、`failcode=1`，
看似 Zig 函数错。用最小隔离测试（只调 `led_next(0x01)`/`led_next(0x40)` 存 xdata）
证明返回 `0x02`/`0x80` 正确；真因是 **SDCC 把 XSEG 也放在 0x0001**，
与 `__at` 绝对变量重叠、互相踩踏。把结果变量移到高位 `0x8000` 后即通过。

### 结论

- **8 位（mcs51）整条链已闭环**：Zig→asm→sdas8051→sdcc 链接→`.ihx`→ucsim 运行。
  可作为 C↔Zig 互操作与后端代码生成的**回归验证手段**（无需开发板）。
- blink 工程（STC AI8051U 8 位兼容模式）同样能在 ucsim 里跑：P1 依次
  `0x7E→0x7D→0x7B→0x77`，即流水灯逐位点亮。
- **251 目标仍只能靠真实硬件**（ucsim 251 核缺失）。

## 自举问题解决：改用系统 zig 0.16.0 重建（2026-09-15）

前面的“放弃自举”结论**作废**。根因确认：`compiler/zig-out/bin/zig.exe`（55MB）
是个**坏 bootstrap**——它把 stage2 `zig.exe` miscompile 成一编译就崩
（x86_64 主机路径栈溢出 / `@intCast`）。用**官方 0.16.0** 当 bootstrap 就正常。

### 重建方法（系统 zig 0.16.0，winget 装的，`zig` 已在 PATH）

```powershell
cd <workspace>\mcs251\compiler
zig build -Doptimize=ReleaseFast -Dno-lib --zig-lib-dir <workspace>\mcs251\compiler\lib
# 产物：<workspace>\mcs251\compiler\zig-out\bin\zig.exe（0.16.1）
```

- **必须** `--zig-lib-dir` 指向源码树自带的 `compiler/lib`（含 mcs51/mcs251 目标定义）；
  否则用系统 zig 自己的 lib 会报 `no field named 'mcs51' in enum Target.Cpu.Arch`。
- `-Dno-lib` 跳过 lib 拷贝，省时；运行新编译器时仍设
  `ZIG_LIB_DIR=<repo>\compiler\lib`。
- 首次全量编译若干分钟；增量/命中缓存很快。

### 验证

- `zig-out\bin\zig.exe version` → `0.16.1`。
- `build-obj -target x86_64-windows`（此前**必崩**）→ **exit 0**。
- `-target mcs51-freestanding` / `mcs251-freestanding` → 正常出 asm。
- 用它重建 `examples/at89c52_sim` 的 `simtest.ihx`，ucsim 里
  `0x8000=aa`、序列正确 → 产物可信。

### 意义

- **解锁所有后端源码级改动**：mcs51 指针/全局/多参数、标签前缀、peephole 优化等，
  都能改 `compiler/src/codegen/mcs/` 后重建验证，不再受“不能重编”限制。
- xmake 的 `--zig` 默认已改为**优先** `compiler/zig-out/bin/zig.exe`，退回旧 bootstrap。

## 验证：stage2 可用、ptr_rt 生效、stage3 仍崩（2026-09-15）

### 通过项

- 系统 zig 0.16.0 构建的 stage2（`zig-out/bin/zig.exe`，23.2 MB，报 0.16.1）：
  - `build-obj -target x86_64-windows`（旧系统**必崩**）→ exit 0；
  - mcs51 / mcs251 编译正常；
  - 用它重建 `simtest.ihx` → ucsim `0x8000=aa`、序列正确。
- **`.ptr_rt` 修复确实生效**：mcs251 下**直接用 `buf[i]`**（不再用 workaround）
  编 `fill`/`sum`，`fill` 生成 `mov @dr28,r3`（写 buffer），而不是
  `mov @spx-0xN,a`（写自己的栈帧）。→ 旧的
  `(@as(*u8, @ptrCast(buf + i))).*` **不再必需**。
- mcs251 `ptrtest` 全流程（zig→sdas251→sdcc→ihx）OK。

### 未通过项（已知，不阻塞目标）

- **自举 stage3 崩**：用 stage2 再编一个编译器（stage3，947 MB）→ 任何输入都
  `0xC0000094`（整数除零）。与本文前段的自举崩溃同源，是**源码里遗留的 codegen
  缺陷**，触发于“编译编译器自身”这种复杂输入；普通用户代码（含 mcs51/mcs251
  目标）不触发。
- **不影响 mcs51/mcs251 目标产物**（我们的用途）。需重编编译器时，用
  **系统 zig 0.16.0**（而非 stage2 自举）。
- stage2(23 MB) 与 stage3(947 MB) 体积差约 40×，说明二者构建配置不同：
  stage3 走**自托管后端、未启用 LLVM**，该后端在此源码版本上不可靠。

### 结论

- 日常流程：**改后端 → 用系统 zig 重建 stage2 → 用 stage2 编目标代码 → ucsim 验证**。
- 不要依赖 stage2 自举（stage3）。

## 构建模式对比与迭代提速（2026-09-15）

| 模式 | 主机 x86_64 编译 | mcs51/mcs251 | 全量/增量重建耗时 | 体积 |
| --- | --- | --- | --- | --- |
| ReleaseFast | ✅ | ✅ | **~498 s**（改一行也重编整个 `zig` 模块） | 23 MB |
| Debug | ❌（安全 panic，exit -1） | ✅ | **~104 s** | 55.7 MB |

- **迭代后端时用 Debug**：只关心 mcs51/mcs251 产物，Debug 快约 5×。
  命令加 `-Doptimize=Debug` + 独立 `--cache-dir`。
- 需主机编译（如自举/发布）时才用 ReleaseFast。
- 旧 `compiler/zig-out/bin/zig.exe` 的 **55 MB** 与 Debug 产物 **55.7 MB** 几乎一致
  → 它很可能就是一个 Debug 构建，这也解释了它的主机崩溃症状。
- **“把后端拎出来做运行库”不可行/不划算**：`src/codegen/mcs/` 吃的是 Zig **AIR**
  （由 AstGen/Sema/Zcu 产生），无法脱离前端独立运行；要独立就得重写 Sema。
  “运行库”是程序链接用的辅助库，与后端迭代速度无关。
  真正影响迭代速度的是“改一行重编整个模块”，故用 Debug 构建是当前最有效的提速。

## mcs51 指针（xdata）实现（2026-09-15）

后端原本所有指针路径都是 MCS-251/DR28 专用，mcs51 会错发 251 指令。新增 mcs51 分支：

- `derefRead` / `derefWrite`：mcs51 → `loadPtrToDptr`（低字节→DPL、高字节→DPH）
  + `movx a,@dptr` / `movx @dptr,a` + 逐字节 `inc dptr`。
- `emitElemPtr`（`+off`）与 `emitPtrAdd`（`buf + off`）：mcs51 → 复制 2 字节指针，
  再用 DPTR 做 16 位加（`mov a,dpl; add a,#lo; mov dpl,a; mov a,dph; addc a,#hi; mov dph,a`）。
- 指针表示：mcs51 下 `[*]T` = **2 字节 xdata 指针**，帧内小端（`+0`=低，`+1`=高），
  与 SDCC 的 `__xdata T *` 一致。

验证（ucsim，AT89C52 风格自检）：

- `examples/at89c52_sim`：C 传 `__xdata u8 *`，Zig `sum4` 读 4 字节求和；
  `0x8000=aa`、`failcode=0`。
- 三种写法均 `dr28=0` 且 `sdas8051` 通过：`buf[i]`、`(@as(*u8,@ptrCast(buf+i))).*`、`buf+1`。
- fill/sum（mcs51 版 ptrtest）：`fill` 返回 5、`sum` 返回 20（`0x14`），`status=0xaa`。

改动：`compiler/src/codegen/mcs/CodeGen.zig`（约 +90 行）。重编：Debug ~100s / ReleaseFast ~11min。

仍缺：多参数、全局变量、切片、`@ptrFromInt(addr).*`（单元素指针）——见 [06 §1.1](06-常见问题与限制.md)。

## mcs51 多参数（C-栈约定）实现（2026-09-15）

采用 **SDCC `--stack-auto` 约定**作为共享 ABI（用户选定「C-栈」）：

- 参数0 → DPL/DPH/B/A；参数 2..N 由 **caller 逆序压栈**；callee 在入口读取；
  返回在 DPL/DPH/B/A；caller 清理（`dec sp`）。
- Zig 后端 caller 侧（`emitCall`）本就实现了逆序压栈 + 退栈；**callee 侧
  （`emitArg`）的 SP 偏移算错**：原 `off = 2 + Σsize(2..k)`（含自身），
  修正为 `off = 2 + Σsize(2..k-1)`（`preallocArg` mcs51 分支）。
- 验证（ucsim）：
  - `add3(1,2,3)=6`、`add4(1,2,3,4)=10`；
  - **Zig 回调 C**：`viac(1) → cadd3(1,2,3) = 123`；
  - `examples/at89c52_sim`（标量 + 指针 + 多参数）`status=0xaa`。
- C 侧必须 `--stack-auto`（`xmake` 的 simtest 已加）。**未改 SDCC 源码**——
  `--stack-auto` 是现成开关。
- 预留的 SDCC 分叉：`<workspace>\sdcc-c251-abi`（原 `sdcc-c251` 保持原样）。
  若要把 stack-auto 设为 mcs251/mcs51 默认（免开关），在
  `src/SDCCmem.c:allocParms` 的判定或默认选项处改，再用 WSL 重编 SDCC。

仍缺：**全局变量**（`CodeGen` 的 `indirect memory access` + `src/link/Asx.zig:updateNav`
只打 TODO）、切片、`@ptrFromInt(addr).*` 单元素指针。

## mcs51/Zig 全局变量（xdata）实现（2026-09-15）

- `CodeGen.zig`：新增 `globalSymbolOf`（识别 `.ptr→.nav` / `.@"extern"` 的编译期数据符号）
  与 `derefSymbolRead/Write`（`mov dptr,#_sym` + `movx`）；在 `emitLoad`/`emitStore`
  标量路径接入。`encode.zig` 增加 `imm_symbol` 操作数（输出 `#_sym`）。
- `src/link/Asx.zig`：`updateNav` 不再只打 TODO——对**已定义**的数据 nav 输出
  `.area XSEG (XDATA)` + `.globl _name` + `_name: .ds <size>`（**零初始化**）。
- 验证（ucsim）：
  - extern（C 定义、Zig 读写）：`gv` 5→6（`inc_gv`/`get_gv`）；
  - Zig 定义（C 读写）：`export var counter`，C 侧 `counter`/`bump()` 一致；
  - `examples/at89c52_sim` 增至 **标量 + 指针 + 多参数 + 全局** 全通过。
- 限制：非零初值（`var x = 42`）暂不生效（xdata 初始化需 XINIT + 启动拷贝，
  Zig 后端不发启动片段）。

至此 8 位（mcs51）C↔Zig 互操作覆盖：单标量、多参数、xdata 指针、全局变量。仍缺：
切片、`@ptrFromInt(addr).*` 单元素指针。

## 固定地址访问 `@ptrFromInt`（2026-09-15）

- `CodeGen.zig` 新增 `fixedAddrOf`（识别 `.ptr` 的 `base_addr == .int`）与
  `derefFixedRead/Write`（`mov dptr,#<addr>` + `movx`），在 `emitLoad`/`emitStore`
  标量路径接入。
- 验证：Zig `(@as(*volatile u8, @ptrFromInt(0x8010))).*` 读写与 C/仿真一致；
  `at89c52_sim` 增加 0x8020 固定地址读写测试。
- 局限：按 **xdata** 处理（MOVX）。**SFR 直址（0x80–0xFF）尚未区分**——用
  `@ptrFromInt` 访问真实 SFR 需地址空间转换（后续）。

至此 mcs51 C↔Zig 互操作覆盖：**单标量、多参数、xdata 指针、全局变量、固定地址**。
仍缺：切片。
