// 改写建议用例：ReleaseSafe 下多字节乘法溢出检查尚未实现。
// 故意不登记进 cases.txt（示例构建不编它）。
export fn diag_mul(a: u16, b: u16) u16 {
    return a * b;
}
