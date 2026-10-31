
import sys
sys.path.insert(0, r"E:\code\yuyan\zig-0.17\tools\mcs2")
from pathlib import Path
import mcs2
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build")
p = B / "retorder.asm"
p.write_text("    .area CSEG (CODE)\n    ljmp _m\n_m:\n    mov sp,#0x7F\n    mov a,#>(_r1)\n    push 0xE0\n    mov a,#<(_r1)\n    push 0xE0\n    ret\n_w: mov dptr,#0x8000\n    mov a,#0xAA\n    movx @dptr,a\n    sjmp .\n_r1: mov dptr,#0x8000\n    mov a,#0x55\n    movx @dptr,a\n    sjmp .\n", encoding="utf-8")
ihx = mcs2.assemble(p, "retorder", dseg=0x30, cseg=0x0000)
v = mcs2.sim(ihx, steps=200, slots=1)
print("xdata 0x8000 =", hex(v.get(0x8000, 0)), "(0x55=压高再压低 正确；0xaa=顺序反了)")
