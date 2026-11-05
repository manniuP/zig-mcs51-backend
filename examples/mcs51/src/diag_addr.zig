// 改写建议用例：数据地址当整数暂不支持。
const buf = [_]u8{ 1, 2, 3, 4 };

export fn diag_addr() u16 {
    return @truncate(@intFromPtr(&buf[0]));
}
