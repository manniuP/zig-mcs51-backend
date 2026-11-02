# 预编译包（非稳定版）

| 文件 | 说明 |
| --- | --- |
| `zig-mcs51-0.17.1-windows-x86_64.zip` | Windows x64：编译器 + `lib` 子集 + 示例 + 工具 + SDCC |

## ⚠️ 这是非稳定版（pre-release）

- 本树基于 **Zig 0.17.1-dev**，而 0.17.1 **尚未正式发版**；
  包里的 `zig.exe` 是**自举产物**（用 0.17.0 + 本树源码编出来的）。
- GitHub Actions 目前构建失败：`internPool`/`Sema` 用了 0.17.1 才有的 API，
  引导编译器版本对不上（0.17.0 太旧、master 又漂了）。**等 0.17.1 发版后会自动重建**。
- 只有 Windows x64。Linux 版必须在 Linux 上用匹配的 0.17.1 引导编译（见 `ci/build-dist.sh`）。

## 用法

```bat
set ZIG_LIB_DIR=<解压目录>\lib
cd examples\mcs51
..\..\zig.exe build
rem 产物：examples\mcs51\zig-out\asm\*.asm
```

冒烟已过：用包里的 `zig.exe` 编 `examples/mcs51` → 48 个 `.asm`。

## 校验

```
sha256  见下方（发布时填写）
```
