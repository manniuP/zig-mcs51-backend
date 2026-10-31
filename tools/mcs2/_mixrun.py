
import subprocess, re
from pathlib import Path
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\interop\build")
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
cmds = "step 4000\ndump iram 0x00 0x40\nquit\n"
r = subprocess.run([uc, "-t", "8052", str(B / "cdc_mix.ihx")], input=cmds,
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
out = (r.stdout or "") + (r.stderr or "")
mp = (B / "cdc_mix.map").read_text(errors="replace")
for line in mp.splitlines():
    if "_out8b" in line or "_out8 " in line:
        print("MAP:", line.strip())
print(out[-700:])
