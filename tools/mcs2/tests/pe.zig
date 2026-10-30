//! 部分求值专用：无参、纯 u8 计算，期望编译期折叠成常量。
export fn pe_sum() u8 {
    var s: u8 = 0;
    var i: u8 = 0;
    while (i < 25) : (i += 1) {
        s +%= i;
    }
    return s;
}
