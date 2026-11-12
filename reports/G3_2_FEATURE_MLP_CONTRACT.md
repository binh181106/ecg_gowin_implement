# G3.2 — Feature Extraction ↔ MLP Input Contract

Date: 2026-11-12
Scope: the full data path `Feature Extraction -> features_flat -> Normalization ->
FC1 -> ReLU -> FC2 -> Argmax -> class_code`, plus the reset / handshake /
RR-invalid / zero-convention questions.

**Headline result:** the Feature Extraction output **is mathematically and
arithmetically compatible** with the MLP input contract — the flatten order,
signedness, sign extension and widths are all consistent. The only defect
found in the integration is that **`weight.mi` is never loaded**, so the
classifier runs with all-zero weights (see `G3_4_WEIGHT_PROVENANCE.md`).
The fixed-point datapath itself is verified correct (184 checks, all 4
classes, MAC saturation, ReLU, argmax ties).

---

## 1. Feature order when flatten / unpack — CONSISTENT

`src/top_ecg_rom_demo.v:149-153`:

```verilog
wire [191:0] features_flat = {
  f_rr_diff, f_rr_ratio, f_rr_prev, f_rr,
  f_max,     f_half_ratio, f_crest, f_ptp,
  f_zc,      f_peak,      f_var,   f_rms
};
```

The concatenation puts `f_rms` at the LSB. `ai_classifier` unpacks with
`features[g] = features_flat[g*16 +: 16]`, so index `g` maps to:

| g | feature | fractional bits |
|---|---|---|
| 0 | rms | 0 |
| 1 | var | 0 |
| 2 | peak | 0 |
| 3 | zc | 0 |
| 4 | ptp | 0 |
| 5 | crest | 8 |
| 6 | half_ratio | 12 |
| 7 | max | 0 |
| 8 | rr | 0 |
| 9 | rr_prev | 0 |
| 10 | rr_ratio | 12 |
| 11 | rr_diff | 0 |

This matches the frozen `feature_order` and `feature_fractional_bits` in
`src/golden/g21_reference.py:107`. **No reordering bug.** (I verified the
names line up exactly; the `f_` prefix is the only textual difference.)

## 2. Signedness and sign extension — CONSISTENT

- `features[g]` is declared `reg signed [15:0]` and each `feature` output in
  `feature_extraction.v` is a signed16. No sign-extension bug.
- In `ai_classifier`, every arithmetic use is wrapped in `$signed(...)`
  (normalisation, MAC products, bias adds), and `mac_temp` / the accumulators
  are `reg signed [47:0]` / `[31:0]`. Sign extension is explicit and correct.
- The `features_norm` register is `reg signed [31:0]` — the normalisation
  product is widened to 32 bits before the MAC.

## 3. Units and fractional bits of each feature

The MLP has **no per-feature scale other than `mean` / `inv_scale`**, which
are free 16-bit registers. The fractional bits in the table above are
carried in the feature *value* (crest is Q0.8 internally, stored here as the
final signed16; half_ratio and rr_ratio are Q4.12-ish counts / ratios).
The classifier treats every feature as an integer signed16 and applies one
`(x - mean) * inv_scale` normalisation. **This is fine as a contract** as
long as the weights were trained on the *same* per-feature representation.
Because the weights are unknown/unproven (see G3.4), the fractional-bit
convention cannot yet be confirmed against a trained model.

## 4. Actual normalisation formula

```verilog
features_norm[cnt] <= ($signed(features[cnt]) - $signed(mean_vals[cnt]))
                       * $signed(inv_scale[cnt]);
```

The product is a 16-bit x 16-bit signed multiply assigned to a 32-bit signed
register, so it is the full 32-bit two's-complement product (no overflow for
the `|x - mean| <= 65535` x `|inv_scale| <= 32767` range, max 2^31-1).
The normalised value is **not** divided by any 2^12 — the scale is baked
into `inv_scale` and the later MAC shifts. This matches the independent
golden `src/g3_mlp_reference.py` exactly.

## 5. Fixed-point format for mean / inverse scale

Both are plain signed16 registers (`reg signed [15:0]`). There is no
documented Q-format for them in the RTL — they are whatever the (unloaded)
`weight.mi` supplies. **This is a gap**, not a bug: the format is only
meaningful once a valid model is loaded.

## 6. Raw-feature -> normalised Q-format

`norm[i] = s32((s16(raw[i]) - s16(mean[i])) * s16(inv_scale[i]))`. With
`inv_scale = 4096` (=1.0 in Q12) the normalised value equals the raw value,
i.e. the MAC sees the raw signed16. With the generator's non-unit scales
(`4096 + i*32`) the scale is exercised. **Contract verified** by the golden.

## 7. Weight multiply and shift after the MAC

FC1:

```verilog
mac_prod = $signed(features_norm[(cnt-1)%12]) * $signed(fc1_weights[cnt-1]);
mac_next = fc1_out_raw[(cnt-1)/12] + (mac_prod >>> 12);
```

