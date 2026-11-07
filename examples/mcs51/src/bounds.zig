// 边界检查覆盖度复核：ReleaseSafe 下前端应当为**每一个运行期下标**发 trap，
// 越界时后端跳 _mcs_panic（标记 0xA5）。这里把各种元素宽度与下标形态摆在一起，
// 用同一个函数体形状对照，缺哪一条一目了然。

const bytes = [_]u8{ 1, 2, 3, 4 };
const words = [_]u16{ 100, 200, 300, 400 };
const dwords = [_]u32{ 1, 2, 3, 4 };
const grid = [2][3]u8{ .{ 1, 2, 3 }, .{ 4, 5, 6 } };

// ① 单字节元素（已有用例，作为基线）
export fn bnd_u8(i: u8) u8 {
    return bytes[i];
}

// ② 16 位元素：步长 2，越界判据仍按元素个数
export fn bnd_u16(i: u8) u16 {
    return words[i];
}

// ③ 32 位元素：步长 4
export fn bnd_u32(i: u8) u32 {
    return dwords[i];
}

// ④ 多维：两维各自都要判
export fn bnd_grid(i: u8, j: u8) u8 {
    return grid[i][j];
}

// ⑤ 指针下标：Zig 语义里 [*] 不带长度，**不该**有边界检查（有就是多余的）
export fn bnd_ptr(p: [*]const u8, i: u8) u8 {
    return p[i];
}

// ⑥ 数组上取切片再下标：切片带长度，必须判
export fn bnd_slice(i: u8) u8 {
    const s = bytes[1..3];
    return s[i];
}
