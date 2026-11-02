//! **多字节全局变量**：`var g: u32` / `var g16: u16` 的写、读、读-改-写。
//! 形状刻意跨函数（写进全局，再从另一个函数读回）—— 同函数内写读可能自我一致，
//! 跨函数才能证明这真是全局符号、而且 4 个字节的地址与字节序都对。
//!
//! 注意：`var` 的初值**不会**在启动时装进去（XRAM 掉电即失，装载要走启动拷贝），
//! 所以用例一律「先写后读」，不依赖初值。

var g32: u32 = 0;
var g16: u16 = 0;

fn peek32() u32 {
    return g32;
}

fn peek16() u16 {
    return g16;
}

export fn wg32(v: u32) u32 {
    g32 = v;
    return peek32();
}

export fn wg16(v: u16) u16 {
    g16 = v;
    return peek16();
}

// 读-改-写：全局 u32 参与运算后再写回（比纯 store 多一轮 load + add + store）
export fn wginc(v: u32, step: u32) u32 {
    g32 = v;
    g32 = g32 +% step;
    return g32;
}

// 全局参与比较（宽比较走 cmp_wide_br）
export fn wgcmp(v: u32) u8 {
    g32 = v;
    return if (g32 > 0x1234) 1 else 0;
}
