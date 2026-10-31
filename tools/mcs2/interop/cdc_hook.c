/* USB-CDC 混编实验的 **C 侧**（SDCC, -mmcs51 --model-large，与 usb_cdc 示例同参数）。
 *
 * 这里扮演 usb_cdc 的回调：C 负责外设与协议，把纯计算交给 Zig。
 * 参数/返回只用定长整数 —— 与 docs/03 的约定一致。
 */
extern unsigned char zig_cdc_mix(unsigned char x);
extern unsigned long zig_cdc_hash(unsigned long a, unsigned long b);
extern unsigned char zig_calls_c(unsigned char x);

/* 给 Zig 侧的 extern fn c_scale 提供实现（Zig→C 方向，M2.5 解锁）。 */
unsigned char c_scale(unsigned char x)
{
    return (unsigned char)(x * 2);
}

volatile unsigned char out8;
volatile unsigned char out8b;
volatile unsigned long out32;

void main(void)
{
    out8 = zig_cdc_mix(0x21);
    out8b = zig_calls_c(0x10);   /* 期望 (0x10*2)+1 = 0x21：Zig 调 C 再回 Zig */
    out32 = zig_cdc_hash(0x12345678UL, 0x000000FFUL);
    while (1) {
    }
}
