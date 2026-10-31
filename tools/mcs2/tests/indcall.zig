//! 间接调用：把函数地址装进 u16，再 @ptrFromInt 强转成函数指针调用。
//! 这是嵌入式最常见、也最容易踩坑的用法（地址经常来自表/协议/常量）。
//!
//! 8051 没有 "lcall @a+dptr"，发射层自己搭返回地址：
//! push 返回地址(低/高) + push 目标(低/高) + ret（**RET 先弹高字节**，实测）。
//! 限制：间接调用拿不到被调方的 PARM 符号 → 实参合计只能 ≤4 字节（全走 ABI 寄存器）。

export fn inc8(v: u8) u8 {
    return v +% 1;
}

export fn call_ind(a: u16, x: u8) u8 {
    const Fn = *const fn (u8) u8;
    const f: Fn = @ptrFromInt(a);
    return f(x);
}

// 同一段代码调两次：证明间接调用能连续用（栈上不能残留）
export fn twice_ind(a: u16, x: u8) u8 {
    const Fn = *const fn (u8) u8;
    const f: Fn = @ptrFromInt(a);
    return f(f(x));
}
