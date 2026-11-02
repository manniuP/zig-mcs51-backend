//! 固定地址的**多字节**读写（u32 外设块 / 全局）：逐字节 store_xdata/load_xdata。
//! 放在 0x8100 而不是 0x8000：测试驱动会把返回值写到 0x8000，同址会互相覆盖。

const P: *volatile u32 = @ptrFromInt(0x8100);

export fn wstore(v: u32) void {
    P.* = v;
}

export fn wload() u32 {
    return P.*;
}

// 存进去再读回来（同一函数里验证两条路径）
export fn wround(v: u32) u32 {
    P.* = v +% 1;
    return P.*;
}

// 存参数本身（不做运算）再读回
export fn wround2(v: u32) u32 {
    P.* = v;
    return P.*;
}
// 纯宽加 +1（不碰内存）：隔离「宽加丢常数」的怀疑
export fn addone(v: u32) u32 {
    return v +% 1;
}