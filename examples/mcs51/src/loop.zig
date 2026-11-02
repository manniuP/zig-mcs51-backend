//! M2 验收：while 循环（cmp_lt → cmp_br + 回边）。
export fn sum(n: u8) u8 {
    var s: u8 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        s +%= i;
    }
    return s;
}

// 无参 + 纯 u8 计算：部分求值（切片 A）应把它折成常量。
export fn sum_to_fold() u8 {
    var s: u8 = 0;
    var i: u8 = 0;
    while (i < 25) : (i += 1) {
        s +%= i;
    }
    return s;
}

// 递减循环：djnz 候选（i != 0 的形态）。
export fn cnt(n: u8) u8 {
    var c: u8 = 0;
    var i: u8 = n;
    while (i != 0) : (i -%= 1) {
        c +%= 1;
    }
    return c;
}
