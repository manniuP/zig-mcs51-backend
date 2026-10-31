
import subprocess
from pathlib import Path
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build")
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
cmds = "step 2000\ndump xram 0x8000 0x8008\ndump xram 0x8100 0x8108\nquit\n"
r = subprocess.run([uc, "-t", "8052", str(B / "wround.ihx")], input=cmds,
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
out = (r.stdout or "") + (r.stderr or "")
print("\n".join(l for l in out.splitlines() if l.startswith("0x8")))
