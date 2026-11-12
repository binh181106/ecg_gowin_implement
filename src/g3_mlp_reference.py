"""G3 independent golden MLP: normalization, FC1, ReLU, FC2, argmax.

Independent of the RTL: every quantity is computed with Python integers
from the frozen fixed-point contract, never read back from a simulator.
The contract is stated in reports/G3_2_FEATURE_MLP_CONTRACT.md.

CONTRACT (bit-exact target for src/ai_classifier.v)
  * feature vector: 12 x signed16, index 0 = RMS (LSB of features_flat)
  * normalization:  norm[i] = (raw[i] - mean[i]) * inv_scale[i]
                    -> evaluated at 32 bits (assignment context sign extends
                       the 16-bit operands), NO overflow flag
  * FC1 MAC:       acc[j] = sat32(acc[j] + ((norm[i] * W1[j][i]) >>> 12))
                    -> saturating, SETS the overflow flag
  * FC1 bias:      acc[j] = s32(acc[j] + b1[j])
                    -> plain 32-bit WRAP, NO overflow flag
  * ReLU:          h[j] = max(acc[j], 0)      (exactly 0 stays 0)
  * FC2 MAC:       logit[k] = sat32(logit[k] + ((h[j] * W2[k][j]) >>> 12))
  * FC2 bias:      logit[k] = s32(logit[k] + b2[k])   -> plain 32-bit WRAP
  * argmax:        lowest index wins ties
  * overflow:      sticky flag, set ONLY by MAC saturation

NOTE the asymmetry: only the MAC accumulation saturates and flags. The
normalization and the bias additions are plain 32-bit wrap operations
that can silently overflow. This mirrors the RTL exactly and is reported
as a contract weakness, not silently "fixed" here - see the KNOWN LATENT
DEFECT note in fc1_mac().

The weight/bias/normalizer arrays are signed16; the accumulators are
signed32.

Weight layout follows the RTL memory addressing. The MAC address is
fc1_weights[cnt-1] with neuron=(cnt-1)/12 and input=(cnt-1)%12, so
  fc1_weights[neuron*12 + input] is the weight from input to hidden neuron
Analogously fc2_weights[cnt-1] has neuron=(cnt-1)/8, input=(cnt-1)%8, so
  fc2_weights[output*8 + hidden] is the weight from hidden to output
This was settled with sim/tb_g3_probe.sv (a non-diagonal single-weight
probe: flat 13 -> neuron 1 / input 1, flat 12 -> neuron 1 / input 0,
flat 5 -> neuron 0 / input 5). The model dicts below use the clearer
fc1_w[neuron][input] / fc2_w[output][hidden] ordering; the flattening to
the DUT arrays is done by the vector generator.
"""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]

N_FEATURES = 12
N_HIDDEN = 8
N_OUTPUT = 4
WEIGHT_SHIFT = 12          # MAC product shift, both layers
INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


def s16(value):
    """Narrow to signed16 the way a 16-bit signed register holds it."""
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def s32(value):
    """Narrow to signed32 by truncation (no saturation, no flag)."""
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def sat32(value):
    """Saturate to the signed32 range. Returns (value, overflowed)."""
    if value > INT32_MAX:
        return INT32_MAX, True
    if value < INT32_MIN:
        return INT32_MIN, True
    return value, False


def arshift(value, bits):
    """Arithmetic right shift, floor toward -inf (Verilog >>> on signed)."""
    return value >> bits


def normalize(raw, mean, inv_scale):
    """norm[i] = s32(s16(raw[i]) - s16(mean[i])) * s16(inv_scale[i]).

    Mirrors the RTL S_NORM assignment exactly: the subtraction and the
    multiply are both evaluated at 32 bits. The "normalisation" here is a
    plain MULTIPLY by inv_scale (there is no Q-division in this datapath);
    the 2^12 that restores scale is folded into the MAC shift instead.
    """
    out = []
    for i in range(N_FEATURES):
        diff = s16(raw[i]) - s16(mean[i])
        out.append(s32(diff * s16(inv_scale[i])))
    return out, False


def fc1_mac(norm, w1, b1):
    """acc[j] = sum_i ((norm[i] * W1[j][i]) >>> 12), then WRAPPING acc[j] + b1[j].

    The MAC accumulation saturates and sets the overflow flag, but the bias
    add is a plain 32-bit wrap that does NOT set the flag - exactly as in
    the RTL. This asymmetry is deliberate in the reference: the reference
    must predict the RTL bit-exactly, so that fixing the RTL later shows up
    as a test failure rather than being silently absorbed.

    KNOWN LATENT DEFECT (identified, deliberately NOT fixed here - see
    reports/G3_FINAL_REPORT.md): because the accumulator saturates at the
    32-bit boundary but the bias add wraps, a saturated-POSITIVE accumulator
    plus a positive bias wraps to a large negative value, which ReLU then
    clamps to 0. The MAC's overflow protection is thereby undone for the
    affected neuron.
    """
    acc = [0] * N_HIDDEN
    overflow = False
    for j in range(N_HIDDEN):
        total = 0
        for i in range(N_FEATURES):
            product = norm[i] * w1[j][i]
            total, ov = sat32(total + arshift(product, WEIGHT_SHIFT))
            overflow |= ov
        acc[j] = s32(total + b1[j])
    return acc, overflow


def relu(values):
    """ReLU on the accumulator: strictly greater than zero survives."""
    return [v if v > 0 else 0 for v in values]


