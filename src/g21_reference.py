"""Independent G2.1 reference: signed preprocessing, FROZEN feature equations.

No RTL state machine, square-root iteration or divider implementation is copied.
Python integers, math.isqrt, extrema and event timestamp lists define the result.
RR outputs are compatibility diagnostics, never valid physiological measurements.
See G2_DESIGN_CONTRACT.txt. Legacy golden files are never overwritten here.
"""
import argparse
import hashlib
import json
from math import isqrt
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WINDOW, STRIDE = 512, 256
ORDER = ["rms", "var", "peak", "zc", "ptp", "crest", "half_ratio", "max",
         "rr", "rr_prev", "rr_ratio", "rr_diff"]


def preprocess(raw, mode="rom-centered", adc_zero=128):
    if not 0 <= raw <= 255 or not 0 <= adc_zero <= 255:
        raise ValueError("raw and ADC zero must be unsigned 8-bit codes")
    if mode == "legacy":
        return max(raw - 169, 0)
    if mode == "rom-centered":
        return raw - 128
    if mode == "adc-offset":
        return min(127, max(-128, raw - adc_zero))
    raise ValueError("unknown preprocessing mode")


def signed16(value):
    return (value + 32768) % 65536 - 32768


def features(samples, threshold=80):
    """Current 512-sample equations, including explicitly documented G2 debt.

    This is not the future corrected RMS/absolute-crest/streaming-RR contract.
    Returning old RR diagnostics is necessary for strict packet comparison;
    do not interpret either the counters or fallback ratio as valid RR.
    """
    if len(samples) != WINDOW or any(x < -128 or x > 127 for x in samples):
        raise ValueError("exactly 512 signed int8 samples required")
    total = sum(samples)
    energy = sum(x*x for x in samples)
    rms_fp = isqrt((energy // WINDOW) * 65536)
    variance_numerator = WINDOW * energy - total * total
    if variance_numerator < 0:
        raise AssertionError("population variance cannot be negative")
    peak, minimum = max(samples), min(samples)
    crest = (abs(peak) * 65536 // rms_fp) if rms_fp else 0
    if peak < 0:
        crest = -crest
    crossings = sum((a < 0) != (b < 0) for a, b in zip(samples, samples[1:]))
    # Independent event timestamp derivation of the frozen legacy RR counter.
    unsigned = [x % 256 for x in samples]
    events = [i for i in range(1, WINDOW)
              if unsigned[i-1] > threshold and unsigned[i] <= threshold]
    intervals = ([events[0]] + [b-a-1 for a, b in zip(events, events[1:])]) if events else []
    rr = intervals[-1] if intervals else 0
    previous = intervals[-2] if len(intervals) >= 2 else 0
    ratio = rr * 4096 // previous if previous else 4096
    vector = [rms_fp // 256, variance_numerator // (WINDOW*WINDOW), peak,
              crossings, peak-minimum, crest, sum(x >= 0 for x in samples)*8,
              peak, rr, previous, ratio, rr-previous]
    return [signed16(v) for v in vector]


def packet(vector, index, class_code=0):
    body = [0xe7, 0xa5, 1, 28, index & 255, index >> 8]
    for value in vector:
        body.extend([value & 255, (value >> 8) & 255])
    body.extend([class_code, 0])
    return body + [sum(body[2:32]) % 256]


def make_golden(mode="rom-centered", adc_zero=128):
    rom = ROOT / "src/ecg_rom.hex"
    raw = [int(x, 16) for x in rom.read_text().split()]
    if len(raw) != 2048:
        raise ValueError("ROM must contain exactly 2048 samples")
    samples = [preprocess(v, mode, adc_zero) for v in raw]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    paths = ["src/ecg_rom.hex", "src/window_buffer.v", "src/feature_extraction.v",
             "src/top_ecg_rom_demo.v", "src/g21_reference.py"]
    windows = []
    for i, start in enumerate(range(0, len(raw)-WINDOW+1, STRIDE), 1):
        vector = features(samples[start:start+WINDOW])
        payload = packet(vector, i)
        windows.append(dict(win_index=i, sample_range=[start, start+WINDOW-1],
                            raw_range=[min(raw[start:start+WINDOW]), max(raw[start:start+WINDOW])],
                            features_rtl=vector, class_code=0, flags=0,
                            rr_physiologically_valid=False, strict_mask=[1]*33,
                            checksum=payload[-1], packet=payload))
    return {
        "source": "G2.1 signed ROM codes; frozen feature equations, no physical-unit calibration",
        "provenance": {"source_revision": revision, "rom_hex": "src/ecg_rom.hex",
                       "rom_hex_sha256": hashlib.sha256(rom.read_bytes()).hexdigest(),
                       "source_sha256": {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}},
        "conversion": {"mode": mode, "adc_zero_code": adc_zero if mode == "adc-offset" else None,
                       "equation": {"legacy": "max(raw-169,0)", "rom-centered": "raw-128",
                                    "adc-offset": "min(127,max(-128,raw-adc_zero_code))"}[mode],
                       "input": "unsigned 8-bit min-max codes", "output": "signed int8, F=0, code units",
                       "physical_units_known": False, "digital_midpoint": 128},
        "feature_order": ORDER, "feature_fractional_bits": [0,0,0,0,0,8,12,0,0,0,12,0],
        "formulas": {
            "f_rms": "R=isqrt(floor(sum(x*x)/512)*65536); f_rms=floor(R/256) (G2.2 precision fix pending)",
            "f_var": "floor((512*sum(x*x)-sum(x)^2)/262144)",
            "f_peak/f_max": "max(x)", "f_ptp": "max(x)-min(x)",
            "f_zc": "adjacent sign changes only; zero nonnegative; no artificial first crossing",
            "f_crest": "sign(max(x))*floor(abs(max(x))*65536/R), R=0 -> 0; F=8; absolute crest pending",
            "f_half_ratio": "count(x>=0)*8; F=12",
            "rr": "UNSIGNED byte threshold falling events; window-local count; interval gaps minus one",
            "f_rr_ratio": "signed16(floor(rr*4096/prev)), prev=0 -> 4096; invalid physiological measurement",
            "f_rr_diff": "rr-prev",
        },
        "rr_physiologically_valid": False,
        "model_compatibility": "G1-trained normalization/weights incompatible; placeholder zero weights only",
        "strict_all_bytes": True, "baud_div": 437, "windows": windows,
    }


def sv_include(golden):
    windows = golden["windows"]
    lines = ["// Generated by independent src/g21_reference.py. Do not edit expected values.",
             "// G2.1 preprocessing only; RR remains an INVALID physiological diagnostic.",
             f"localparam int EXP_NUMW = {len(windows)};",
             "reg signed [15:0] exp_feat [0:EXP_NUMW-1][0:11];",
             "reg [7:0] exp_pkt [0:EXP_NUMW-1][0:32];", "initial begin"]
    for i, win in enumerate(windows):
        for k, value in enumerate(win["features_rtl"]):
            lines.append(f"  exp_feat[{i}][{k}] = 16'h{value & 65535:04X};")
        for k, value in enumerate(win["packet"]):
            lines.append(f"  exp_pkt[{i}][{k}] = 8'h{value:02X};")
    return "\n".join(lines + ["end", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["legacy", "rom-centered", "adc-offset"], default="rom-centered")
    parser.add_argument("--adc-zero", type=int, default=128)
    parser.add_argument("--output", type=Path, default=ROOT/"src/golden/g21_signed")
    parser.add_argument("--check", action="store_true", help="Compare existing vectors, never write")
    args = parser.parse_args()
    golden = make_golden(args.mode, args.adc_zero)
    path = args.output / "expected_packets.json"
    if args.check:
        previous = json.loads(path.read_text())
        for old, new in zip(previous["windows"], golden["windows"], strict=True):
            for key in ["features_rtl", "packet", "strict_mask", "checksum"]:
                if old[key] != new[key]:
                    raise AssertionError(f"reference mismatch window={new['win_index']} field={key}")
        print(f"PASS independent {args.mode} reference: 7 windows, all 231 bytes")
        return
    if args.output.resolve() == (ROOT/"src/golden").resolve():
        raise ValueError("G1 golden directory is frozen; use a separate output directory")
    args.output.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(golden, indent=2)+"\n", encoding="utf-8")
    (args.output/"expected_packets.sv").write_text(sv_include(golden), encoding="ascii")
    print(f"Generated {args.mode}: {path}")
    for w in golden["windows"]:
        print(f"window {w['win_index']}: {w['features_rtl']} RR_VALID=false")


if __name__ == "__main__":
    main()
