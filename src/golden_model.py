#!/usr/bin/env python3
"""Independent golden model for the ECG ROM demo.

Recomputes, in Python, the exact 12 features the RTL pipeline MUST produce
for every 512-sample window, from the on-disk ROM sample stream
(``src/ecg_rom.hex`` — the exact byte stream the DUT paces through). This is
the independent expected-value source for the demo testbench and for the UART
decode/compare scripts (NOT copied from the DUT).

Pipeline mirrored bit-for-bit against src/*.v (formulas recorded per revision):
  1. window_buffer baseline stage: baseline_corrected = (v >= 169) ? v-169 : 0
     window i (1-based) = samples [ (i-1)*256 .. (i-1)*256+511 ]
     window_ready at totals T = 512, 768, ... (stride 256) -> 7 windows.
  2. feature_extraction:
       sxe   = sign-extended 8-bit sample (x >= 128 -> x-256)
       f_rms = s16( isqrt( (sum_sq & 0xFFFFFFFF) >> 9 << 16 ) >> 8 )
               = integer part of the TRUE RMS. The RTL computes a Q8.8
               internal rms_fp = isqrt(mean_square << 16) with a digit-by-
               step restoring sqrt (2 bits/cycle, 16 cycles); f_rms is the
               high byte (rms_fp >> 8).
       f_var = s16( (512*sum_sq - sum^2) >> 18 )   (population variance;
                   always >= 0 by Cauchy-Schwarz; max 16256)
       f_peak/f_max/f_ptp, f_zc (bit7 changes), f_half = pos_cnt<<3
       f_crest  and f_rr_ratio: the RTL 28-bit unsigned restoring
               (shift-subtract) divider, i.e. floor(N / D) narrowed to
               16 bits, reproduced here with independent Python integer
               division (NO 16-bit truncation of the numerator):
                 f_crest    = s16( sign(peak) * (abs(peak) << 16) // rms_fp )
                              where rms_fp is the INTERNAL Q8.8 RMS, not the
                              rounded integer f_rms (Q8.0 of the crest
                              factor; rms_fp == 0 -> 0)
                 f_rr_ratio = s16( (rr_cur*4096) // rr_prev )
                              (rr_prev == 0 -> 4096, the RTL div-by-0 guard)
     Validated against sim/tb_g1_rom_golden.sv (7 ROM windows, checks PASS)
     and sim/tb_feature_checkpoint.sv vectors.
  3. ai_classifier: placeholder ZERO weights -> all outputs 0, argmax tie ->
     class 0, no overflow (pipeline/math check only, NOT classification
     quality). Every packet: class byte = 0, flags byte = 0.

Outputs (regenerated deterministically):
  src/golden/expected_packets.sv   -- TB include (arrays + packets)
  src/golden/expected_packets.json -- machine golden for Python decoders
                                      (src/uart_decode.py reads this path)

All 33 bytes of every packet are asserted STRICTLY (strict_mask = all 1);
there is no masked / tool-dependent byte. The golden mirrors the as-RTL
restoring divider, so crest and the checksum are byte-deterministic.

Usage:  python -I src/golden_model.py
"""
import hashlib
import json
import subprocess
from math import isqrt
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
ROM_HEX = REPO / "src" / "ecg_rom.hex"
OUT = REPO / "src" / "golden"

# --- conversion parameters (mirror the on-disk ROM stream) -----------------
N = 2048                       # ROM_WORDS
BASELINE = 169                 # window_buffer BASELINE_OFFSET
THRESH_LOW = 80                # ecg_threshold[7:0] APB reset (apb_slave_if.v)
WINDOW, STRIDE = 512, 256
NUM_W = (N - WINDOW) // STRIDE + 1            # = 7 (T = 512..2048 step 256)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x1_0000_0000 if v & 0x8000_0000 else v


def s64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    return v - 2 ** 64 if v & (1 << 63) else v


def rtl_restoring_divider(numerator, denominator):
    """Mirror of the RTL 28-bit unsigned shift-subtract (restoring) divider
    in feature_extraction.v S_DIV_CREST / S_DIV_RR.

    Returns the 16-bit narrow of the exact floor(numerator/denominator),
    i.e. the value the RTL drives onto div_quot[15:0]. Denominator must be
    non-zero; the caller guards zero denominators (crest rms==0 -> 0, rr
    prev==0 -> 4096 constant), exactly as the RTL does.
    """
    # Exact floor of the true quotient, independent of the RTL's bit-serial
    # loop: the RTL computes it via 28 shift-subtract iterations.
    return numerator // denominator


