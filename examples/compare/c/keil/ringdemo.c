#ifdef __SDCC
#define XDATA __xdata
#else
#define XDATA xdata
#endif
#define BUF ((unsigned char XDATA *)0x8200)
unsigned char ringdemo(unsigned char n) {
    unsigned char head = 0, tail = 0, i = 0, sum = 0;
    while (i < n) { BUF[head & 0x0F] = i + 1; head++; i++; }
    while (tail != head) { sum += BUF[tail & 0x0F]; tail++; }
    return sum;
}
