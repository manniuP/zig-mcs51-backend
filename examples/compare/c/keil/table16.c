unsigned int f(unsigned char i, unsigned int v) { volatile unsigned int xdata *p = (volatile unsigned int xdata *)0x8200; p[i] = v; return p[i]; }
