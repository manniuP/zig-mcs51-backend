//! 比较当值用：bool 返回（0/1 字节）。条件位置仍走 cond_br 融合，值形态才物化。

// -1 < 0 → 1（有符号 + 宽比较）
export fn lt32(a: i32, b: i32) bool {
    return a < b;
}

// 无符号 8 位 >=
export fn ge8(a: u8, b: u8) bool {
    return a >= b;
}
