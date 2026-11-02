//! 环形缓冲（kfifo 思路的 8051 版）：u8 索引 + 掩码替代取模 + 单生产者单消费者。
//!
//! 验收：ringdemo(5) = 1+2+3+4+5 = 15。
//! ringdemo(20) 会让生产者跑过消费者（16 格环写 20 次）——真实驱动必须先查剩余空间，
//! 这里故意保留该语义，用来验证「索引只加不减、占用 = head - tail」的算法。
const buf: [*]u8 = @ptrFromInt(0x8200);
const mask: u8 = 0x0F; // 16 字节环：size 必须是 2 的幂，才能用 and 代替 %

export fn ringdemo(n: u8) u8 {
    var head: u8 = 0; // 生产者索引（只加不减，u8 自然回绕）
    var tail: u8 = 0; // 消费者索引
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        buf[head & mask] = i +% 1;
        head +%= 1;
    }
    var sum: u8 = 0;
    while (tail != head) {
        sum +%= buf[tail & mask];
        tail +%= 1;
    }
    return sum;
}
