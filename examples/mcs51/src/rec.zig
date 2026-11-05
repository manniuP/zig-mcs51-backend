// 非尾递归：静态参数区与局部槽不可重入，后端必须编译期明确拒绝，
// 而不是静默生成会算错的代码。
// 故意不登记进 cases.txt（示例构建不编它），只由 tools/mcs2 的拒绝用例使用。
export fn rec_bad(n: u8) u8 {
    if (n <= 1) return 1;
    return rec_bad(n - 1) + 1;
}
