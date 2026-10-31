
import subprocess
from pathlib import Path
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build")
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
mp = (B / "call_ind.map").read_text(errors="replace") if (B/"call_ind.map").exists() else ""
import re
for line in mp.splitlines():
    if "_inc8" in line or "_call_ind" in line:
        print("MAP:", line.strip())
cmds = "break 0x77\nrun\nquit\n"
r = subprocess.run([uc, "-t", "8052", str(B / "call_ind.ihx")], input=cmds,
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
print(((r.stdout or "") + (r.stderr or ""))[-700:])
