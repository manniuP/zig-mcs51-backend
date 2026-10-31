//! 运行期 xdata 下标 + 位运算：UART RX 环（buf[i]）的前置能力。
//!
//! memrt：固定基址 0x8100 + 运行期下标 → 写/读同一个格子，验证 dptr = base + idx。
//! bitfn / xor2：位与/或/异或立即数。
const buf: [*]u8 = @ptrFromInt(0x8100);

export fn memrt(i: u8) u8 {
    buf[i] = i | 0x40;
    return buf[i] & 0x7F;
}

export fn bitfn(a: u8) u8 {
    return (a & 0x0F) | 0x80;
}

export fn xor2(a: u8) u8 {
    return a ^ 0xAA;
}
// 走 cmp_br(ne)：一个与运行期值比、一个与立即数比（发射层 cjne 分支）。
export fn ne5(a: u8) u8 {
    var i: u8 = 0;
    var n: u8 = 0;
    while (i != a) : (i += 1) {
        n +%= 1;
    }
    return n;
}

export fn ne_imm() u8 {
    var i: u8 = 0;
    while (i != 3) : (i += 1) {}
    return i;
}
