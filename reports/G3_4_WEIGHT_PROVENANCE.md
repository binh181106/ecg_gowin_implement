# G3.4 — Trained Weight / Normalization Provenance Audit

Date: 2026-11-12
Subject: `src/weight.mi` — is it a trained model, and can it be integrated?

**Verdict: NO. `src/weight.mi` cannot be established as a trained model, and
integrating it as-is is unsafe. Trained-model integration is BLOCKED.**

The file's *shape* fits the 12->8->4 architecture exactly, but every
provenance question the task asks is unanswerable from the repository, and
the file fails objective plausibility checks against the G2.3 feature
statistics. Independently of all that, the RTL never reads the file at all.

---

## 1. What the file actually is

```
#File_format=Hex
#Address_depth=164
#Data_width=16
<164 hex words, 16-bit>
```

- 164 values x 16 bits. No manifest, no comments, no class labels, no
  metadata of any kind beyond the three header lines.
- All values are distinct and non-zero; 2 values are exactly `0x7FFF`
  (= +32767), 0 values are `-32768`.
- Parsed as signed16, the value ranges are:

| Assumed slice | count | min | max | zeros |
|---|---|---|---|---|
| FC1 weights | 96 | -13662 | +32767 | 0 |
| FC1 biases | 8 | -565 | +580 | 0 |
| FC2 weights | 32 | -12861 | +19730 | 0 |
| FC2 biases | 4 | -2795 | +5497 | 0 |
| mean | 12 | -25578 | +7178 | 0 |
| inv_scale | 12 | -8802 | +13025 | 0 |

The **counts** (96 + 8 + 32 + 4 + 12 + 12 = 164) match a 12->8->4 MLP with
per-feature normalisation. **That is the only thing that matches.** As the
task statement itself warns, "the number matching does not prove order,
Q-format, quantisation or model validity".

## 2. Provenance search — everything is missing

Searched the **entire** repository history (18 commits, all branches):

```
git log --all --diff-filter=D --name-only   -> no deleted files
git log --all --pretty=format: --name-only  -> complete file inventory
git log --all -S"weight.mi" -- src/ai_classifier.v -> no hits
git log --all --oneline -- src/ai_classifier.v     -> 1 commit: e835aad "ayna"
```

| Required artefact | Present? | Evidence |
|---|---|---|
| Training script | **NO** | no `*.py`/notebook anywhere references training |
| Model checkpoint / trained weights export | **NO** | `weight.mi` is the only candidate, with no manifest |
| Scaler / normaliser object | **NO** | the mean+inv_scale slice is inside the opaque file |
| Dataset + label source | **NO** | no dataset, no MIT-BIH/CSV/record reference |
| Class label mapping (4 classes) | **NO** | nothing maps class codes 0..3 to conditions |
| Train/validation split (patient-level) | **NO** | — |
| Feature-pipeline version used at train time | **NO** | — |
| Accuracy / confusion matrix | **NO** | — |