A 48-bit signed product is arithmetic-right-shifted by **12 bits** (the
`WEIGHT_SHIFT`) and accumulated. The shift is a **truncation** (floor for
positive, floor-toward -inf for negative), **not rounding**. The independent
golden uses `>>` on a signed Python int, which is also floor. **Consistent.**

The weight is effectively Q-scaled such that `1.0 = 4096`. The `>>> 12`
restores the unit. This is self-consistent within the RTL; whether it
matches the trained model's quantisation is unknown (G3.4).

## 8. Accumulator width and overflow / saturation

- `mac_temp` is `reg signed [47:0]`; the per-neuron accumulator
  `fc1_out_raw[]` / `fc2_out_raw[]` is `reg signed [31:0]`.
- The MAC saturates **at the 32-bit boundary** (clamps to
  `32'h7FFFFFFF` / `32'h80000000`) and latches `overflow_latch`.
- For a *sane* trained model (|weight| <= ~4096, |norm| <= 32767),
  the largest MAC term is `(32767 * 4096) >>> 12 = 32767` and 12 terms sum to
  `393204`, far below `INT32_MAX`. **Normalised trained weights cannot
  saturate the accumulator**, so the `overflow` flag is only reachable with
  pathological / untrained weight values. It is a defensive signal, not a
  per-inference early-out.

## 8a. **DEFECT FOUND — bias add wraps after MAC saturation (latent)**

The MAC clamp and the bias add are **inconsistent**. In `S_FC1_B` / `S_FC2_B`
the bias is added with a plain 32-bit add:

```verilog
fc1_out_raw[cnt] <= fc1_out_raw[cnt] + $signed(fc1_biases[cnt]);
```

If the MAC step has already saturated the accumulator to `0x7FFFFFFF`, adding
any positive bias **wraps the result to a large negative value**
(`0x7FFFFFFF + 4096 = 0x80000FFF = -2147479552`), and the ReLU stage then
clamps it to 0. The overflow flag (set by the MAC) does **not** survive that
path, so the neuron silently emits 0 instead of the clamped maximum. The
symmetric negative case (`-0x80000000` + negative bias) wraps positive.

- **Impact:** the defect is *latent* — it cannot fire for a well-conditioned
  trained model, because such a model cannot saturate the 32-bit accumulator
  at all (see §8). It only fires with weight values that push the accumulator
  to the clamp boundary, e.g. untrained / pathological / debug values.
- **Status:** **identified, not fixed** — the handoff task forbids refactoring
  RTL in this checkpoint. The defect is pinned by the verification: the
  independent golden `src/g3_mlp_reference.py` models the *exact* current RTL
  behaviour (MAC saturating, bias add wrapping, `s32` truncation), and the
  test vector set includes a dense neuron (neuron 6, bias +4096) that drives
  the accumulator into the wrap. If the RTL is later changed to saturate the
  bias add consistently, the `g3_mlp` test will **fail**, which is intended:
  it forces the golden and the report to be updated in the same change so the
  test cannot silently pass against a changed contract.
- Reproduction (Python, exact values):
  ```
  INT32_MAX = 2147483647
  acc = INT32_MAX                 # after MAC saturation
  bias = 4096
  (acc + bias) & 0xFFFFFFFF       # 0x80000FFF = -2147479553
  relu(-2147479553)              # 0   (expected INT32_MAX)
  ```

## 9. Bias scaling at FC1 and FC2

Both bias stages are plain signed16 adds into the 32-bit accumulator,
**without** a shift: `fc1_out_raw[cnt] + $signed(fc1_biases[cnt])` and
`fc2_out_raw[cnt] + $signed(fc2_biases[cnt])`. So a bias of `1.0` must be
represented as `4096` in the bias register to be consistent with the weights.
This is the contract the independent golden uses. **Verified** that the bias
add cannot overflow 32 bits (a signed16 bias is tiny relative to the 32-bit
accumulator), and that the `S_FC2_B` "double add" (`fc2_out =
fc2_out_raw + fc2_biases` on top of `fc2_out_raw` already containing the
bias) is **correct, not a bug**: both operands read the same pre-update
value, so `fc2_out` = MAC + bias, exactly as the golden computes.

## 10. ReLU sign behaviour

```verilog
if (fc1_out_raw[cnt] > 32'sd0) hidden_out[cnt] <= fc1_out_raw[cnt];
else                           hidden_out[cnt] <= 32'd0;
```

Strictly-positive survives; zero and negative clamp to zero. **Standard
ReLU (0 at 0).** Golden matches.

## 11. Argmax and tie-breaking

```verilog
if (fc2_out_raw[0] >= ... [1] >= ... [2] >= ... [3]) class 0
else if ([1] >= [2] && [1] >= [3])                    class 1
else if ([2] >= [3])                                  class 2
else                                                   class 3
```

All comparisons use `>=`, so **the lowest index wins any tie** (class 0 > 1
> 2 > 3 on equal logits). Golden `argmax` does the same. With the zero
default weights every logit is 0, so **the classifier always returns class 0**
— consistent with the G2.3 report ("placeholder weights produce class 0").

