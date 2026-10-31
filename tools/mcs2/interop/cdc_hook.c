/* USB-CDC 混编实验的 **C 侧**（SDCC, -mmcs51 --model-large，与 usb_cdc 示例同参数）。
 *
 * 这里扮演 usb_cdc 的回调：C 负责外设与协议，把纯计算交给 Zig。
 * 参数/返回只用定长整数 —— 与 docs/03 的约定一致。
 */
extern unsigned char zig_cdc_mix(unsigned char x);
extern unsigned long zig_cdc_hash(unsigned long a, unsigned long b);

volatile unsigned char out8;
volatile unsigned long out32;

void main(void)
{
    out8 = zig_cdc_mix(0x21);
    out32 = zig_cdc_hash(0x12345678UL, 0x000000FFUL);
    while (1) {
    }
}
