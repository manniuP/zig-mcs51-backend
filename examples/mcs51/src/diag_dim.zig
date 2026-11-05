// 改写建议用例：const 常量表的二维下标。
const tbl = [_][2]u8{ .{ 1, 2 }, .{ 3, 4 } };

export fn diag_dim(i: u8, j: u8) u8 {
    return tbl[i][j];
}
