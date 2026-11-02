//! 探针：16 位 & 32 位**运行期移位次数**（8 位已有 shlv/shrv/sarv 覆盖）。

export fn s16r(v: i16, n: u8) i16 {
    return v >> @intCast(n);
}

export fn u16l(v: u16, n: u8) u16 {
    return v << @intCast(n);
}

export fn u32l(v: u32, n: u8) u32 {
    return v << @intCast(n);
}