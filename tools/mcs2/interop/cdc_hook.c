/* USB-CDC 混编实验的 **C 侧**（SDCC, -mmcs51 --model-large，与 usb_cdc 示例同参数）。
 *
 * 这里扮演 usb_cdc 的回调：C 负责外设与协议，把纯计算交给 Zig。
 * 参数/返回只用定长整数 —— 与 docs/03 的约定一致。
 */
extern unsigned char zig_cdc_mix(unsigned char x);
extern unsigned long zig_cdc_hash(unsigned long a, unsigned long b);
extern unsigned char zig_calls_c(unsigned char x);
extern unsigned char zig_two_void_calls(unsigned char x);

/* 给 Zig 侧的 extern fn c_scale 提供实现（Zig→C 方向，M2.5 解锁）。 */
unsigned char c_scale(unsigned char x)
{
    return (unsigned char)(x * 2);
}

/* 无参无返回的 C 函数（void f(void)）——Zig 侧 extern fn 直接调；
   多份实例就是多个不同的符号名（fun_1 / fun_2 …）。 */
volatile unsigned char c_calls;

void c_ping(void)
{
    c_calls = (unsigned char)(c_calls + 1);
}

void c_ping2(void)
{
    c_calls = (unsigned char)(c_calls + 1);
}

volatile unsigned char out8;
volatile unsigned char out8b;
volatile unsigned char out8c;
volatile unsigned long out32;

void main(void)
{
    out8 = zig_cdc_mix(0x21);
    out8b = zig_calls_c(0x10);   /* 期望 (0x10*2)+1 = 0x21：Zig 调 C 再回 Zig */
    out8c = zig_two_void_calls(0x40);   /* 期望 0x41；同时 c_calls 应为 2（两个 void 调用都执行了） */
    out32 = zig_cdc_hash(0x12345678UL, 0x000000FFUL);
    while (1) {
    }
}
