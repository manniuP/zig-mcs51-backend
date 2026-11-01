
import subprocess
from pathlib import Path
B = Path(r"E:\code\yuyan\zig-0.17\tools\mcs2\build")
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
r = subprocess.run([uc, "-t", "8052", str(B / "t8get.ihx")],
                   input="step 300\ndump xram 0x8300 0x8308\ndump xram 0x8000 0x8004\nquit\n",
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
out = (r.stdout or "") + (r.stderr or "")
print("\n".join(l for l in out.splitlines() if l.startswith("0x8")))
