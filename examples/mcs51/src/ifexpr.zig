//! `if` / `switch` **表达式**（块返回值）：后端用「内存 phi」降级。

// if 表达式：c 非 0 → 0x11，否则 0x22
export fn ifx(c: u8) u8 {
    const r: u8 = if (c != 0) 0x11 else 0x22;
    return r;
}

// 直接 return if（返回值形态）
export fn ifr(c: u8) u8 {
    return if (c != 0) 0x11 else 0x22;
}

// switch 表达式（u8 判定 + else）
export fn swx(c: u8) u8 {
    return switch (c) {
        1 => 0x11,
        2 => 0x22,
        3 => 0x33,
        else => 0xEE,
    };
}

// 多字节（u16）if 表达式
export fn ifw(c: u8) u16 {
    return if (c != 0) 0x1234 else 0x5678;
}