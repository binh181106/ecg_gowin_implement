import time
from pathlib import Path
import serial

PORT = "COM6"
BAUD = 115200
EXPECTED_BYTES = 231
TIMEOUT_SECONDS = 30

with serial.Serial(
    port=PORT,
    baudrate=BAUD,
    bytesize=serial.EIGHTBITS,
    parity=serial.PARITY_NONE,
    stopbits=serial.STOPBITS_ONE,
    timeout=0.2,
    xonxoff=False,
    rtscts=False,
    dsrdtr=False,
) as ser:

    ser.reset_input_buffer()

    print(f"UART opened: {PORT}, {BAUD} baud")
    print("ARMED - program FPGA NOW using Gowin Programmer")
    print("Capturing binary UART data...")

    data = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS

    while time.monotonic() < deadline:
        chunk = ser.read(EXPECTED_BYTES - len(data))

        if chunk:
            data.extend(chunk)
            print(f"Received: {len(data)}/{EXPECTED_BYTES} bytes")

        if len(data) >= EXPECTED_BYTES:
            break

Path("capture.bin").write_bytes(data)

print("\n=== CAPTURE RESULT ===")
print(f"Received: {len(data)} bytes")
print("Saved: capture.bin")
print("First bytes:", data[:16].hex(" ").upper())

if len(data) == EXPECTED_BYTES:
    print("CAPTURE SIZE: PASS")
else:
    print("CAPTURE SIZE: INCOMPLETE - inspect UART/FPGA")
