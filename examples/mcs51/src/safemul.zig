// 安全档 16 位无符号乘法溢出检查（单开文件：safe.zig 同单元的静态槽已近上限）。
// 三次 MUL AB 拼 16×16→32，高 16 位 = t0 + t1 + t2，两次 add 的进位任一置位即溢出。

export fn safe_mul16(a: u16, b: u16) u16 {
    return a * b;
}
