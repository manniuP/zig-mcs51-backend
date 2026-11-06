//! `@intFromPtr(&数据)`：把全局数组的**地址本身**当 16 位整数用。
//! 与 `symtab.zig` 的区别：那些是「知道符号就直接访存」，这里地址要变成值
//! —— DMA 描述符、缓冲区指针表、环形队列的读写指针都靠它。
//!
//! 四条用例覆盖四种地址来源：常量基址 / 运行期下标 / 存进表里再取回 / 偏移差。
//! ⚠️ 全局变量的**初值不保证被装载**（XSEG 初值要靠启动代码搬），
//! 所以每条用例都是「先写后读」自证，不能依赖 `.{1,2,...}` 那个初值。

var buf: [8]u8 = .{ 1, 1, 1, 1, 1, 1, 1, 1 };
var reg: [2]u16 = .{ 0, 0 };

// ① 常量基址：&buf[0] → u16 → @ptrFromInt 读回（地址往返）
export fn daddr0() u8 {
    buf[0] = 0x11;
    buf[1] = 0x22;
    const a: u16 = @truncate(@intFromPtr(&buf[0]));
    const q: *u8 = @ptrFromInt(a);
    return q.* +% buf[1];
}

// ② 运行期下标：地址 = 符号基址 + i（下标在运行期加进 DPTR）
export fn daddr1(i: u8) u8 {
    buf[i] = 0x5A;
    const a: u16 = @truncate(@intFromPtr(&buf[i]));
    const q: *u8 = @ptrFromInt(a);
    return q.*;
}

// ③ 地址进表再取回（真实用途：缓冲区指针表 / 跳转表）
export fn daddr2(i: u8) u8 {
    buf[0] = 0x5C;
    buf[1] = 0x5D;
    reg[0] = @truncate(@intFromPtr(&buf[0]));
    reg[1] = @truncate(@intFromPtr(&buf[1]));
    const a: u16 = reg[i & 1];
    const q: *u8 = @ptrFromInt(a);
    return q.*;
}

// ④ 偏移差：&buf[2] - &buf[0] 必须是 2（证明符号基址 + 常量偏移真的加对了）
//    注意先截断成 u16 再减：usize 是 24 位，后端只支持 8/16/32 位加减。
export fn daddr3() u8 {
    const a: u16 = @truncate(@intFromPtr(&buf[2]));
    const b: u16 = @truncate(@intFromPtr(&buf[0]));
    return @truncate(a -% b);
}
