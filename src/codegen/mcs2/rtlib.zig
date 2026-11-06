//! mcs2 运行时模板库（rtlib）：标准算子的**手写汇编**版本。
//!
//! 为什么需要它：后端生成的内联代码在槽往返、循环化、复制消除上先天吃亏。
//! 以 32 位算术右移为例，内联展开是「复制到目标槽 + 每轮 4 对 `mov a,槽` /
//! `rrc a` / `mov 槽,a`」，4 字节移 3 位要 124 B；手写模板把值摆在 r1–r4、
//! 用 `djnz` 循环，整份只有 37 B（含站点摆参）。固定算法就该给一份调好的。
//!
//! 约定（三条都不能破）：
//!
//! 1. **只用 r0–r4**。`assignRegisters` 固定分配 R5/R6/R7，模板避开它们，
//!    就不必给寄存器分配加"某函数禁用某几个寄存器"的特殊规则。
//! 2. **参数与返回值走边界 ABI**（DPL/DPH/B/A 小端，低位在前），与 SDCC
//!    `--model-small` 逐字节一致，C 侧可以直接调用，互操作轴不受影响。
//! 3. **符号是编译单元局部的**（不加 `.globl`）。多个编译单元各自带一份
//!    模板，代价是每单元多 30 余字节，换来"链接时不会撞符号"。
//!
//! 纯函数性质：模板没有静态槽、没有会话状态，**天然可重入**。这一点比
//! `factor.zig` 的共享例程更强——后者复用拥有者函数的静态槽，不可重入。
//!
//! ISR 内**不套用**：中断现场只保存 A/PSW/DPTR/B，被模板占着的 r0–r4 会被
//! 打断方踩坏。`mcs2.zig` 里用 `!self.is_isr` 把关，与 `assignRegisters`
//! 的 ISR 规则同源。

const std = @import("std");

pub const Id = enum { sar32 };

pub const Template = struct {
    /// 符号名（单元局部，不加 .globl）。
    sym: []const u8,
    /// 完整汇编文本，末尾自带换行。
    text: []const u8,
    /// 站点额外成本：摆参（4 条 mov = 8 B）+ 次数（2 B）+ lcall（3 B）+ 取回（8 B）。
    /// 只用于诊断输出，不参与决策。
    site_bytes: u16 = 21,
};

/// 32 位算术右移。
///
/// 入：r0 = 移位次数（1..31），r1 = **槽基址 + 3**（最高字节）。
/// 出：原地写回同一组槽（调用方负责保证这组槽在此之后才被释放/覆盖）。
///
/// 为什么直连槽而不是走 ABI 寄存器：走 DPL/DPH/B/A 的话，站点要付两次
/// 逐字节往返（入 4 条 + 出 4 条 `mov direct,direct` 各 3 B，共 24 B），
/// 比模板本体还贵。`@Ri` 能寻 8 位 IDATA，而 DSEG 槽就在 0x30–0x7F，
/// 于是站点只剩「装指针 + 装次数 + lcall」7 B。
///
/// 每轮用 `mov c,acc.7` 重新取符号位：`rrc` 链会把 C 带走（上一字节的 bit0），
/// 只有每轮重设才能保证是算术右移而不是逻辑右移。
const sar32_text =
    \\
    \\    .area CSEG (CODE)
    \\_mcs_rt_sar32:
    \\L_mcs_rt_sar32:
    \\    mov a,@r1
    \\    mov c,acc.7
    \\    rrc a
    \\    mov @r1,a
    \\    dec r1
    \\    mov a,@r1
    \\    rrc a
    \\    mov @r1,a
    \\    dec r1
    \\    mov a,@r1
    \\    rrc a
    \\    mov @r1,a
    \\    dec r1
    \\    mov a,@r1
    \\    rrc a
    \\    mov @r1,a
    \\    inc r1
    \\    inc r1
    \\    inc r1
    \\    djnz r0,L_mcs_rt_sar32
    \\    ret
    \\
;

pub const templates = [_]Template{
    .{ .sym = "_mcs_rt_sar32", .text = sar32_text },
};

pub const count = templates.len;

/// 总开关（与 `enable_factor`、`no_reuse_wide` 同款：做尺寸对照时手工改 false）。
pub var enabled: bool = true;

/// 本编译单元内已发射过的模板。多个站点共用一份，第一个站点负责带出文本。
var emitted: [count]bool = @splat(false);

/// 是否本次新发射（true 表示调用方要把文本追加出去）。
pub fn take(id: Id) bool {
    const i = @intFromEnum(id);
    if (emitted[i]) return false;
    emitted[i] = true;
    return true;
}

pub fn sym(id: Id) []const u8 {
    return templates[@intFromEnum(id)].sym;
}

pub fn text(id: Id) []const u8 {
    return templates[@intFromEnum(id)].text;
}

/// 按下标取（发射时遍历位图用，省得做枚举转换）。
pub fn textAt(i: usize) []const u8 {
    return templates[i].text;
}

/// 单元开始时清账（同一进程内编译多个单元时，各单元都要带一份自己的模板）。
pub fn reset() void {
    emitted = @splat(false);
}

test "模板表自洽：符号名不重复、文本以换行结尾" {
    for (templates, 0..) |t, i| {
        try std.testing.expect(t.text.len > 0);
        try std.testing.expectEqual(@as(u8, '\n'), t.text[t.text.len - 1]);
        for (templates[0..i]) |p| {
            try std.testing.expect(!std.mem.eql(u8, p.sym, t.sym));
        }
    }
}

test "take 只对新模板返回 true" {
    reset();
    defer reset();
    try std.testing.expect(take(.sar32));
    try std.testing.expect(!take(.sar32));
    reset();
    try std.testing.expect(take(.sar32));
}
