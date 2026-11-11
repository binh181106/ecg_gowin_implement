#!/usr/bin/env python3
"""Offline decoder + capture checker for the demo UART result packets.

The parser is testable WITHOUT a board: it operates on a raw byte stream
(a .bin capture, the demo testbench's dumped bytes, or a live serial port if
pyserial is available — optional, not required).

Protocol (see src/demo_uart_packetizer.v):
    33 bytes, 16-bit fields little-endian, features two's complement:
      [0]=0xE7 [1]=0xA5 [2]=type 0x01 [3]=len 28
      [4..5]=win_index [6..29]=f0..f11 (12 x 16-bit)
      [30]=class_code(2b) [31]=flags(bit0 adc,bit1 feat,bit2 mlp overflow)
      [32]=checksum = sum(bytes[2..31]) mod 256

The checksum scope is bytes 2..31 INCLUSIVE, i.e. every byte actually
received in that range. The checksum is therefore verified against the
REAL received bytes, never against golden values.

Usage:
    python -I src/uart_decode.py                  -> self-test
    python -I src/uart_decode.py capture.bin      -> decode & print packets
    python -I src/uart_decode.py --check capture.bin
        -> full acceptance check against src/golden/expected_packets.json.
           Exit code 0 = capture meets the acceptance criteria, 1 = it does
           not, 2 = usage / IO error.
    python -I src/uart_decode.py --check capture.bin --golden src/golden/g21_signed/expected_packets.json
        -> explicitly select G2.1 signed preprocessing; mode is not in the packet.

Acceptance criteria for --check (a clean demo capture):
    * exactly 231 bytes total (7 packets x 33 bytes)
    * exactly 7 packets, each 33 bytes, correct framing
      (sync 0xE7 0xA5, type 0x01, len 28)
    * window indices 1..7, in order
    * every packet's checksum verifies against its own received bytes
    * EVERY byte equals the golden byte (byte position, expected and actual
      are reported on mismatch). The golden mirrors the RTL arithmetic
      exactly — including the 28-bit restoring divider used for f_crest and
      f_rr_ratio — so all 33 bytes are asserted (strict_mask is all 1s).
      There are no open / masked / tool-dependent bytes.

Provenance note: the golden records the source revision and the SHA256 of
src/ecg_rom.hex it was generated from. A capture is only comparable
byte-exact if it was produced from that same revision and ROM image. When
checking an older capture, treat any mismatch as "possibly a stale
artifact" until the bitstream origin is confirmed.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

SYNC1, SYNC2, PKTLEN = 0xE7, 0xA5, 33
N_PACKETS = 7
CAPTURE_BYTES = N_PACKETS * PKTLEN          # 231


def checksum_of(body: bytes) -> int:
    """checksum = sum(bytes[2..31]) mod 256 — the bytes actually received."""
    return sum(body[2:32]) & 0xFF


def decode_stream(data: bytes):
    """Yield (offset, packet_dict) for every valid packet found in `data`.

    Resyncs on E7 A5 after any garbage; a packet is accepted only when its
    checksum verifies. Never raises on malformed input.
    """
    i, n = 0, len(data)
    while i + PKTLEN <= n:
        if data[i] == SYNC1 and data[i + 1] == SYNC2:
            body = data[i:i + PKTLEN]
            chk = checksum_of(body)
            if chk == body[32] and body[2] == 0x01 and body[3] == 28:
                feats = []
                for k in range(12):
                    lo, hi = body[6 + 2 * k], body[7 + 2 * k]
                    v = hi * 256 + lo
                    feats.append(v - 65536 if v & 0x8000 else v)
                yield i, {
                    "win_index": body[4] | (body[5] << 8),
                    "features": feats,
                    "class": body[30] & 0x3,
                    "flags": body[31] & 0x7,
                    "checksum": body[32],
                }
                i += PKTLEN
            else:
                i += 2
        else:
            i += 1


def find_packets(data: bytes):
    """Return the list of (offset, raw 33-byte body) for every frame found.

    Unlike decode_stream() this does NOT require a valid checksum, so a
    corrupt packet is still REPORTED (as a bad frame) instead of silently
    vanishing from the packet count.
    """
    out = []
    i, n = 0, len(data)
    while i + PKTLEN <= n:
        if data[i] == SYNC1 and data[i + 1] == SYNC2:
            out.append((i, data[i:i + PKTLEN]))
            i += PKTLEN
        else:
            i += 1
    return out


def check_capture(data: bytes, golden: dict):
    """Full acceptance check of a capture against the golden.

    Returns (ok: bool, lines: list[str]). `lines` is the report to print.
    """
    lines = []
    ok = True

    def fail(msg):
        nonlocal ok
        ok = False
        lines.append(f"FAIL {msg}")

    def info(msg):
        lines.append(f"     {msg}")

    wins = golden["windows"]
    exp_packets = [bytes(w["packet"]) for w in wins]
    exp_masks = [w["strict_mask"] for w in wins]

    # ---- 1. total size -----------------------------------------------------
    if len(data) != CAPTURE_BYTES:
        fail(f"capture size {len(data)} bytes, expected exactly "
             f"{CAPTURE_BYTES} ({N_PACKETS} packets x {PKTLEN})")
    else:
        info(f"size {len(data)} bytes = {N_PACKETS} x {PKTLEN}  OK")

    # ---- 2. packet count ----------------------------------------------------
    frames = find_packets(data)
    if len(frames) != N_PACKETS:
        fail(f"found {len(frames)} packet frames, expected {N_PACKETS}")
    else:
        info(f"packet frames {len(frames)}  OK")

    # ---- 3. per-packet framing + checksum ----------------------------------
    for idx, (off, body) in enumerate(frames):
        tag = f"pkt#{idx} @{off}"
        if len(body) != PKTLEN:
            fail(f"{tag}: length {len(body)} != {PKTLEN}")
            continue
        if body[0] != SYNC1 or body[1] != SYNC2:
            fail(f"{tag}: bad sync {body[0]:02X} {body[1]:02X} "
                 f"(expected {SYNC1:02X} {SYNC2:02X})")
        if body[2] != 0x01:
            fail(f"{tag}: bad type 0x{body[2]:02X} (expected 0x01)")
        if body[3] != 28:
            fail(f"{tag}: bad len {body[3]} (expected 28)")
        chk = checksum_of(body)
        if chk != body[32]:
            fail(f"{tag}: checksum 0x{body[32]:02X} != computed 0x{chk:02X} "
                 f"(sum of received bytes 2..31)")
        else:
            info(f"{tag}: framing + checksum 0x{chk:02X}  OK")

    # ---- 4. window index order ---------------------------------------------
    got_idx = [body[4] | (body[5] << 8) for _, body in frames]
    want_idx = [w["win_index"] for w in wins]
    if got_idx != want_idx:
        fail(f"window index order {got_idx}, expected {want_idx}")
    else:
        info(f"window indices {got_idx} in order  OK")

    # ---- 5. byte-exact comparison + (still-supported) masked differences --
    # The golden is now all-strict, so any difference is a FAIL. The mask
    # loop below remains correct: a mask[k]==0 byte would be REPORTED but
    # not fatal, in case a future golden re-introduces an open byte. For
    # the current all-1 mask every differing byte is a strict mismatch.
    for idx, (off, body) in enumerate(frames):
        if idx >= len(wins):
            fail(f"pkt#{idx}: more packets than golden windows")
            break
        mask = exp_masks[idx]
        strict_bad, open_bad = [], []
        for k in range(PKTLEN):
            if body[k] != exp_packets[idx][k]:
                if mask[k]:
                    strict_bad.append(k)
                else:
                    open_bad.append(k)
        if strict_bad:
            names = {16: "f_crest[7:0]", 17: "f_crest[15:8]", 32: "checksum"}
            for k in strict_bad:
                fail(f"pkt#{idx} @{off} byte[{k}]"
                     f"{' (' + names[k] + ')' if k in names else ''} "
                     f"strict mismatch: "
                     f"expected 0x{exp_packets[idx][k]:02X}, "
                     f"actual 0x{body[k]:02X}")
        if open_bad:
            names = {16: "f_crest[7:0]", 17: "f_crest[15:8]", 32: "checksum"}
            desc = ", ".join(
                f"byte[{k}]({names.get(k, 'masked')}) expected "
                f"0x{exp_packets[idx][k]:02X} actual 0x{body[k]:02X}"
                for k in open_bad)
            info(f"pkt#{idx} @{off} MASKED difference (reported, not fatal): "
                 f"{desc}")
        if not strict_bad and not open_bad:
            info(f"pkt#{idx} @{off}: all 33 bytes match golden  OK")

    lines.append("CHECK RESULT: " + ("PASS" if ok else "FAIL"))
    return ok, lines


def _load_golden(path=None):
    return json.loads((Path(path) if path else HERE / "golden" / "expected_packets.json").read_text())


def _rebuild(body: bytes) -> bytes:
    """Return body with a freshly computed checksum (bytes 2..31 scope)."""
    b = bytearray(body)
    b[32] = checksum_of(bytes(b))
    return bytes(b)


def self_test():
    golden = _load_golden()
    wins = golden["windows"]
    exp_packets = [bytes(w["packet"]) for w in wins]
    stream = b"".join(exp_packets)

    # --- case 1: a clean capture must PASS --------------------------------
    ok, lines = check_capture(stream, golden)
    assert ok, "clean capture must pass:\n" + "\n".join(lines)
    assert len(list(decode_stream(stream))) == N_PACKETS

    # --- case 2: a missing packet must FAIL --------------------------------
    ok2, _ = check_capture(b"".join(exp_packets[:3] + exp_packets[4:]), golden)
    assert not ok2, "missing packet must fail the check"

    # --- case 3: reordered packets must FAIL -------------------------------
    reordered = [exp_packets[1], exp_packets[0]] + exp_packets[2:]
    ok3, _ = check_capture(b"".join(reordered), golden)
    assert not ok3, "reordered packets must fail the check"

    # --- case 4: a corrupt checksum must FAIL ------------------------------
    bad = bytearray(stream)
    bad[32] ^= 0xFF
    ok4, _ = check_capture(bytes(bad), golden)
    assert not ok4, "bad checksum must fail the check"

    # --- case 5: a wrong STRICT byte with a RECOMPUTED checksum must FAIL --
    tampered = bytearray(exp_packets[0])
    tampered[6] ^= 0x01                 # f_rms low byte — a strict byte
    p5 = _rebuild(bytes(tampered)) + b"".join(exp_packets[1:])
    ok5, lines5 = check_capture(p5, golden)
    assert not ok5, "wrong strict byte must fail even with a valid checksum"
    assert any("strict mismatch" in l for l in lines5), lines5

    # --- case 6: a changed CREST byte with a valid checksum must FAIL ------
    # (strict_mask is all 1s, so f_crest is a strict byte; the checker must
    #  FAIL and report byte 16 = f_crest[7:0], not merely report it.)
    tampered2 = bytearray(exp_packets[0])
    tampered2[16] ^= 0x20              # f_crest low byte — a STRICT byte now
    p6 = _rebuild(bytes(tampered2)) + b"".join(exp_packets[1:])
    ok6, lines6 = check_capture(p6, golden)
    assert not ok6, "changed crest byte must fail the check:\n" + \
        "\n".join(lines6)
    # The report must name byte 16 and identify it as the f_crest low byte.
    assert any("byte[16]" in l for l in lines6), lines6
    assert any("f_crest" in l for l in lines6), lines6

    # --- the parser still rejects a corrupt checksum -----------------------
    assert len(list(decode_stream(bytes(bad)))) == N_PACKETS - 1
    # --- resync after garbage prefix ---------------------------------------
    assert len(list(decode_stream(b"\x00\x01\x02" + stream))) == N_PACKETS

    print(f"PASS uart_decode self-test: {N_PACKETS} golden packets decoded, "
          f"corrupt-checksum rejected, resync ok")
    print("PASS uart_decode check cases: clean=PASS missing=FAIL "
          "reorder=FAIL badsum=FAIL strict-byte=FAIL crest-byte=FAIL")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--check":
        if not (len(args) == 2 or (len(args) == 4 and args[2] == "--golden")):
            print("usage: uart_decode.py --check <capture.bin> [--golden <expected.json>]",
                  file=sys.stderr)
            sys.exit(2)
        path = Path(args[1])
        try:
            blob = path.read_bytes()
            golden = _load_golden(args[3] if len(args) == 4 else None)
        except (OSError, ValueError) as e:
            print(f"ERROR cannot read capture/golden: {e}", file=sys.stderr)
            sys.exit(2)
        ok, report = check_capture(blob, golden)
        print(f"== capture check: {path} ({len(blob)} bytes) ==")
        for line in report:
            print(line)
        sys.exit(0 if ok else 1)
    elif args:
        blob = Path(args[0]).read_bytes()
        for off, pkt in decode_stream(blob):
            print(f"@{off:6d} win={pkt['win_index']} class={pkt['class']} "
                  f"flags={pkt['flags']:b} feats={pkt['features']}")
    else:
        self_test()
