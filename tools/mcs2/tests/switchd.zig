//! 命令分发：mcs2 现在支持的形态 —— 语句 if 链。
//! switch（表达式形态）、enum 参数、tagged union 都还没做（见 M2.7）。

export fn dispatch(cmd: u8) u8 {
    var r: u8 = 0;
    if (cmd == 1) {
        r = 0x11;
    } else if (cmd == 2) {
        r = 0x22;
    } else if (cmd == 3) {
        r = 0x33;
    }
    return r;
}
