# G3 — Final Report (Feature Extraction ↔ MLP integration)

Date: 2026-11-12
Branch: `feat/g3-trained-mlp`
Baseline: `a9c39b6` ("feat(g2.3): implement continuous RR tracker and zero crossing")

---

## 1. Headline

**G3 is a partial checkpoint. Two things are done and verified; two are
blocked.**

| # | Item | Status |
|---|---|---|
| 1 | Feature Extraction ↔ MLP interface contract audited and documented | **DONE** |
| 2 | MLP fixed-point arithmetic verified against an independent golden | **DONE — 184/184 checks PASS** |
| 3 | Trained-model integration from `src/weight.mi` | **BLOCKED** — provenance unprovable |
| 4 | Gowin synthesis / P&R / timing comparison | **BLOCKED** — tool version mismatch |

**G3 is NOT complete.** The classifier in this design still runs with
zero weights and always returns class 0. No trained model is integrated and
no accuracy has ever been measured.

## 2. What was done

### 2.1 Interface contract (documented, verified)

The full path `Feature Extraction -> features_flat -> Normalization -> FC1
-> ReLU -> FC2 -> Argmax -> class_code` was audited line by line against
the RTL and an independent Python model.

- **Feature order is correct.** `features_flat` puts `f_rms` at the LSB;
  `ai_classifier` unpacks `features[g] = features_flat[g*16 +: 16]`, which
  matches the frozen `feature_order` in `src/golden/g21_reference.py`.
- **Signedness / sign extension is correct.** All feature words are signed16,
  every arithmetic use is wrapped in `$signed(...)`, and the accumulators are
  explicitly signed.
- **The Q-format contract is now explicit**: normalisation is
  `norm[i] = (raw[i] - mean[i]) * inv_scale[i]` evaluated at 32 bits — a
  plain *multiply*, not a Q-division. The `2^12` scale restoration is folded
  into the MAC shift (`>>> 12`), and the shift truncates toward -inf in both
  the RTL and the golden.
- **Argmax tie-breaking** is lowest-index-wins (`>=` comparisons in index
  order), matching the golden.
- **Reset / handshake** behaviour is sound: hard and soft reset both return
  the FSM to idle and clear the error state; `start` is only accepted from
  idle; `mlp_done` is a one-cycle pulse.

Full detail: `reports/G3_2_FEATURE_MLP_CONTRACT.md`.

### 2.2 Arithmetic verification (the substance of this checkpoint)

A new independent golden (`src/g3_mlp_reference.py`) computes normalisation,
FC1, ReLU, FC2 and argmax in pure Python integers from the frozen contract,
never reading back from a simulator. A new bench (`sim/tb_g3_mlp.sv`) forces
a deterministic synthetic weight set into the **real** `ai_classifier`
datapath and compares every intermediate value.

- 11 directed vectors, **184 bit-exact checks**, **all PASS**.
- All four output classes reachable; tie, all-negative, signed16 extremes,
  positive and negative MAC saturation, non-zero mean and non-zero bias all
  covered; repeated inference and soft reset checked.
- Wired into the shared suite as the `g3_mlp` group.

**The weights are synthetic and deterministic, and are labelled as such in
the generator docstring, the generated force-file header and the bench
header. They are not a trained model and no accuracy is claimed.**

### 2.3 Non-vacuity (the important part)

The first version of this bench **passed vacuously**: the expectation file
packed several 32-bit words per line, but `$readmemh` assigns one address
per line, so every expectation read back as 0 — matching a DUT whose weights
are zero by design. This was found and fixed, and a `$fatal` guard on an
all-zero expectation file was added.

The bench was then shown to observe the DUT by mutation testing: four RTL
mutations (MAC shift, argmax tie-break, saturation clamp, mean subtraction)
were each introduced, recompiled, and each made the bench fail
(78 / 3 / 4 / 61 checks). One mutation (mean subtraction) was initially
**not** caught, revealing a real coverage gap; it was closed by giving the
model a non-zero mean, after which it is caught.

## 3. What is blocked

### 3.1 Trained-model integration — BLOCKED

`src/weight.mi` cannot be established as a trained model:

- **Shape only**: 164 x 16-bit, consistent with a 12->8->4 MLP plus a
  per-feature normaliser. Nothing more is provable from the file.
- **No provenance exists in the repository or its history** (18 commits, all
  branches): no training script, no checkpoint, no scaler object, no
  dataset, no label mapping, no train/validation split, no train-time
  feature-pipeline version, no measured accuracy. The file arrived in the
  very first commit (`e835aad "ayna"`) and has never been modified.
- **The RTL never reads it.** `ai_classifier.v` has no `$readmemh` and no
  weight-file parameter; `Bao_rom.gprj` lists the file as `type="file.other"`
  (an opaque project file). The comment at `ai_classifier.v:81-86` states
  the weights are zero-by-design. **The MLP has therefore never executed
  with non-zero weights in any commit of this repository.**
