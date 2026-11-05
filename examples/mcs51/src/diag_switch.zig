// 改写建议用例：switch 判定值 > 8 位。
export fn diag_switch(x: u16) u8 {
    return switch (x) {
        1 => 1,
        else => 0,
    };
}
