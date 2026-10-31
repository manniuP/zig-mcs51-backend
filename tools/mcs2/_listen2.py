
import serial
for baud in (115200, 9600):
    try:
        with serial.Serial("COM14", baud, timeout=1.5) as sp:
            sp.reset_input_buffer()
            data = sp.read(400)
        print(f"--- {baud}: {len(data)} bytes")
        if data:
            print(repr(data[:200]))
    except Exception as e:
        print(f"--- {baud}: ERR {e}")
