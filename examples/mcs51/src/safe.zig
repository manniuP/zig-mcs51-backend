// 安全档（ReleaseSafe）溢出检查验收用例。
// 正常输入必须返回正确结果；溢出时 mcs2 发停机路径（sjmp .），不返回回绕值。
// 这组函数故意用普通运算符（+ - *），让前端按档位发 add_safe / sub_safe / mul_safe。

export fn safe_add(a: u8, b: u8) u8 {
    return a + b;
}

export fn safe_sub(a: u8, b: u8) u8 {
    return a - b;
}

export fn safe_mul(a: u8, b: u8) u8 {
    return a * b;
}

// 有符号加法走溢出标志 OV，不能拿进位标志 C 代替。
export fn safe_sadd(a: i8, b: i8) i8 {
    return a + b;
}

// 运行期下标的边界检查：安全档下前端发 trap，越界时后端停机。
const bounds_tbl = [_]u8{ 1, 2, 3, 4 };

export fn safe_bounds(i: u8) u8 {
    return bounds_tbl[i];
}