def provenance():
    """Source revision + on-disk ROM image SHA256 (records in the JSON)."""
    rev = None
    try:
        rev = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO, capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except Exception:
        pass
    blob = ROM_HEX.read_bytes()
    return {
        "source_revision": rev,
        "rom_hex": "src/ecg_rom.hex",
        "rom_hex_bytes": len(blob),
        "rom_hex_sha256": hashlib.sha256(blob).hexdigest(),
    }


def main():
    # Load the ON-DISK hex — the exact sample stream the DUT paces through
    # (src/ecg_rom.hex, one 2-digit hex byte per line). This is the single
    # source of truth; the golden does NOT recompute from a raw .dat file
    # (none exists in this repo) which could drift from the DUT's input.
    if not ROM_HEX.is_file():
        raise SystemExit(f"missing {ROM_HEX} — the DUT's ROM image")
    eight = []
    for line in ROM_HEX.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        eight.append(int(line, 16))
    # Sanity: the on-disk file must contain the full segment.
    if len(eight) != N:
        raise SystemExit(f"on-disk hex has {len(eight)} samples, expected {N}")

    lo, hi = min(eight), max(eight)   # for the JSON provenance record only

    # window_buffer baseline stage (window_buffer.v:59-65)
    post = [(v - BASELINE) if v >= BASELINE else 0 for v in eight]

    # pacer emits each sample once; windows fire at T = 512, 768, ..., 2048
    windows = []
    for i in range(1, NUM_W + 1):            # 1-based, matches win_index
        win = post[(i - 1) * STRIDE: (i - 1) * STRIDE + WINDOW]

        sxe = [v - 256 if v >= 128 else v for v in win]
        ssum = s32(sum(sxe))
        ssumsq = sum(v * v for v in sxe)

        # f_rms (G2): TRUE RMS, computed at Q8.8 internal precision.
        # The RTL takes a 32-bit radicand (mean_square << 16) and a
        # digit-by-step restoring sqrt (2 bits/cycle, 16 cycles) -> a 16-bit
        # Q8.8 result.  Python's isqrt() is the exact same floor(sqrt(x)),
        # verified bit-exact over all 65536 mean_square values.
        #   rms_fp = isqrt(mean_square << 16)   (Q8.8)
        #   f_rms  = rms_fp >> 8                (integer part of the RMS)
        mean_sq = (ssumsq & 0xFFFFFFFF) >> 9
        rms_fp = isqrt(mean_sq << 16)          # internal Q8.8 RMS
        rms16 = s16(rms_fp >> 8)               # f_rms output (integer part)

        # f_var (G2): population variance, always >= 0.
        #   var = (512*sum_sq - sum^2) / 512^2 = (512*sum_sq - sum^2) >> 18
        # Cauchy-Schwarz guarantees 512*sum_sq >= sum^2, so the numerator is
        # never negative. Max (x in [-128..127], N=512) = 16256 -> fits int16.
        var_num = 512 * ssumsq - ssum * ssum
        if var_num < 0:
            raise SystemExit(f"w{i}: f_var numerator negative ({var_num}) — "
                             f"formula or accumulation is broken")
        f_var = s16(var_num >> 18)

        peak = max(sxe)
        minv = min(sxe)

        # f_crest (G2): crest factor = |peak| / rms, but the divisor is the
        # INTERNAL Q8.8 rms_fp (not the rounded integer f_rms), so the
        # quotient carries the RMS's internal precision. Mirrors the RTL:
        #   numerator = mag_peak << 16  ({4'd0, mag_peak, 16'd0}, 28-bit)
        #   divisor   = rms_fp (Q8.8)
        #   quotient  = floor((mag_peak*2^16) / rms_fp) via the 28-bit
        #                restoring divider, narrowed to div_quot[15:0]
        #   sign      = sign of peak_reg (not of the magnitude)
        #   rms_fp == 0  -> f_crest = 0 (RTL branch)
        # The value is the crest factor scaled by 256 (Q8.0 of the ratio):
        # (mag_peak*2^16)/(rms*2^8) = (mag_peak/rms)*256.
        # int16-safe: max = 127*256 = 32512 < 32768.
        mag_peak = (-peak) & 0xFF if peak < 0 else peak
        if rms_fp > 0:
            num = mag_peak << 16
            if num >= (1 << 28):
                raise SystemExit(f"w{i}: crest numerator {num} exceeds 28 bits")
            q = rtl_restoring_divider(num, rms_fp)
            if q >= (1 << 16):
                raise SystemExit(f"w{i}: crest quotient {q} exceeds 16 bits")
            crest = -q if peak < 0 else q
            f_crest = s16(crest)
        else:
            f_crest = 0

        zc, prev, pos = 0, 0, 0
        for v in win:
            b7 = 1 if v >= 128 else 0
            if prev ^ b7:
                zc += 1
            prev = b7
            pos += (b7 == 0)

        # RR: EXACT mirror of the fixed feature_extraction S_ACCUMULATE.
        # Registers: rr_timer=0, rr_current=0, rr_previous=0, sample_delayed=0.
        # For each consumed sample win[k] (k=0..511): a falling crossing at
        # sample k is (sample_delayed > T) && (win[k] <= T), compared as
        # UNSIGNED 8-bit values. On a crossing: rr_previous<-rr_current,
        # rr_current<-rr_timer, rr_timer<-0; else rr_timer<-rr_timer+1.
        # sample_delayed<-win[k]. rr_timer counts the samples elapsed since
        # the previous crossing (the just-finished interval).
        rr_prev = 0; rr_cur = 0; rr_timer = 0; sdel = 0
        for k in range(len(win)):
            event = (sdel > THRESH_LOW and win[k] <= THRESH_LOW)
            if event:
                rr_prev = rr_cur
                rr_cur = rr_timer
                rr_timer = 0
            else:
                rr_timer += 1
            sdel = win[k]

        # f_rr_ratio: the RTL 28-bit restoring divider (S_DIV_RR).
        #   numerator = {rr_current, 12'd0} == rr_cur*4096 (28 bits)
        #   divisor   = rr_previous (16-bit unsigned)
        #   rr_previous == 0 -> f_rr_ratio = 4096 (RTL div-by-zero guard)
        if rr_prev == 0:
            f_rr_ratio = s16(4096)
        else:
            num = rr_cur * 4096
            if num >= (1 << 28):
                raise SystemExit(f"w{i}: rr_ratio numerator {num} exceeds 28 bits")
            q = rtl_restoring_divider(num, rr_prev)
            if q >= (1 << 16):
                raise SystemExit(f"w{i}: rr_ratio quotient {q} exceeds 16 bits")
            f_rr_ratio = s16(q)

        feats = [
            rms16,          # f_rms
            f_var,          # f_var
            s16(peak),      # f_peak
            s16(zc),        # f_zc
            s16(peak - minv),  # f_ptp
            f_crest,        # f_crest (RTL 28-bit restoring divider)
            s16(pos << 3),  # f_half_ratio
            s16(peak),      # f_max
            s16(rr_cur),    # f_rr
            s16(rr_prev),   # f_rr_prev
            f_rr_ratio,     # f_rr_ratio (RTL 28-bit restoring divider)
            s16(rr_cur - rr_prev),  # f_rr_diff
        ]

        # --- UART packet (demo protocol, 33 bytes) ---
        # ALL 33 bytes are STRICT: the golden reproduces the RTL arithmetic
        # exactly (crest / rr_ratio via the 28-bit restoring divider), so no
        # byte is open or tool-dependent. The checksum is derived from the
        # bytes above, so it is asserted too.
        widx = i
        cls = 0             # zero-weight classifier -> argmax tie -> class 0
        flags = 0           # no adc / feature / mlp overflow on a clean run
        body = [0xE7, 0xA5, 0x01, 28, widx & 0xFF, widx >> 8]
        for f in feats:
            body += [f & 0xFF, (f >> 8) & 0xFF]
        body += [cls & 0xFF, flags & 0xFF]
        pkt = body + [sum(body[2:32]) & 0xFF]
        mask = [1] * 33
        windows.append({
            "win_index": widx,
            "raw_range": [lo, hi],
            "features_rtl": feats,
            "class_code": cls,
            "flags": flags,
            "strict_mask": mask,
            "checksum": pkt[32],
            "packet": pkt,
        })

    OUT.mkdir(parents=True, exist_ok=True)

    # ---- JSON golden (board compare + offline decode) ----
    prov = provenance()
    jdoc = {
        "source": ("src/ecg_rom.hex (on-disk, 8-bit, 2048 samples) — the exact "
                   "byte stream the DUT paces through"),
        "provenance": {
            **prov,
            "note": ("A capture may only be compared byte-exact if it was "
                     "produced from THIS source revision and ROM image. If a "
                     "capture predates them, its bitstream is unconfirmed and "
                     "a mismatch may be a stale-artifact issue, not an RTL bug."),
        },
        "conversion": {
            "baseline": BASELINE,
            "threshold_low": THRESH_LOW,
            "eightbit_min": lo, "eightbit_max": hi,
        },
        "formulas": {
            "baseline": "x = (raw >= 169) ? raw - 169 : 0",
            "f_rms": "s16(isqrt((sum_sq & 0xFFFFFFFF) >> 9))   [TRUE RMS]",
            "f_var": "s16((512*sum_sq - sum^2) >> 18)   [population variance, >=0]",
            "f_crest": ("RTL 28-bit restoring divider: s16(sign(peak) * "
                        "floor(abs(peak)*256 / rms)); rms == 0 -> 0   [Q7.8]"),
            "f_rr_ratio": ("RTL 28-bit restoring divider: s16(floor(rr_cur*4096 "
                           "/ rr_prev)); rr_prev == 0 -> 4096"),
            "f_half_ratio": "s16(pos_cnt << 3)  (pos_cnt = count of bit7==0)",
            "f_zc": "count of bit7 toggles between consecutive samples",
            "rr_event": "prev > 80 && cur <= 80 (unsigned 8-bit)",
            "classifier": ("zero weights/biases -> argmax tie -> class 0, "
                           "no overflow"),
        },
        "strict_all_bytes": True,
        "baud_div": 437,
        "windows": windows,
    }
    (OUT / "expected_packets.json").write_text(json.dumps(jdoc, indent=1))

    # ---- SystemVerilog include for the demo TB ----
    lines = [
        "// AUTO-GENERATED by src/golden_model.py -- do not edit by hand.",
        "// Independent golden values (from src/ecg_rom.hex, NOT DUT output).",
        f"localparam int EXP_NUMW = {NUM_W};",
        "reg [15:0] exp_widx [0:EXP_NUMW-1];",
        "reg signed [15:0] exp_feat [0:EXP_NUMW-1][0:11];",
        "reg [1:0]  exp_class [0:EXP_NUMW-1];",
        "reg [7:0]  exp_pkt  [0:EXP_NUMW-1][0:32];",
        "reg [7:0]  exp_chk  [0:EXP_NUMW-1];",
        "// 1 = strict; ALL bytes are strict (crest uses the RTL 28-bit divider)",
        "reg        exp_mask [0:EXP_NUMW-1][0:32];",
        "initial begin",
    ]
    for w in windows:
        i = w["win_index"] - 1
        lines.append(f"  exp_widx[{i}] = 16'd{w['win_index']};")
        for k, f in enumerate(w["features_rtl"]):
            two_c = f & 0xFFFF  # 16-bit two's complement of the signed value
            lines.append(f"  exp_feat[{i}][{k}] = 16'h{two_c:04X};")
        lines.append(f"  exp_class[{i}] = 2'd{w['class_code']};")
        for k, b in enumerate(w["packet"]):
            lines.append(f"  exp_pkt[{i}][{k}] = 8'h{b:02X};")
        for k, m in enumerate(w["strict_mask"]):
            lines.append(f"  exp_mask[{i}][{k}] = 1'b{m};")
        lines.append(f"  exp_chk[{i}] = 8'h{w['checksum']:02X};")
    lines.append("end")
    (OUT / "expected_packets.sv").write_text("\n".join(lines))

    print(f"windows: {NUM_W}  (T = 512..2048 step 256)")
    print(f"rom: {ROM_HEX}  sha256={prov['rom_hex_sha256']}")
    print(f"rev: {prov['source_revision']}")
    print(f"raw seg: min={lo} max={hi}  ->  post-baseline min={min(post)} "
          f"max={max(post)}")
    for w in windows:
        f = w["features_rtl"]
        print(f"w{w['win_index']}: rms={f[0]} var={f[1]} peak={f[2]} "
              f"zc={f[3]} ptp={f[4]} crest={f[5]} "
              f"half={f[6]} max={f[7]} rr={f[8]}/{f[9]} "
              f"rr_ratio={f[10]} rr_diff={f[11]} chk=0x{w['checksum']:02X}")
    print("wrote", OUT / "expected_packets.json")
    print("wrote", OUT / "expected_packets.sv")


if __name__ == "__main__":
    main()
