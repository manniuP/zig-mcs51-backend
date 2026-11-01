//! AIR 转储探针：函数名以 _airdump 结尾 → 编 mcs2 时会打印该函数的 AIR 指令序列。
//! 用法：zig build-obj ... tests/airdump.zig 2>&1 | grep 'AIR\['

const T16: *volatile [8]u16 = @ptrFromInt(0x8200);
const T8: *volatile [8]u8 = @ptrFromInt(0x8300);

// u16 表：想看它到底降成什么（ptr_elem_ptr? array_elem_val? 还是别的）
export fn t16get_airdump(i: u8) u16 {
    return T16[i];
}

// u8 表（对照组）
export fn t8get_airdump(i: u8) u8 {
    return T8[i];
}
