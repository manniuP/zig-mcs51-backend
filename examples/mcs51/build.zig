//! mcs2（MCS-51 / 8051）示例与验收用例的统一构建入口。
//!
//! 用法（在 examples/mcs51 下）：
//!
//!     zig build                                   # 全部用例 → zig-out/asm/*.asm
//!     zig build -Dcase=add                        # 只构建一个
//!     zig build -Dzig=<repo>/zig-out/bin/zig      # 显式指定 mcs2 编译器
//!
//! 产物是 ASxxxx 汇编文本（8051 后端只出汇编），后续 sdas8051 + sdld 由
//! tools/mcs2（ucsim 验收）或上层构建脚本负责。
//!
//! 为什么 `zig build` 由宿主 zig 跑、用例却由 mcs2 编：
//!   mcs2 树的 host 链接路径目前跑不了 build runner（宿主 exe 链接会卡在
//!   compiler_rt 归档解析），所以「跑构建脚本」和「编 8051 代码」分成两个工具。
//!   用例清单在 `cases.txt`（与 src/ 一一对应），改用例时保持一致。
const std = @import("std");

const cases_txt = @embedFile("cases.txt");

pub fn build(b: *std.Build) void {
    // 默认就用**正在跑这个脚本的编译器**：本仓库自举出来的 zig 直接 `zig build` 即可。
    // 如果你想用系统 zig 跑脚本、另指定 mcs2 编译器，就传 -Dzig=...
    const zig_exe = b.option([]const u8, "zig", "mcs2 编译器路径（默认=当前 zig）") orelse
        b.graph.zig_exe;
    const only = b.option([]const u8, "case", "只构建某个用例（文件名去掉 .zig）");

    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, cases_txt, " \t\r\n");
    while (it.next()) |stem| {
        if (only) |want| {
            if (!std.mem.eql(u8, want, stem)) continue;
        }
        const cmd = b.addSystemCommand(&.{
            zig_exe,
            "build-obj",
            "-OReleaseSmall",
            "-target",
            "mcs51-freestanding",
            "--dep",
            "cordic",
        });
        // 相对路径都相对本目录：cwd 固定成 build 根（examples/mcs51）
        cmd.setCwd(b.path("."));
        cmd.setEnvironmentVariable("ZIG_LIB_DIR", "../../lib");
        cmd.addPrefixedFileArg("-Mroot=", b.path(b.fmt("src/{s}.zig", .{stem})));
        cmd.addPrefixedFileArg("-Mcordic=", b.path("lib/cordic.zig"));
        const out = cmd.addPrefixedOutputFileArg("-femit-bin=", b.fmt("{s}.asm", .{stem}));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(out, .prefix, b.fmt("asm/{s}.asm", .{stem})).step);
        n += 1;
    }
    std.debug.print("mcs2 examples: {d} 个用例 → zig-out/asm/（编译器 {s}）\n", .{ n, zig_exe });
}