- **Objective plausibility checks fail.** Under the assumed layout, 6 of the
  12 "inverse scales" are *negative*; the implied normalisation magnitudes
  (~1e8) would saturate every MAC on the first step; and the assumed means
  bear no relation to the G2.3 feature statistics (ratios from -21867x to
  +620x). Under every alternative layout hypothesis tried, the file's
  normaliser cannot have been produced by fitting the G2.3 pipeline.
- **Order, endianness, quantisation and class semantics are all unknown**,
  and the class-code-to-condition mapping is absent entirely.

Loading it as-is would produce a constant, sign-flipped, saturated
classifier that could not legitimately be presented as a 4-class detector.

Detail: `reports/G3_4_WEIGHT_PROVENANCE.md`.

**To unblock**, the following must be supplied (none is reconstructible
from this repository): the training/export script with the weight layout,
Q-format and sign convention; the labelled dataset and a patient-level
split; the class-code mapping; confirmation that the features were computed
with the G2.3 pipeline (which changed in G2.2 and again in G2.3); ideally a
retrained model on the current pipeline.

### 3.2 Gowin synthesis / P&R — BLOCKED

The G3 RTL is byte-identical to the G2.3 baseline, so there is no
implementation delta to characterise. However the build could not be run:
the installed Gowin is **V1.9.9** while the repo expects **V1.9.12.01**, and
the runner's `open_project` command does not exist in the older build
(`invalid command name "open_project"`). A manual equivalent using this
build's `create_project` / `add_file` / `run all` was rejected by the
project's own part string (`GW5A-LV25UG324C2/I1`: *"The target device does
not have device version"*), and this build's `set_option` has no
`-global_freq`.

Per the brief, the RTL and the Gowin project were **not** altered to work
around a tool-configuration problem, and no generated build output is
committed. **This checkpoint therefore carries no area, Fmax, WNS, TNS or
critical-path data, and none is claimed.** The G2.3 implementation results
remain the reference.

Detail: `reports/G3_3_REGRESSION_AND_TOOLCHAIN.md` §7.

## 4. Defect found, identified, deliberately not fixed

**The bias add wraps after MAC saturation** (`ai_classifier.v`, `S_FC1_B` /
`S_FC2_B`). The MAC clamps the accumulator to the 32-bit boundary; the bias
is then added with a plain 32-bit add, so a saturated-positive accumulator
plus a positive bias wraps to a large negative value and ReLU clamps it to
0 — undoing the overflow protection for that neuron.

- **Latent**: unreachable with a well-conditioned trained model, since such a
  model cannot saturate the 32-bit accumulator. It fires only with
  pathological / untrained weights.
- **Not fixed in this checkpoint** (this is a git handoff, not an RTL
  refactor), but **pinned**: the golden models the current RTL exactly and
  a vector drives a dense neuron with a positive bias into the wrap, so a
  future RTL fix makes the `g3_mlp` group fail — forcing the golden and the
  contract docs to be updated in the same change rather than the test
  silently passing against a changed contract.

## 5. Regression evidence

```
27/27 PASS, 0 FAIL, exit 0
protected inputs unchanged: True
```

The G2.3 baseline suite was 25 groups; G3 adds `g3_mlp` and the
`python_mlp` invariant, giving 27. The Gowin gate in
`sim/run_g23_gowin.py` was updated from `== 25` to `== 27` and now also
requires `"g3_mlp: PASS"`, so it cannot be satisfied by a run that omitted
the new group. All 26 pre-existing groups still PASS, consistent with G3
changing no RTL.

- `reports/G3_regression_summary.txt`
- `reports/G3_regression_input_sha256.json`

## 6. Files added by G3

| File | Purpose |
|---|---|
| `src/g3_mlp_reference.py` | independent integer fixed-point golden |
| `sim/tb_g3_mlp.sv` | RTL testbench against the real `ai_classifier` |
| `sim/gen_g3_mlp_vectors.py` | deterministic vector/force generator |
| `sim/tb_g3_probe.sv` | one-off layout probe (documented, not in the regression) |
| `reports/G3_0_BASELINE_AUDIT.md` | baseline audit |
| `reports/G3_1_G2_PATCH_REVIEW.md` | G2 patch review |
| `reports/G3_2_FEATURE_MLP_CONTRACT.md` | interface contract |
| `reports/G3_3_REGRESSION_AND_TOOLCHAIN.md` | regression, toolchain, blockers |
| `reports/G3_4_WEIGHT_PROVENANCE.md` | weight provenance audit |
| `reports/G3_FINAL_REPORT.md` | this report |
| `reports/G3_regression_summary.txt` | regression output |
| `reports/G3_regression_input_sha256.json` | run-time input hashes |

## 7. Honest status statement

**What is true today:** the ECG datapath extracts 12 features correctly, and
a 12->8->4 MLP datapath computes those features into a 4-way argmax with
**verified bit-exact fixed-point arithmetic** — verified against an
independent model, with proof (via mutation testing) that the verification
would catch real defects.

**What is not true today:** that the design performs ECG classification. The
classifier is still a zero-weight network that returns class 0 for every
input. No trained model is loaded, no class label mapping exists, and no
accuracy figure has been produced. Two G3 objectives — trained-model
integration and the implementation comparison — remain blocked for reasons
documented above, and both require input that this repository does not
contain.
