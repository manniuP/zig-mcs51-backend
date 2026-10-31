
from pathlib import Path
p = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build\chain32.ihx")
mem = {}
for line in p.read_text().splitlines():
    line = line.strip()
    if not line.startswith(":"): continue
    n = int(line[1:3],16); addr = int(line[3:7],16); typ = int(line[7:9],16)
    data = bytes.fromhex(line[9:9+2*n])
    if typ == 0:
        for i,b in enumerate(data): mem[addr+i] = b
print("0x40..0x69:", " ".join(f"{mem.get(a,0):02X}" for a in range(0x40,0x6A)))
print("mov a,0xE0 处:", f"{mem.get(0x57,0):02X} {mem.get(0x58,0):02X}", " 期望 E5 E0")
print("lcall 处:", f"{mem.get(0x48,0):02X} {mem.get(0x49,0):02X} {mem.get(0x4a,0):02X}")
