#ifdef __SDCC
#define XDATA __xdata
#else
#define XDATA xdata
#endif
#define BUF ((unsigned char XDATA *)0x8100)
unsigned char memrt(unsigned char i) {
    BUF[i] = i | 0x40;
    return BUF[i] & 0x7F;
}
