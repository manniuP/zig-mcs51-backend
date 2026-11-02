//! 运行期移位次数（不是编译期常量）：按「每轮 1 位」循环，8 位也走同一模板。
//! Zig 的移位次数量值类型是 u5，源码里要 @intCast；后端只看低字节。

export fn shlv(x: u32, n: u8) u32 {
    return x << @as(u5, @intCast(n));
}

export fn shrv(x: u32, n: u8) u32 {
    return x >> @as(u5, @intCast(n));
}

// 有符号右移：每轮把最高位补成符号（不是补 0）
export fn sarv(x: i32, n: u8) i32 {
    return x >> @as(u5, @intCast(n));
}
