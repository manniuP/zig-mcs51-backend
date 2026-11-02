//! M1.5 验收：timer0 中断 ISR（向量号 1 → 0x000B，编译器自动发向量跳板）。
//! 每次溢出中断把 xdata 0x8000 计数 +1（load_xdata/add/store_xdata）。
//! SFR/xdata 固定地址经 `@ptrFromInt` 解引用访问——lower 到 load_dir/load_xdata/store_xdata。
const counter = @as(*volatile u8, @ptrFromInt(0x8000));

export fn timer0_isr() callconv(.{ .mcs51_interrupt = .{ .vector = 1 } }) void {
    const c = counter.*;
    counter.* = c +% 1;
}
