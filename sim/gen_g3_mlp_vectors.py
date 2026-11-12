"""Generate deterministic MLP test vectors for the ai_classifier datapath.

One coherent model is used so a single force-file exercises the whole path:
normalization (nonzero mean + non-unit inverse scale), the >>>12 MAC,
saturation, ReLU, argmax and all four output classes.

The weights/normalizers are SYNTHETIC and deterministic; they are NOT a
trained model. They prove the fixed-point datapath matches the independent
Python reference src/g3_mlp_reference.py.

Outputs under sim/g3_vectors/:
  mlp_force.txt    "flat_index hex_value" pairs to force into the DUT
  mlp_expect.hex   per case: 12 features, 8x32 hidden, 4x32 logit, class
                   (26 x 32-bit words per case, $readmemh-sequential)
"""
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("g3mlp", ROOT / "src/g3_mlp_reference.py")
g3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g3)


def model():
    """Sparse identity network plus one deliberately dense high-weight
    neuron that forces MAC saturation and a non-zero bias for the wrap case.

    Contract: norm[i] = (raw[i] - mean[i]) * inv_scale[i] (plain multiply).
    With mean = 0 and inv_scale = 4096 (=1.0 in Q12), norm[i] = raw[i]*4096,
    so a diagonal weight of 4096 makes neuron j compute exactly raw[j]
    after the >>>12 shift. Neurons 0..3 therefore give all four reachable
    classes by making one feature large.

    Neuron 7 is dense with weight 32767 on every input: with large features
    its accumulator exceeds INT32_MAX, so the saturating MAC and the sticky
    overflow flag are exercised. It also carries a NON-ZERO bias (4096):
    once the MAC has saturated the accumulator to 0x7FFFFFFF, adding a
    positive bias must stay clamped. A plain 32-bit add would wrap to a
    negative value and silently corrupt the neuron; this is the defect the
    bias wrap tests are written to catch. fc2 does NOT tap neuron 7, so it
    cannot hijack the argmax.
    """
    m = dict(fc1_w=[[0] * 12 for _ in range(8)], fc1_b=[0] * 8,
             fc2_w=[[0] * 8 for _ in range(4)], fc2_b=[0] * 4,
             # Nonzero per-feature mean exercises the (raw - mean) offset path
             # in normalization; the diagonal 4096 weights keep every neuron
             # monotonic in its own feature, so the four classes remain
             # reachable by making one feature large.
             mean=[i * 100 for i in range(12)],
             inv_scale=[4096] * 12)
    for j in range(8):
        m["fc1_w"][j][j] = 4096
    for k in range(4):
        m["fc2_w"][k][k] = 4096
    for i in range(12):
        m["fc1_w"][7][i] = 32767
    # Neuron 7's bias stays 0 so the pure MAC-saturation case is unambiguous:
    # the MAC clamps the accumulator, and ReLU keeps the clamped value
    # (0x7FFFFFFF -> 2147483647 positive, or -0x80000000 -> 0).
    m["fc1_b"][7] = 0
    # Neuron 6 is dense too but carries a POSITIVE bias, so its accumulator
    # saturates and is then unwound by the plain-32-bit bias add: the wrap
    # turns the clamped 0x7FFFFFFF negative, and ReLU then clamps it to 0.
    # This case PINS that known latent defect (reports/G3_FINAL_REPORT.md):
    # the reference predicts the current RTL behaviour exactly, so if the RTL
    # is later fixed to saturate the bias add, this test FAILS loudly and
    # forces the golden to be updated in the same change. Neither neuron is
    # tapped by fc2, so neither can hijack the argmax.
    for i in range(12):
        m["fc1_w"][6][i] = 32767
    m["fc1_b"][6] = 4096
    # Exercise the normal (non-saturating) bias-add path on a diagonal neuron
    # so the bias stage is covered without reaching the wrap edge.
    m["fc1_b"][0] = 4096
    return m


def cases():
    """Directed vectors: four classes, tie, negatives, signed16 extremes,
    and MAC saturation (the accumulator must clamp and raise overflow)."""
    return [
        [8000, 100, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0],        # -> class 0
        [100, 8000, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0],        # -> class 1
        [10, 100, 8000, 0, 0, 0, 0, 0, 0, 0, 0, 0],        # -> class 2
        [10, 100, 10, 8000, 0, 0, 0, 0, 0, 0, 0, 0],       # -> class 3
        [0] * 12,                                            # tie -> class 0
        [-4000, -3000, -2000, -1000, 0, 0, 0, 0, 0, 0, 0, 0],  # ReLU -> all 0
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],           # small positives
        [32767] * 12,                                        # signed16 max, tie
        [-32768] * 12,                                        # signed16 min
        [32767] * 12,                                        # max, saturation
        [-32768] * 12,                                       # min, saturation
    ]


