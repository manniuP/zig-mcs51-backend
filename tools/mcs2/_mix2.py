
import subprocess, re
from pathlib import Path
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\interop\build")
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
cmds = "step 6000\ndump iram 0x00 0x20\nquit\n"
r = subprocess.run([uc, "-t", "8052", str(B / "cdc_mix.ihx")], input=cmds,
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
out = (r.stdout or "") + (r.stderr or "")
mp = (B / "cdc_mix.map").read_text(errors="replace")
addrs = {}
for line in mp.splitlines():
    m = re.search(r"^(?:D|X):\s*([0-9A-Fa-f]{8})\s+(_out8b|_out8c|_c_calls)\b", line.strip())
    if m: addrs[m.group(2)] = int(m.group(1), 16)
print("map:", addrs)
for line in out.splitlines():
    if line.startswith("0x00") or line.startswith("0x08"):
        print(line)
