#!/usr/bin/env python
"""Generate canonical G2 expected feature vectors for the SV testbenches.
Mirrors golden_model.py exactly (independent Python reference). Emits the
12-feature port-order array per case so the .sv expected values are
guaranteed consistent with the golden. Run: python -I sim/gen_g2_expect.py
"""
import sys, math
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8")

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def feats(vals, TH=80):
    sxe = [v - 256 if v >= 128 else v for v in vals]
    s = sum(sxe); ss = sum(x * x for x in sxe)
    ms = (ss & 0xFFFFFFFF) >> 9
    rms_fp = math.isqrt(ms << 16)          # internal Q8.8 RMS
    f_rms = rms_fp >> 8                    # integer part
    f_var = s16(((512 * ss - s * s) >> 18) & 0xFFFF)
    peak = max(sxe); minv = min(sxe)
    mag = peak if peak >= 0 else -peak
    q = ((mag << 16) // rms_fp) if rms_fp else 0
    crest = s16(q) if peak >= 0 else s16((-q) & 0xFFFF)
    zc = sum(1 for k in range(1, len(vals)) if (vals[k] >= 128) != (vals[k - 1] >= 128))
    pos = sum(1 for v in vals if v < 128); half = s16(pos << 3)
    rp = rc = rt = sd = 0
    for v in vals:
        if sd > TH and v <= TH:
            rp, rc = rc, rt; rt = 0
        else:
            rt += 1
        sd = v
    ratio = 4096 if rp == 0 else s16((rc * 4096) // rp)
    return [s16(f_rms), f_var, s16(peak), s16(zc), s16(peak - minv), crest,
            half, s16(peak), s16(rc), s16(rp), ratio, s16(rc - rp), rms_fp]

def rep(n, v):
    return [v] * n

Z = [0] * 512
# RR case: three impulses at 10,30,60 (down-crossings -> rr fires)
_rr = [0] * 512
for i in (10, 30, 60):
    _rr[i] = 100
CASES = {
    "zero":    Z,
    "x10":     rep(512, 10),
    "x20":     rep(512, 20),
    "imp0":    [100] + [0] * 511,
    "imp511":  [0] * 511 + [100],
    "rr":      _rr,
    "neg128":  rep(256, 0x80) + rep(256, 0x7F),
    "nonint":  rep(300, 3) + rep(212, 0xFD),
    "neg3":    rep(512, 0xFD),
}

NAMES = ["f_rms", "f_var", "f_peak", "f_zc", "f_ptp", "f_crest", "f_half",
         "f_max", "f_rr", "f_rr_prev", "f_rr_ratio", "f_rr_diff"]

def sv_array(vals):
    """Return full feats() list (12 features + rms_fp)."""
    return feats(vals)

print("// G2 expected (independent Python reference; matches golden_model.py)")
print("// port order: rms,var,peak,zc,ptp,crest,half,max,rr,rrprev,ratio,rrdiff")
for name, vals in CASES.items():
    f = sv_array(vals)
    print(f"{name:9s} " + " ".join(str(x) for x in f) + f"   // rms_fp={f[12]}")
