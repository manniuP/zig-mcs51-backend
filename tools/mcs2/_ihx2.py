
from pathlib import Path
p = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build\call_ind.ihx")
mem = {}
for line in p.read_text().splitlines():
    line = line.strip()
    if not line.startswith(":"): continue
    n = int(line[1:3],16); addr = int(line[3:7],16); typ = int(line[7:9],16)
    if typ == 0:
        for i,b in enumerate(bytes.fromhex(line[9:9+2*n])): mem[addr+i] = b
print("0x60..0x7A:", " ".join(f"{mem.get(a,0):02X}" for a in range(0x60,0x7B)))
print("期望：74 00 C0 E0 74 77 C0 E0 ...")
