//! 8/16 位有符号除法：DIV AB 只有无符号，走同一条模板。

// -100 / 7 = -14 → 0xF2
export fn i8div(a: i8, b: i8) i8 {
    return @divTrunc(a, b);
}

// -100 % 7 = -2 → 0xFE
export fn i8rem(a: i8, b: i8) i8 {
    return @rem(a, b);
}

// -1000 / 7 = -142 → 0xFF72
export fn i16div(a: i16, b: i16) i16 {
    return @divTrunc(a, b);
}