The only mentions of "trained" in the repo are negative statements:
`src/golden_model.py:36` ("placeholder ZERO weights"), `G2_2_REPORT.txt:283`
("Placeholder weights giữ nguyên"), `G2_3_REPORT.txt:401` ("weights remain
placeholders and no trained-model integration was started").

**`weight.mi` was introduced in the very first commit `e835aad "ayna"`**
together with `ai_classifier.v`, and has never been modified. It arrived with
no provenance, and the only code that has ever consumed the file is the G1
protected-hash list (`sim/run_g1.py:33`), which merely checks that it does
not change.

## 3. Decisive objective checks

### 3.1 The file is never read by the design

```
$ grep -rn "weight.mi|readmem" --include=*.v --include=*.sv --include=*.py .
./Bao_rom.gprj:30:  <File path="src/weight.mi" type="file.other" enable="1"/>
./sim/run_g1.py:33: ... "golden_model.py", "weight.mi"]] + ...
```

`type="file.other"` means Gowin treats it as an opaque project file — **it is
not a Verilog memory-init file** (`$readmemh` needs a `module`+`reg` target
anyway, and `weight.mi` has no module). `ai_classifier.v` has **no**
`$readmemh`, no parameter for a weight file, and its initial block sets all
weights to zero. The comment at `ai_classifier.v:81-86` says so explicitly.

**Therefore the MLP has never executed with non-zero weights in any commit of
this repository.**

### 3.2 The assumed normaliser is implausible

Using the assumed layout (mean at 140..151, inv_scale at 152..163) and
applying it to the actual G2.3 feature vectors:

- **6 of the 12 "inverse scales" are negative.** An inverse standard
  deviation is by definition positive; a negative value would *flip* the
  sign of the standardised feature.
- The resulting normalised magnitudes are ~1e8 (`range [-2.2e8, 5.4e7]`).
  With any weight of magnitude >= 1 the MAC term
  `(norm * w) >>> 12` immediately exceeds 2^31, so **every** unit would
  saturate on the first MAC step and the output would be constant garbage.

I tested four plausible alternative layouts (mean/inv at the front, swapped,
and at offset 24/36). Layout B (`mean` at 0, `inv` at 12) is the only one
with all-positive inverse scales, but it still yields post-normalisation
magnitudes ~2e7 and a mean of -2.3e7 — far from the zero-mean/unit-variance
property a normaliser must have.

**Conclusion:** under every layout hypothesis, the file's normaliser cannot
have been produced by fitting the G2.3 feature pipeline. If it came from a
real scaler, it was fitted to a *different* feature pipeline.

### 3.3 The assumed mean does not match the G2.3 feature statistics

G2.3 feature statistics over the 7 ROM windows (`src/g23_reference.py`
pipeline, `rom-centered` preprocessing):

| f | feature | G2.3 mean | `weight.mi` assumed mean | ratio |
|---|---|---|---|---|
| 0 | rms | 89.9 | -3747 | -41.7 |
| 1 | var | 764.7 | -279 | -0.36 |
| 2 | peak | 119.4 | -25578 | -214.2 |
| 3 | zc | 3.3 | 2038 | +620.3 |
| 4 | ptp | 244.3 | -4 | -0.02 |
| 5 | crest | 356.9 | -4031 | -11.3 |
| 6 | half_ratio | 93.7 | -1075 | -11.5 |
| 7 | max | 119.4 | -3689 | -30.9 |
| 8 | rr | 252.4 | 7178 | +28.4 |
| 9 | rr_prev | 210.7 | 2291 | +10.9 |
| 10 | rr_ratio | 3021.9 | 3583 | +1.19 |
| 11 | rr_diff | 1.1 | -24991 | -21867 |

The means span ratios from -21867x to +620x. A scaler fitted to this
pipeline would track these values closely (they are the direct output of the
feature module). It does not.

*(Caveat, stated honestly: the ROM demo is 2048 samples / 7 windows — a
single synthetic record. Its per-feature statistics are not the statistics
of a real training set. So this test shows the file's means are inconsistent
with **the G2.3 pipeline's output distribution**; it cannot by itself prove
the file was not trained on some *other* pipeline. That is precisely why the
absence of a training script, dataset and class mapping is decisive.)*

### 3.4 Serialization order, endianness and quantisation — UNKNOWN

- **Order:** only the counts are inferable; the per-field order inside each
  block is unconstrained by the file. Neural-network weight layouts are
  commonly row-major or input-major, and `ai_classifier` indexes
  `fc1_weights[(cnt-1)%12]` (input-major within a neuron). A mismatch here
  silently scrambles the network while still producing plausible-looking
  outputs.
- **Endianness:** the file is one hex word per line, so no byte-order
  question arises for the file itself; but it does not tell us whether the
  value is two's-complement signed16 (assumed) or offset-binary.
- **Quantisation scale:** unknown. The RTL's `>>> 12` implies weights with
  1.0 == 4096, and `inv_scale` is likewise Q12-ish. Whether the file's
  values were produced by that quantiser is unknowable without the exporter.
- **Class label mapping:** completely absent. Even with a perfect file,
  nothing maps class 0..3 to N/S/V/F or any other labelling.

## 4. What CAN be verified

- The file is 164 x 16-bit, consistent with a 12->8->4 MLP + per-feature
  normaliser. **PASS** (shape only).
- The file is stable and protected: it is in the G1 protected-hash list and
  the regression confirms `protected inputs unchanged: True`. **PASS**.
- The file is syntactically well-formed for a Gowin `file.other` entry and
  does not break the build. **PASS** (it is simply ignored).

## 5. Why integrating it as-is would be wrong

Loading `weight.mi` into `ai_classifier` with the assumed layout would:

1. produce **negative "inverse scales"** for 6 of 12 features, flipping the
   sign of half the standardised features;
2. drive every MAC into **immediate 32-bit saturation** (normalised values
   ~1e8), so the argmax output would be a constant, not a classification;
3. rest on an **unproven weight order**, so even a well-conditioned file
   could be scrambled;
4. be presented to the user as "the trained model works", when **no
   accuracy has ever been measured** and none of the four class labels is
   defined anywhere.

The task explicitly forbids this: *"Không tự tạo trọng số AI giả rồi gọi là
trained model"* and *"Không tự giả định"*. Treating an unproven file as a
trained model — and worse, presenting a saturated/constant classifier as a
working 4-class detector — would violate both the letter and the spirit of
the task.

## 6. What WAS done instead (the honest split)

The task requires keeping these two states separate, and they are kept
separate:

| State | Status | Evidence |
|---|---|---|
| **MLP arithmetic verified** (normalisation, FC1 MAC, ReLU, FC2 MAC, argmax, saturation, reset, handshake) with **deterministic, clearly-synthetic, documented** non-zero weights | **PASS** | `sim/tb_g3_mlp.sv`, 184 bit-exact checks vs `src/g3_mlp_reference.py`, all 4 classes reachable, MAC saturation exercised, repeated inference + soft reset. Regression group `g3_mlp`. |
| **Trained-model integration** (real weights, real normaliser, class semantics, accuracy) | **BLOCKED** | Missing: training script, checkpoint, scaler, dataset, label mapping, train/val split, train-time feature-pipeline version, measured accuracy. |

The synthetic weights used for the arithmetic proof are generated by
`sim/gen_g3_mlp_vectors.py` with a documented, reproducible rule (sparse
diagonal network + one deliberately dense saturating neuron). They are
labelled "NOT a trained model" in the generator docstring, in the generated
force file header, and in the testbench header.

## 7. Recommendation for unblocking (needs the user)

To complete the trained-model integration, the following must be supplied —
none of it can be reconstructed from this repository:

1. **The training script** (or the exact export procedure that produced
   `weight.mi`), including the weight layout, the Q-format of the weights,
   the mean/inv-scale convention, and the sign convention.
2. **The dataset** with labels, and the **patient/record-level split**, so
   accuracy can be measured without leakage.
3. **The class label mapping** (which class code is which condition).
4. **Confirmation that the features were computed with the G2.3 pipeline**
   (signed preprocessing, Q8.8 RMS, population variance, absolute crest,
   nonzero-skipping ZC, continuous RR) — the G2.2 report already states the
   existing trained statistics are incompatible with the G2.2 numerics, and
   G2.3 changed features 3 and 8..11 again.
5. Ideally: a **retrained model** using the G2.3 pipeline, since the current
   pipeline's numeric conventions changed in G2.2 and again in G2.3.

Only then can `weight.mi` be replaced by a verified file, wired into
`ai_classifier` (a real `$readmemh` against a `reg` array), and the
end-to-end test extended from "arithmetic" to "classification accuracy".

**Until then the correct, honest state is: the MLP computes correctly and
can be proven to do so; it is not yet connected to a real model.**