## 12. Reset / soft reset

- `!rst_n` and `soft_reset` both return the FSM to `S_IDLE`, clear `cnt`,
  `done`, `overflow`. The `features_norm`, `hidden_out`, `fc1_out`,
  `fc2_out` registers are only re-written during the run, so a soft reset
  mid-inference discards the in-flight result and the next `start` begins
  clean. Verified by the repeated-inference and soft-reset checks in
  `tb_g3_mlp`.

## 13. Handshake start / done / enable

- `start && enable` latches into `S_LOAD` -> `S_NORM`. `mlp_start` is
  generated by `control_fsm` (`src/control_fsm.v:134-139`) one cycle after
  `feat_valid`. `mlp_done` is a one-cycle pulse from `S_DONE`.
- **Verified** no repeated / unaccepted `mlp_start`: the `replay` bench
  asserts `!(previous_start && dut.mlp_start)` and that every `mlp_start`
  occurs in `u_ai.state == 0` with `sys_enable`.
- `enable` is held high for the demo. A `start` when not idle is rejected
  (FSM only accepts from `S_IDLE`). No deadlock found.

## 14. Effect of RR-invalid / zero convention / ratio clipping on the model

- RR-invalid => `f_rr = f_rr_prev = f_rr_ratio = f_rr_diff = 0` (the
  documented missing-value convention).
- The classifier has **no validity mask**, so an invalid-RR window presents
  four zeros to the model. This is a known G2.3 contract limitation
  (`G2_3_DESIGN_CONTRACT.txt:97-102`): the model cannot tell "physiologically
  zero RR" from "no RR". Recorded as a risk.
- Ratio clipping (`rr_ratio_saturated`) does **not** set the UART error
  flags; it is a diagnostic only.

## 15. The central finding — `weight.mi` is not loaded

`src/ai_classifier.v:63-80` initialises **all** of `fc1_weights`,
`fc1_biases`, `fc2_weights`, `fc2_biases` to `16'd0` and `mean_vals` to 0,
`inv_scale` to `4096`. The comment at `ai_classifier.v:81-86` explicitly
removes the ROM-load port: *"weights are zero-by-design in this demo"*.
There is **no `$readmemh` or parameterisation that pulls `src/weight.mi`
into the classifier** — the file is present only as a `file.other` in
`Bao_rom.gprj` and in the G1 protected-hash list.

**Consequence:** the on-silicon / on-sim MLP is an all-zero network. Every
feature vector normalises to `(x - 0)*4096`, but with zero weights every
hidden activation is zero, every logit is zero, and **argmax returns class 0
for all inputs.** The classifier has **never** produced a non-trivial
classification in this design.

This is the blocker for "integrate and verify the trained MLP" — the
arithmetics are correct, but the model is not wired in.

## 16. Verification performed (TASK 5)

Independent golden: `src/g3_mlp_reference.py` (integer/fixed-point).
RTL testbench: `sim/tb_g3_mlp.sv`, driven by `sim/gen_g3_mlp_vectors.py`,
run through the G2.3 regression (`g3_mlp` group) and standalone.

- 11 directed feature vectors: four reachable classes, tie -> 0, all-negative
  -> ReLU zero, signed16 min/max, a dense saturating neuron with bias 0
  (neuron 7, unambiguous MAC-saturation case) and a dense saturating neuron
  with positive bias (neuron 6, pins the §8a wrap behaviour).
- **184 bit-exact checks** on `fc1_out`, `fc2_out`, `class_code`,
  `overflow` against the independent Python model. **All PASS.**
- Confirms: normalisation (incl. the mean-subtraction path, exercised with
  a non-zero mean), FC1 MAC + bias, ReLU, FC2 MAC + bias, argmax
  tie-breaking, 32-bit MAC saturation, repeated-inference stability, and
  soft reset. **MLP arithmetic verified with non-zero deterministic weights.**

### 16a. Non-vacuity (mutation) evidence

An earlier run of this bench silently passed against an *empty* expectation
file (a `$readmemh` format bug packed several 32-bit words per line). That
was caught, the vector file fixed to one word per line, and a guard was
added that `$fatal`s on an all-zero expectation file. To prove the bench
actually observes the DUT, four RTL mutations were introduced, recompiled
and must each make the bench fail:

| Mutation | Effect | Result |
|---|---|---|
| FC1 MAC shift `>>>12` -> `>>>13` | scales every neuron | **FAIL, 78 checks** |
| argmax `>=` -> `>` on the first compare | changes tie-break | **FAIL, 3 checks** |
| disable the FC1 saturation clamp | wrong accumulator + flag | **FAIL, 4 checks** |
| remove mean subtraction from normalisation | wrong offsets | **FAIL, 61 checks** |

All mutations were reverted; `src/ai_classifier.v` is byte-identical to the
G2.3 baseline (verified by diff). The bench therefore detects real defects,
and its PASS is not vacuous.
