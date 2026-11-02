//! 乘/除/取余/取反（u8）：8051 的 MUL AB / DIV AB / CPL A。
export fn mul8(a: u8, b: u8) u8 {
    return a *% b;
}

export fn div8(a: u8, b: u8) u8 {
    return a / b;
}

export fn rem8(a: u8, b: u8) u8 {
    return a % b;
}

export fn not8(a: u8) u8 {
    return ~a;
}

// XNOR：与或非的组合（~（a ^ b)），验取反能参与表达式
export fn xnor8(a: u8, b: u8) u8 {
    return ~(a ^ b);
}