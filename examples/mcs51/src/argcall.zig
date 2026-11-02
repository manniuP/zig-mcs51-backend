//! 调用会踩 DPL：arg0 是 1 字节时后端把参数**就地**当 DPL（省一次 mov），
//! 但 `lcall` 会把被调方的 arg0 放进 DPL —— 于是第二次用到参数就变成上次的实参。
//! 真程序里 `puthex`/`putbyte` 这类「算一位、发一位」的写法一撞就中（realapp.zig 踩到过）。

fn plus1(v: u8) u8 {
    return v +% 1;
}

// 同一个参数连用两次：0x34 → 0x35 + 0x35 = 0x6A
export fn twice(x: u8) u8 {
    return plus1(x) +% plus1(x);
}

// 高低半字节各用一次：0x34 → plus1(3)=4, plus1(4)=5 → 9
export fn digits(x: u8) u8 {
    return plus1(x >> 4) +% plus1(x & 0x0F);
}

// 调完再用参数做别的（不是实参）：0x34 → 0x35 + 0x34 = 0x69
export fn after(x: u8) u8 {
    const y: u8 = plus1(x);
    return y +% x;
}