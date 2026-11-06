// 改写建议用例：ReleaseSafe 下 32 位乘法溢出检查尚未实现（16 位已支持）。
// 故意不登记进 cases.txt（示例构建不编它）。
export fn diag_mul(a: u32, b: u32) u32 {
    return a * b;
}
