//! **尾递归**：`return f(...)` 形状编译成 `ljmp`（自递归 → 跳回入口，栈深度不增长）。
//!
//! 为什么必须支持：8051 的栈只有 128 字节，普通递归一旦上百层就崩；而"尾递归 = 循环"
//! 是状态机/解析器最常见的写法。非尾递归仍然**不安全**（静态 PARM 槽会被内层调用踩掉），
//! 本文件只保证尾位置正确。

// 自尾递归：累加 1..n（两个参数，第二个走 PARM 区）
fn go(n: u8, acc: u16) u16 {
    if (n == 0) return acc;
    return go(n - 1, acc +% n);
}

export fn trsum(n: u8) u16 {
    return go(n, 0);
}

// 互尾递归：even/odd 互相 `return`（尾调用跨函数 → ljmp 另一个符号）
fn isEven(n: u8) u8 {
    if (n == 0) return 1;
    return isOdd(n - 1);
}

fn isOdd(n: u8) u8 {
    if (n == 0) return 0;
    return isEven(n - 1);
}

export fn evodd(n: u8) u8 {
    return isEven(n);
}
