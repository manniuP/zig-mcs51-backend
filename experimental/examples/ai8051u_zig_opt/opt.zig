//! opt.zig — 内存层级放置（data/idata/edata）+ 优化等级（O0/O5）演示，UART 实机核验。
//!
//! 每轮输出**固定**：`opt 11223344 060a`（可逐字节核对）。
//!   v_data=0x11、v_idata=0x22、v_edata=0x33、v_auto=0x44（自动：≤2B→data）；
//!   acc_fast(4)=0+1+2+3=0x06（`O0`：速度优先）、acc_small(5)=0x0a（`O5`：体积优先）。
//!
//! 放置标签：`data`(直址,快) / `idata`(@r0) / `edata`(@dptr,251 片上)；无标签→编译器自决。
//! 优化等级：`O0`(最快/最占) … `O5`(最省/最慢)，默认 `O3`(平衡)；`O4/O5` 函数进 `COLD` 区。

const m = @import("mcs");

var v_data: u8 linksection(".data") = 0; // DSEG
var v_idata: u8 linksection(".idata") = 0; // ISEG
var v_edata: u8 linksection(".edata") = 0; // EDATA（@dptr）
var v_auto: u8 = 0; // 无标签 → 编译器自决

// 热函数：CSEG，按速度优化
export fn acc_fast(n: u8) linksection(".Ofast") u8 {
    var s: u8 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) s +%= i;
    return s;
}

// 冷函数：COLD 区，按体积优化
export fn acc_small(n: u8) linksection(".Os") u8 {
    var s: u8 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) s +%= i;
    return s;
}

export fn main() void {
    m.uartInit(40_000_000, 9600);
    v_data = 0x11;
    v_idata = 0x22;
    v_edata = 0x33;
    v_auto = 0x44;
    m.uartPuts("\r\nopt\r\n");
    while (true) {
        m.uartPuts("opt ");
        m.uartPutHex2(v_data); // 11
        m.uartPutHex2(v_idata); // 22
        m.uartPutHex2(v_edata); // 33
        m.uartPutHex2(v_auto); // 44
        m.uartPuts(" ");
        m.uartPutHex2(acc_fast(4)); // 06
        m.uartPutHex2(acc_small(5)); // 0a
        m.uartPuts("\r\n");
        var t: u16 = 0;
        while (t < 6000) : (t += 1) {}
    }
}
