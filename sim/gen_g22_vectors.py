"""Deterministic G2.2 test vectors from independent mathematics, never DUT output."""
import importlib.util
import json
from math import isqrt
from pathlib import Path
import random
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/"sim/g22_vectors"
spec = importlib.util.spec_from_file_location("g22_ref",ROOT/"src/g22_reference.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def cases():
    result = [("zero",[0]*512),("plus10",[10]*512),("minus10",[-10]*512)]
    for amp in [1,2,100,-1,-2,-100,-128,127]:
        for position in [0,255,511]:
            window=[0]*512; window[position]=amp
            result.append((f"impulse_{amp}_at_{position}",window))
    result += [("alternating_extremes",[-128,127]*256),
               ("all_negative_mixed",[-1,-3,-10,-128]*128),
               ("negative_dominant",[-120]+[10]*511),
               ("negative_dominant_last",[10]*511+[-120]),
               ("noninteger_rms",[2]*256+[-3]*256),
               ("zero_crossings",[-1,0,1,0,-1,-1,0,1]*64)]
    result += [(f"constant_{v}",[v]*512) for v in range(-128,128)]
    rng=random.Random(0x22ec6)
    result += [(f"random_{i}",[rng.randrange(-128,128) for _ in range(512)]) for i in range(24)]
    return result


def checkpoint_cases():
    impulse=lambda index: [100 if i==index else 0 for i in range(512)]
    return [[0]*512,[10]*512,[20]*512,impulse(0),impulse(511),
            [100 if i in [10,30,60] else 0 for i in range(512)],
            [-128]*256+[127]*256,[3]*300+[-3]*212,[-3]*512,[10]*512]


def write_hex(name,values,width):
    (OUT/name).write_text("\n".join(f"{v & ((1<<(4*width))-1):0{width}x}" for v in values)+"\n")


def main():
    OUT.mkdir(exist_ok=True)
    # Every legal peak amplitude: proof of nonnegative signed16 crest bound.
    assert max(a*65536//isqrt(a*a*128) for a in range(1,129)) == 5957
    assert isqrt(8388608*128)==32768
    assert ref.arithmetic([1]+[0]*511)["rms_fp"]==11
    assert ref.arithmetic([2]+[0]*511)["rms_fp"]==22
    assert ref.arithmetic([100]+[0]*511)["rms_fp"]==1131
    assert ref.features([-10]*512)[5]==256
    assert ref.features([-128,127]*256)[1]==16256
    records=[]
    for name,samples in cases():
        a=ref.arithmetic(samples); f=ref.features(samples)
        # Independent variance identity: sum_{i<j}(xi-xj)^2 = N*S2-S1^2.
        # A histogram evaluates it without an RTL-shaped accumulator.
        hist={v:samples.count(v) for v in set(samples)}
        vals=sorted(hist)
        pairs=sum(hist[x]*hist[y]*(x-y)**2 for i,x in enumerate(vals) for y in vals[i+1:])
        assert pairs==a["var_num"]
        old=ref.frozen.features(samples)
        assert all(f[i]==old[i] for i in range(12) if i not in [0,1,5])
        latency=1557+(30 if a["rms_fp"] else 1)+(30 if f[9] else 1)
        records.append(dict(name=name,samples=samples,features=f,latency=latency,**a))
    (OUT/"cases.json").write_text(json.dumps(records,indent=1)+"\n")
    write_hex("samples.hex",[x for c in records for x in c["samples"]],2)
    write_hex("features.hex",[x for c in records for x in c["features"]],4)
    write_hex("internals.hex",[c[k] for c in records for k in ["total","energy","var_num","abs_peak","rms_fp","latency"]],16)
    (OUT/"counts.svh").write_text(f"localparam integer NUM_CASES={len(records)};\n")
    prior=json.loads((ROOT/"sim/g21_vectors/cases.json").read_text())
    write_hex("g21_features.hex",[v for c in prior for v in ref.features(c["signed"])],4)
    print(f"G22 PYTHON PASS cases={len(records)} all_constants=256 peak_bounds=128 variance_identity=PASS unchanged_9_features=PASS")


if __name__ == "__main__":
    main()
