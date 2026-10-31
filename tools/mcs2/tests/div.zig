//! 多字节除法/取余（恢复法循环，8n 轮）。
//! 1000 / 7 = 142 余 6（余数取 1000-142*7=6，能同时验商和余数链路）

export fn u16div(a: u16, b: u16) u16 {
    return a / b;
}

export fn u16rem(a: u16, b: u16) u16 {
    return a % b;
}
