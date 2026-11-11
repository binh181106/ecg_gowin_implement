"""Independent integer equations for G2.2; no RTL sqrt/divider simulation.

G2.1 supplies unchanged preprocessing, nine unchanged feature equations and
packet serialization. Corrected arithmetic is derived here with Python ints.
Old golden files are read only. Generate explicitly; --check never writes.
"""
import argparse
import hashlib
import importlib.util
import json
from math import isqrt
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("g21_frozen", ROOT/"src/g21_reference.py")
frozen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frozen)


def arithmetic(samples):
    if len(samples) != 512 or any(not -128 <= x <= 127 for x in samples):
        raise ValueError("G2.2 requires exactly 512 signed int8 samples")
    total = sum(samples)
    energy = sum(x*x for x in samples)
    numerator = 512*energy - total*total
    assert 0 <= energy <= 8388608 and 0 <= numerator <= 4261478400
    absolute_peak = max(abs(x) for x in samples)
    rms_fp = isqrt(energy*128)
    variance = numerator // 262144
    crest = absolute_peak*65536 // rms_fp if rms_fp else 0
    assert 0 <= rms_fp <= 32768 and 0 <= variance <= 16256 and 0 <= crest <= 5957
    return dict(total=total, energy=energy, var_num=numerator, abs_peak=absolute_peak,
                rms_fp=rms_fp, rms=rms_fp//256, variance=min(32767,variance),
                crest=min(32767,crest))


def features(samples):
    a = arithmetic(samples)
    # RR/ZC/peak/order semantics remain precisely the frozen G2.1 contract.
    vector = frozen.features(samples)
    vector[0], vector[1], vector[5] = a["rms"], a["variance"], a["crest"]
    return vector


def make_golden(mode):
    golden = frozen.make_golden(mode)
    raw = [int(v,16) for v in (ROOT/"src/ecg_rom.hex").read_text().split()]
    samples = [frozen.preprocess(v,mode) for v in raw]
    for i,win in enumerate(golden["windows"]):
        window = samples[i*256:i*256+512]
        win["features_rtl"] = features(window)
        win["arithmetic"] = arithmetic(window)
        win["packet"] = frozen.packet(win["features_rtl"],i+1)
        win["checksum"] = win["packet"][-1]
    golden["source"] = "G2.2 corrected Q8.8 RMS / population variance / absolute crest; code units"
    golden["arithmetic_contract"] = "G2.2"
    golden["formulas"].update({
        "f_rms": "R=isqrt(sum(x*x)*128); f_rms=R//256; F=0",
        "f_var": "floor((512*sum(x*x)-sum(x)^2)/262144); F=0; saturate 0..32767, fault on negative",
        "f_crest": "min(32767,max(abs(x))*65536//R), R=0 -> 0; nonnegative F=8",
    })
    golden["model_compatibility"] = "G1/G2.1 trained feature numerics incompatible; placeholder weights unchanged"
    golden["provenance"]["source_sha256"]["src/g22_reference.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return golden


def sv_include(golden):
    return frozen.sv_include(golden).replace("src/g21_reference.py", "src/g22_reference.py").replace(
        "G2.1 preprocessing only", "G2.2 corrected arithmetic")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name,mode in [("g22_signed","rom-centered"),("g22_legacy","legacy")]:
        golden = make_golden(mode)
        out = ROOT/"src/golden"/name
        if args.check:
            saved = json.loads((out/"expected_packets.json").read_text())
            assert saved["windows"] == golden["windows"], name
            assert saved["formulas"] == golden["formulas"], name
            assert (out/"expected_packets.sv").read_text() == sv_include(golden), name
        else:
            out.mkdir(parents=True,exist_ok=True)
            (out/"expected_packets.json").write_text(json.dumps(golden,indent=2)+"\n")
            (out/"expected_packets.sv").write_text(sv_include(golden))
        print(("PASS checked " if args.check else "Generated ")+name+": all 231 bytes strict")


if __name__ == "__main__":
    main()
