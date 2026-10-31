//! USB-CDC 混编实验的 **Zig 侧**（mcs2 编译）。
//!
//! 方向只有一个：**C 调 Zig**。mcs2 还没有 .call（M2.5 未做），Zig 侧无法调回 C，
//! 所以 Zig 在这里只做纯计算，接口只用定长整数（不带指针/切片）。
//!
//! 符号约定：export fn 生成 _<文件名>_<函数名> + 别名 <函数名>，
//! C 侧按 <函数名> 直接声明即可（与 SDCC 的 _ 前缀一致）。

/// **Zig 调 C**（M2.5 之后才可能）：C 侧提供实现，Zig 只声明。
extern fn c_scale(x: u8) u8;

export fn zig_calls_c(x: u8) u8 {
    return c_scale(x) +% 1;
}

/// 无参无返回的 C 函数：连调两个不同实例（对应 C 里的 c_ping / c_ping2）。
extern fn c_ping() void;
extern fn c_ping2() void;

export fn zig_two_void_calls(x: u8) u8 {
    c_ping();
    c_ping2();
    return x +% 1;
}

/// 单字节：模拟 CDC 回调里的一步混音（被 C 直接调用）。
export fn zig_cdc_mix(x: u8) u8 {
    var v: u8 = x ^ 0x5A;
    v +%= 0x11;
    return v;
}

/// 32 位：验证多字节 ABI（arg0 → DPL/DPH/B/A，arg1 → PARM_2..5，返回同）。
export fn zig_cdc_hash(a: u32, b: u32) u32 {
    const m: u32 = a *% 0x00000101;
    return m +% b;
}
