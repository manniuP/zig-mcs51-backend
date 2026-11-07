// 安全档 32 位无符号乘法溢出检查（ReleaseSafe / Debug 生效，ReleaseSmall 不加代码）。
//
// 判据：mulFull 算完整 64 位积，高 32 字节（bit32..63）任一字节非零即溢出。
// 单开文件：安全档的临时槽（8 B 工作副本 + 8 B 积 + 计数器）在 80 B DSEG 里
// 已经很挤，别和别的安全档用例挤同一个汇编单元。

export fn safe_mul32(a: u32, b: u32) u32 {
    return a * b;
}
