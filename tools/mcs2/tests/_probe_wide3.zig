//! 探针：连续三个 i16 局部量（一个来自参数、一个是常量、一个是 0）会不会互相压槽。

export fn wide3(a: i16) i16 {
    var z: i16 = a;
    var x: i16 = 9949;
    var y: i16 = 0;
    z +%= 1;
    x +%= 2;
    y +%= 3;
    return x +% y +% z;
}