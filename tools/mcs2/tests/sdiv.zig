//! 有符号除法/取余：先取绝对值，商按符号异或定号、余数随被除数（C 截断语义）。
//! -100 / 7 = -14 余 -2（不是 floor 除法的 -15 余 5）

export fn i32div(a: i32, b: i32) i32 {
    return @divTrunc(a, b);
}

export fn i32rem(a: i32, b: i32) i32 {
    return @rem(a, b);
}
