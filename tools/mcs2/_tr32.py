
import subprocess
uc = r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe"
ihx = r"E:\code\yuyan\zig-0.17\tools\mcs2\build\chain32.ihx"
cmds = "step 2000\ndump iram 0x30 0x50\nquit\n"
r = subprocess.run([uc, "-t", "8052", ihx], input=cmds, capture_output=True, text=True,
                   encoding="utf-8", errors="replace")
out = (r.stdout or "") + (r.stderr or "")
print(out[-1400:])
