
import serial
try:
    with serial.Serial("COM14", 115200, timeout=2.0) as sp:
        sp.reset_input_buffer()
        d = sp.read(120)
    print(f"COM14 OK: {len(d)} bytes {d[:50]!r}")
except Exception as e:
    print("COM14 ERR:", type(e).__name__, e)
