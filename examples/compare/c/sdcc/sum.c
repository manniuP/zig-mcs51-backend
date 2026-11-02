unsigned char sum(unsigned char n) {
    unsigned char s = 0, i = 0;
    while (i < n) { s += i; i++; }
    return s;
}