def fc2_mac(hidden, w2, b2):
    """logit[k] = sum_j ((hidden[j] * W2[k][j]) >>> 12), then WRAPPING + b2[k]."""
    logits = [0] * N_OUTPUT
    overflow = False
    for k in range(N_OUTPUT):
        total = 0
        for j in range(N_HIDDEN):
            product = hidden[j] * w2[k][j]
            total, ov = sat32(total + arshift(product, WEIGHT_SHIFT))
            overflow |= ov
        logits[k] = s32(total + b2[k])
    return logits, overflow


def argmax(values):
    """Lowest index wins ties (the RTL uses >= comparisons in index order)."""
    best = 0
    for k in range(1, len(values)):
        if values[k] > values[best]:
            best = k
    return best


def classify(raw, model):
    """Full inference. Returns every intermediate value for cross-checking."""
    norm, ov_n = normalize(raw, model["mean"], model["inv_scale"])
    acc, ov1 = fc1_mac(norm, model["fc1_w"], model["fc1_b"])
    hidden = relu(acc)
    logits, ov2 = fc2_mac(hidden, model["fc2_w"], model["fc2_b"])
    return {
        "norm": norm,
        "fc1_acc": acc,
        "hidden": hidden,
        "logits": logits,
        "class_code": argmax(logits),
        "overflow": ov_n or ov1 or ov2,
    }


# ---------------------------------------------------------------- weights ---

def deterministic_weights(seed=1):
    """Reproducible, clearly-synthetic test weights.

    These are NOT a trained model. They exist only to prove the fixed-point
    datapath computes what the contract says it computes.
    """
    def lcg(state):
        return (1103515245 * state + 12345) & 0x7FFFFFFF

    def seq(count, state, lo, hi):
        out = []
        for _ in range(count):
            state = lcg(state)
            out.append(lo + state % (hi - lo + 1))
        return out

    state = seed
    fc1_w = []
    for _ in range(N_HIDDEN):
        fc1_w.append(seq(N_FEATURES, state, -4096, 4096))
        state = lcg(state)
    fc1_b = seq(N_HIDDEN, state, -512, 512)
    state = lcg(state)
    fc2_w = []
    for _ in range(N_OUTPUT):
        fc2_w.append(seq(N_HIDDEN, state, -4096, 4096))
        state = lcg(state)
    fc2_b = seq(N_OUTPUT, state, -512, 512)
    state = lcg(state)
    mean = seq(N_FEATURES, state, -512, 512)
    state = lcg(state)
    inv_scale = seq(N_FEATURES, state, 1, 4096)
    return dict(fc1_w=fc1_w, fc1_b=fc1_b, fc2_w=fc2_w, fc2_b=fc2_b,
                mean=mean, inv_scale=inv_scale)


def load_weight_mi(path):
    """Parse src/weight.mi (hex, 16-bit signed) into the model layout.

    The file carries no manifest, so the 164-value layout below is an
    ASSUMPTION based on the 12->8->4 architecture: 96 FC1 weights, 8 FC1
    biases, 32 FC2 weights, 4 FC2 biases, 12 means, 12 inverse scales.
    The counts match the architecture; the ORDER, the Q-format of each
    field and the normalization convention are NOT proven by the file.
    """
    raw = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        raw.append(int(line, 16))
    if len(raw) != 164:
        raise ValueError(f"weight.mi must hold 164 values, found {len(raw)}")
    vals = [s16(v) for v in raw]
    flat_w1 = vals[0:96]
    fc1_w = [flat_w1[j * N_FEATURES:(j + 1) * N_FEATURES] for j in range(N_HIDDEN)]
    flat_w2 = vals[104:136]
    fc2_w = [flat_w2[k * N_HIDDEN:(k + 1) * N_HIDDEN] for k in range(N_OUTPUT)]
    return dict(fc1_w=fc1_w, fc1_b=vals[96:104], fc2_w=fc2_w, fc2_b=vals[136:140],
                mean=vals[140:152], inv_scale=vals[152:164])


def flatten_weights(model):
    """Model layout -> flat 164-value order matching src/weight.mi."""
    out = []
    for neuron in model["fc1_w"]:
        out.extend(neuron)
    out.extend(model["fc1_b"])
    for row in model["fc2_w"]:
        out.extend(row)
    out.extend(model["fc2_b"])
    out.extend(model["mean"])
    out.extend(model["inv_scale"])
    return out


# ------------------------------------------------------------------ cases ---

def feature_vectors():
    """Directed, boundary and extreme 12-feature vectors."""
    return {
        "zero": [0] * N_FEATURES,
        "max": [32767] * N_FEATURES,
        "min": [-32768] * N_FEATURES,
        "mixed_boundary": [0, 1, -1, 32767, -32768, 2, -2, 3, 1000, -1000, 4096, -4096],
        "rr_invalid_zero": [10, 20, 30, 40, 50, 60, 70, 80, 0, 0, 0, 0],
        "rr_valid_pair": [10, 20, 30, 40, 50, 60, 70, 80, 300, 250, 4915, 50],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=["deterministic", "weight_mi"],
                        default="deterministic")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    if args.model == "weight_mi":
        model = load_weight_mi(ROOT / "src/weight.mi")
    else:
        model = deterministic_weights(args.seed)

    results = {}
    for name, vector in feature_vectors().items():
        results[name] = classify(vector, model)

    for name, r in results.items():
        print(f"{name:20s} class={r['class_code']} overflow={r['overflow']} "
              f"logits={r['logits']}")

    if args.json:
        args.json.write_text(json.dumps(
            {"model": args.model, "seed": args.seed, "results": results},
            indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
