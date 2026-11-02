//! 函数指针表：`table[i]` 取地址 → `@ptrFromInt` → 间接调用。
//! 地址用 @intFromPtr 取得（**函数地址当值**），表本身是普通全局 u16 数组（符号基址）。

var fpt: [3]u16 = undefined;

fn f_inc(x: u8) u8 {
    return x +% 1;
}

fn f_dbl(x: u8) u8 {
    return x +% x;
}

fn f_neg(x: u8) u8 {
    return ~x;
}

// 填表 + 依次调用三项：x=10 → 11 + 22 + (~12 = 0xF3) = 276 → 0x14（u8 回绕）
export fn fpt_all(x: u8) u8 {
    fpt[0] = @truncate(@intFromPtr(&f_inc));
    fpt[1] = @truncate(@intFromPtr(&f_dbl));
    fpt[2] = @truncate(@intFromPtr(&f_neg));
    var acc: u8 = 0;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const fp: *const fn (u8) u8 = @ptrFromInt(fpt[i]);
        acc = acc +% fp(x +% i);
    }
    return acc;
}