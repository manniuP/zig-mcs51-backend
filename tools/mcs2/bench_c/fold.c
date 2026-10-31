unsigned char sum_to_fold(void) {
    unsigned char s = 0, i = 0;
    while (i < 25) { s += i; i++; }
    return s;
}
