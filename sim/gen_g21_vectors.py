"""Generate independent preprocessing/feature vectors; no simulator/DUT input."""
import importlib.util
import json
from pathlib import Path
import random
import sys

sys.dont_write_bytecode = True

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("g21_reference", ROOT/"src/g21_reference.py")
ref=importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)
OUT=ROOT/"sim/g21_vectors"


def main():
    # Independent mathematical invariants, including every ADC zero/raw pair.
    checks=0
    for raw in range(256):
        x=ref.preprocess(raw)
        assert -128 <= x <=127 and x+128==raw
        assert ref.preprocess(raw,"legacy")==max(0,raw-169)
        checks+=2
        for zero in range(256):
            x=ref.preprocess(raw,"adc-offset",zero)
            assert -128 <= x <= 127
            assert x == (raw-zero if -128 <= raw-zero <=127 else (-128 if raw<zero else 127))
            checks+=1
    assert [ref.preprocess(v) for v in [0,127,128,129,255]]==[-128,-1,0,1,127]
    assert ref.features([0]*512)==[0,0,0,0,0,0,4096,0,0,0,4096,0]
    assert ref.features([-3]*512)==[3,0,-3,0,0,-256,0,-3,0,0,4096,0]
    boundary=ref.features([-128]*256+[127]*256)
    assert boundary[:8]==[127,16256,127,1,255,255,2048,127]
    assert ref.features([-1]+[0]*511)[3]==1  # no spurious leading crossing
    # This documents the known precision issue; G2.1 does not fix RMS.
    assert ref.features([1]+[0]*511)[0]==0
    legacy=ref.make_golden("legacy")
    frozen=json.loads((ROOT/"src/golden/expected_packets.json").read_text())
    assert [w["packet"] for w in legacy["windows"]]==[w["packet"] for w in frozen["windows"]]

    rng=random.Random(0x21ec6)
    cases=[("zero",[128]*512), ("positive_10",[138]*512), ("negative_10",[118]*512),
           ("impulse_plus1_first",[129]+[128]*511),
           ("impulse_minus1_last",[128]*511+[127]),
           ("signed_boundary",[0]*256+[255]*256),
           ("zeros_in_crossing",([127,128,129,128,127,127,128,129]*64)),
           ("noninteger_rms",[130]*256+[125]*256),
           ("negative_extremum",[0]+[128]*511),
           ("constant_min",[0]*512), ("constant_max",[255]*512),
           ("positive_last",[128]*511+[255]),
           ("negative_first",[127]+[129]*511)]
    cases += [(f"random_{i}",[rng.randrange(256) for _ in range(512)]) for i in range(3)]
    records=[]
    for name, raw in cases:
        signed=[ref.preprocess(v) for v in raw]
        records.append(dict(name=name,raw=raw,signed=signed,features=ref.features(signed)))
    OUT.mkdir(exist_ok=True)
    (OUT/"cases.json").write_text(json.dumps(records,indent=1)+"\n")
    for field, width in [("raw",2),("signed",2),("features",4)]:
        mask=(1<<(4*width))-1
        (OUT/f"{field}.hex").write_text("\n".join(f"{v&mask:0{width}x}" for c in records for v in c[field])+"\n")
    modes=[("legacy",128),("rom-centered",128),("adc-offset",0),
           ("adc-offset",128),("adc-offset",169),("adc-offset",255)]
    (OUT/"conversion.hex").write_text("\n".join(f"{ref.preprocess(v,m,z)&255:02x}" for m,z in modes for v in range(256))+"\n")
    (OUT/"counts.svh").write_text(f"localparam integer NUM_CASES={len(records)};\n")
    rom=[int(x,16) for x in (ROOT/"src/ecg_rom.hex").read_text().split()]
    (OUT/"rom_signed.hex").write_text("\n".join(f"{ref.preprocess(v)&255:02x}" for v in rom)+"\n")
    print(f"G21 PYTHON PASS exhaustive_conversion_checks={checks} directed_cases={len(records)} legacy_bytes=231")


if __name__=="__main__":
    main()
