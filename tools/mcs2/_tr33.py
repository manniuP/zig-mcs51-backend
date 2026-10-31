
import subprocess
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
ihx = r"E:\code\yuyan\zig-0.17\tools\mcs2\build\chain32.ihx"
cmds = "break 0x4b\nrun\nquit\n"
r = subprocess.run([uc, "-t", "8052", ihx], input=cmds, capture_output=True, text=True,
                   encoding="utf-8", errors="replace")
print(((r.stdout or "") + (r.stderr or ""))[-900:])
