// 数据地址当整数：以前只给改写建议（failFix），现在直接支持。
// const 表住在代码段，地址一样是 16 位线性地址，`@intFromPtr` 照常可用。
// 这里断言「偏移差」而不是绝对地址：绝对地址由链接器定，不能写死。
const buf = [_]u8{ 1, 2, 3, 4 };

export fn diag_addr() u16 {
    const a: u16 = @truncate(@intFromPtr(&buf[3]));
    const b: u16 = @truncate(@intFromPtr(&buf[0]));
    return a -% b;
}
