//! M1 收尾用例：局部变量落帧（alloc/store/load）+ 常量操作数路径。
//! addrfn 的指针会被 Sema 折叠成常量加法——正是 refLoc 常量支路的检验。
export fn varfn(a: u8) u8 {
    var x: u8 = a;
    x +%= 1;
    return x;
}
export fn addrfn(a: u8) u8 {
    var x: u8 = a;
    const p: *u8 = &x;
    p.* +%= 1;
    return p.*;
}
