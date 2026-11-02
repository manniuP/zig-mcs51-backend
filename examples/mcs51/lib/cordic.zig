//! CORDIC 定点数学库（8051 友好）：只用加减和算术右移，**没有乘法循环**。
//!
//! 约定：
//!   * 角度 = **二进制角**：一圈 = 65536，用 `i16` 承载（「0..65535 回绕」就是二补码加减）。
//!     45° = 0x2000，90° = 0x4000，180° = -32768。
//!   * 三角函数输出 **Q14**（±16384 = ±1.0）——中间量不会溢出 i16。
//!   * 全部纯函数、无全局状态、无分配、**不用浮点**。
//!   * 每个函数自包含（不用 struct 返回：后端还不支持结构体返回值）。
//!
//! 用法：`@import("cordic")`（构建时注入模块名 `cordic`，见 tools/mcs2/mcs2.py）。

pub const Angle = i16;

/// Q14：±16384 = ±1.0
pub const Q14: i16 = 16384;

/// atan(2^-i) 的二进制角（12 项）
const atan_table = [12]i16{
    8192, 4836, 2555, 1297, 651, 326,
    163,  81,   41,   20,   10,  5,
};

/// 1/K = 0.607253 × 16384 ≈ 9949：预缩放后旋转的模长正好是 Q14。
const k_init: i16 = 9949;

/// 90° 的二进制角
const quarter: i16 = 0x4000;

/// cos(二进制角) → Q14
pub fn cos(a: Angle) i16 {
    var z: i16 = a;
    var q: u8 = 0;
    if (z > quarter) {
        z -%= quarter;
        q = 1;
    } else if (z < -quarter) {
        z +%= quarter;
        q = 2;
    }
    var x: i16 = k_init;
    var y: i16 = 0;
    var i: u8 = 0;
    while (i < 12) : (i += 1) {
        const shift: u4 = @intCast(i);
        const xr: i16 = x >> shift;
        const yr: i16 = y >> shift;
        const step: i16 = atan_table[i];
        if (z >= 0) {
            x -%= yr;
            y +%= xr;
            z -%= step;
        } else {
            x +%= yr;
            y -%= xr;
            z +%= step;
        }
    }
    if (q == 1) return -y;
    if (q == 2) return y;
    return x;
}

/// sin(二进制角) → Q14
pub fn sin(a: Angle) i16 {
    var z: i16 = a;
    var q: u8 = 0;
    if (z > quarter) {
        z -%= quarter;
        q = 1;
    } else if (z < -quarter) {
        z +%= quarter;
        q = 2;
    }
    var x: i16 = k_init;
    var y: i16 = 0;
    var i: u8 = 0;
    while (i < 12) : (i += 1) {
        const shift: u4 = @intCast(i);
        const xr: i16 = x >> shift;
        const yr: i16 = y >> shift;
        const step: i16 = atan_table[i];
        if (z >= 0) {
            x -%= yr;
            y +%= xr;
            z -%= step;
        } else {
            x +%= yr;
            y -%= xr;
            z +%= step;
        }
    }
    if (q == 1) return x;
    if (q == 2) return -x;
    return y;
}

/// atan2(y, x) → 二进制角（向量模式：把 (x,y) 转到 x 轴，累计角度就是 atan2）。
/// `x = y = 0` 没有数学意义，这里会返回 ≈+90°，不要依赖。
pub fn atan2(y: i16, x: i16) Angle {
    var xx: i16 = x;
    var yy: i16 = y;
    var z: i16 = 0;
    // **统一先减半**：CORDIC 第一轮里 x±y 会到 |x|+|y|，16384+16384 就溢出 i16；
    // 减半按比例，角度不变，只丢 1 位精度（所以 atan2 的有效精度是 13 位左右）。
    xx >>= 1;
    yy >>= 1;
    var i: u8 = 0;
    while (i < 12) : (i += 1) {
        const shift: u4 = @intCast(i);
        const xr: i16 = xx >> shift;
        const yr: i16 = yy >> shift;
        const step: i16 = atan_table[i];
        if (yy >= 0) {
            xx +%= yr;
            yy -%= xr;
            z +%= step;
        } else {
            xx -%= yr;
            yy +%= xr;
            z -%= step;
        }
    }
    return z;
}

/// 整数平方根（逐位试差，纯移位减法，无乘法）。
pub fn sqrt32(v: u32) u16 {
    var n: u32 = v;
    var res: u32 = 0;
    var bit: u32 = 0x4000_0000;
    while (bit != 0) : (bit >>= 2) {
        if (n >= res + bit) {
            n -= res + bit;
            res = (res >> 1) + bit;
        } else {
            res >>= 1;
        }
    }
    return @truncate(res);
}

/// 向量长度 sqrt(x²+y²)（x、y 同尺度，结果同尺度）。
pub fn hypot(x: i16, y: i16) u16 {
    const ax: u32 = absU(x);
    const ay: u32 = absU(y);
    return sqrt32(ax *% ax +% ay *% ay);
}

/// Q14 乘法：两个 Q14 相乘再折回 Q14。
pub fn mulQ14(a: i16, b: i16) i16 {
    const p: i32 = @as(i32, a) *% @as(i32, b);
    return @truncate(p >> 14);
}

fn absU(v: i16) u32 {
    if (v < 0) {
        return @intCast(-@as(i32, v));
    }
    return @intCast(v);
}