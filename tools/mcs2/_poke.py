
import serial
try:
    with serial.Serial("COM14", 115200, timeout=0.3) as sp:
        sp.write(bytes([0xA5, 0xA5, 0x7F, 0x7F]))
        sp.flush()
    print("POKED: 已发触发字节，当前固件(认任何字节)应已进 ISP")
except Exception as e:
    print("POKE_FAIL:", type(e).__name__, e)