def main():
    m = model()
    out = ROOT / "sim/g3_vectors"
    out.mkdir(parents=True, exist_ok=True)

    # Force list: every one of the 164 values, so the DUT's own initial
    # block (mean=0, inv_scale=4096, weights=0) is fully overridden and the
    # simulated state is defined entirely by this file.
    #
    # Flat order follows the RTL addressing exactly. The MAC address is
    # fc1_weights[cnt-1] with neuron=(cnt-1)/12 and input=(cnt-1)%12, so the
    # flat index is NEURON-major: neuron*12 + input. For FC2 the address is
    # fc2_weights[cnt-1] with neuron=(cnt-1)/8 and input=(cnt-1)%8, so the
    # flat index is OUTPUT-major: output*8 + hidden. This was settled with
    # sim/tb_g3_probe.sv (a non-diagonal single-weight probe).
    #   then fc1_biases[0..7], fc2_biases[0..3], mean[0..11], inv_scale[0..11]
    #   (total 164, matching src/weight.mi depth)
    force = []
    for j in range(8):
        for i in range(12):
            force.append((j * 12 + i, m["fc1_w"][j][i]))
    for j in range(8):
        force.append((96 + j, m["fc1_b"][j]))
    for k in range(4):
        for j in range(8):
            force.append((104 + k * 8 + j, m["fc2_w"][k][j]))
    for k in range(4):
        force.append((136 + k, m["fc2_b"][k]))
    for i in range(12):
        force.append((140 + i, m["mean"][i]))
    for i in range(12):
        force.append((152 + i, m["inv_scale"][i]))
    assert len(force) == 164
    (out / "mlp_force.txt").write_text(
        "".join(f"{idx} {val & 0xFFFF:04X}\n" for idx, val in force))

    # Also emit an include file of explicit force statements. ModelSim SE
    # 10.7c has no $fgetsls, so the bench cannot parse the text file at
    # runtime; static forces are simpler and deterministic.
    lines = ["// Generated by sim/gen_g3_mlp_vectors.py. Do not edit.",
             "// Synthetic deterministic weights; NOT a trained model.",
             "task g3_forces;"]
    for idx, val in force:
        v = val & 0xFFFF
        if idx < 96:
            lines.append(f"  force dut.fc1_weights[{idx}] = 16'h{v:04X};")
        elif idx < 104:
            lines.append(f"  force dut.fc1_biases[{idx - 96}] = 16'h{v:04X};")
        elif idx < 136:
            lines.append(f"  force dut.fc2_weights[{idx - 104}] = 16'h{v:04X};")
        elif idx < 140:
            lines.append(f"  force dut.fc2_biases[{idx - 136}] = 16'h{v:04X};")
        elif idx < 152:
            lines.append(f"  force dut.mean_vals[{idx - 140}] = 16'h{v:04X};")
        else:
            lines.append(f"  force dut.inv_scale[{idx - 152}] = 16'h{v:04X};")
    lines.append("endtask")
    (out / "mlp_force.svh").write_text("\n".join(lines) + "\n")

    rows = []
    meta = []
    for vec in cases():
        r = g3.classify(vec, m)
        row = [v & 0xFFFF for v in vec]
        row += [v & 0xFFFFFFFF for v in r["hidden"]]
        row += [v & 0xFFFFFFFF for v in r["logits"]]
        row += [r["class_code"], 1 if r["overflow"] else 0]
        assert len(row) == 26, len(row)
        # One 32-bit word per line: $readmemh assigns one address per line,
        # so packing several words per line silently truncates to the low
        # 32 bits and yields all-zero expectations (a vacuous test).
        rows.extend(f"{v:08X}" for v in row)
        meta.append((r["class_code"], r["overflow"]))
    (out / "mlp_expect.hex").write_text("\n".join(rows) + "\n")
    (out / "mlp_cases.txt").write_text(
        "".join(f"{i} class={c} overflow={o}\n"
                for i, (c, o) in enumerate(meta)))
    # Case count for the bench's expected-value loop.
    (out / "mlp_meta.svh").write_text(
        f"// Generated case count.\nlocalparam int G3_NUM_CASES = {len(meta)};\n")

    print(f"{len(meta)} cases, {len(force)} forced entries")
    for i, (c, o) in enumerate(meta):
        print(f"  case {i} class={c} overflow={o}")


if __name__ == "__main__":
    main()
