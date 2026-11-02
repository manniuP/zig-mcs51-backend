unsigned long f(unsigned char i, unsigned long a, unsigned long b) { volatile unsigned long __xdata *p = (volatile unsigned long __xdata *)0x8400; p[i] = a; p[i + 1] = b; return p[i] + p[i + 1]; }
