
import serial, re
try:
    with serial.Serial("COM14", 115200, timeout=2.5) as sp:
        sp.reset_input_buffer()
        data = b""
        import time
        t_end = time.time() + 4.0
        while time.time() < t_end:
            c = sp.read(256)
            if c: data += c
except Exception as e:
    print("PORT ERR:", type(e).__name__, e); raise SystemExit
lines = [l.strip() for l in data.split(b"\r\n") if b"=" in l]
seen = []
for l in lines:
    try: s = l.decode()
    except Exception: continue
    if re.match(r"^[a-z0-9_]+=[0-9A-Fa-f]+$", s) and s not in seen:
        seen.append(s)
print(f"{len(data)} bytes, {len(seen)} 种行:")
for s in seen: print("  ", s)
