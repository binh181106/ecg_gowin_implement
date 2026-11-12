# G3.3 — Regression Evidence, Toolchain and Blockers

Date: 2026-11-12
Scope: what was actually executed for G3, what the results prove, and what
could **not** be verified in this environment.

---

## 1. Regression result (G3 checkpoint)

Full suite, current tree, executed by `sim/run_g23.py`:

```
python_preprocess: PASS     control: PASS              tracker: PASS
python_arithmetic: PASS     start_accept: PASS         replay: PASS
python_stream: PASS        apb: PASS                  windows: PASS
python_golden: PASS        seq: PASS                  reset_faults: PASS
python_mlp: PASS           class_uart: PASS           g3_mlp: PASS
                          rom_uart: PASS             decoder_selftest: PASS
                          rom_uart_injected: PASS    decoder_captures: PASS
                          reset: PASS
                          g2_rom: PASS
                          g2_checkpoint: PASS
                          g21_preprocess: PASS
                          g21_vectors_g22_math: PASS
                          signed_uart: PASS
                          signed_uart_injected: PASS
                          arithmetic: PASS
protected inputs unchanged: True
```

**27/27 PASS, 0 FAIL, exit code 0.**

Group count: the G2.3 baseline suite was **25** groups (19 simulation + 4
Python invariants + `decoder_selftest` + `decoder_captures`). G3 adds the
`g3_mlp` simulation group and the `python_mlp` vector-generation invariant,
so the suite is now **27**. `sim/run_g23_gowin.py` was updated from its
hard-coded `== 25` gate to `== 27` **and** now additionally requires
`"g3_mlp: PASS" in summary`, so the gate cannot be satisfied by a run that
omitted the new group.

- Evidence: `reports/G3_regression_summary.txt`
- Input hashes at run time: `reports/G3_regression_input_sha256.json`
  (`protected inputs unchanged: True` — the runner re-hashes every source,
  testbench and golden file at the end of the run and fails if anything
  changed while it was running).

## 2. What G3 changed in the RTL: **nothing**

```
$ git diff a9c39b6 -- src/ai_classifier.v
(no output — byte-identical to the G2.3 baseline)
```

G3 is a **verification and documentation** checkpoint. The only tracked
source change is `sim/run_g23.py` (adds the `g3_mlp` group, the
`python_mlp` invariant, and three environment fixes) and
`sim/run_g23_gowin.py` (gate count + path handling).

This is why the G2.3 suite is expected to be unaffected, and it is
confirmed: all 26 pre-existing groups still PASS.

## 3. New verification: the G3 MLP arithmetic bench

| Item | Value |
|---|---|
| Independent golden | `src/g3_mlp_reference.py` (pure Python integers; never reads back from the simulator) |
| RTL testbench | `sim/tb_g3_mlp.sv` |
| Vector generator | `sim/gen_g3_mlp_vectors.py` (deterministic, reproducible) |
| Directed cases | 11 |
| Checks | **184 bit-exact** (fc1 accumulators, fc2 logits, class code, overflow flag) |
| Result | **PASS** |
| Regression group | `g3_mlp` |

Coverage: all four output classes reachable, tie-breaking, all-negative
(ReLU zero), signed16 min/max, MAC saturation (positive and negative),
non-zero mean (offset path), non-zero bias (bias-add path), repeated
inference stability, soft reset.

**The weights are synthetic and deterministic. They are NOT a trained
model.** They exist to prove the fixed-point datapath computes what the
contract says it computes. See `G3_4_WEIGHT_PROVENANCE.md`.

## 4. Non-vacuity evidence (mutation testing)

An early run of this bench passed **vacuously**: the expected-value file
packed several 32-bit words per line, but `$readmemh` assigns **one address
per line**, so every expectation read back as 0 — which matched a DUT whose
weights are zero by design. This was found, fixed (one word per line), and
a guard was added that `$fatal`s if the expectation file is empty/all-zero.

To prove the bench actually observes the DUT, four RTL mutations were
introduced, **recompiled together with the bench**, and each had to make the
bench fail:

| # | Mutation | Detected? |
|---|---|---|
| 1 | FC1 MAC shift `>>> 12` -> `>>> 13` | **FAIL — 78 checks** |
| 2 | argmax first compare `>=` -> `>` | **FAIL — 3 checks** |
| 3 | disable the FC1 saturation clamp | **FAIL — 4 checks** |
| 4 | remove the mean subtraction from normalisation | **FAIL — 61 checks** |

Mutation 4 was initially **not** detected, because the model's `mean` was
all zeros, making the subtraction a no-op. That was a genuine coverage gap;
it was closed by giving the model a non-zero per-feature mean, after which
mutation 4 is caught. All mutations were reverted and
`src/ai_classifier.v` was verified byte-identical to the baseline.

One further mutation (ReLU `>` -> `>=`) is *not* observable with any of the
vectors — for an accumulator of exactly 0 both forms clamp to 0. That is a
property of ReLU itself, not a gap in the bench.

## 5. Defect found and **identified, not fixed**

**Bias add wraps after MAC saturation** (`src/ai_classifier.v`, `S_FC1_B` /
`S_FC2_B`). The MAC clamps the accumulator to the 32-bit boundary, but the
bias is then added with a plain 32-bit add:

```verilog
fc1_out_raw[cnt] <= fc1_out_raw[cnt] + $signed(fc1_biases[cnt]);
```

A saturated-positive accumulator plus a positive bias wraps to a large
negative value, which ReLU then clamps to 0 — undoing the MAC's overflow
protection for that neuron.

- **Latent**: unreachable for a well-conditioned trained model (such a model
  cannot saturate the 32-bit accumulator at all). It only fires with
  pathological / untrained weight values.
- **Not fixed here** by design: this checkpoint is a git handoff and the
  brief forbids RTL refactoring. The defect is *pinned* by the verification —
  the golden models the current RTL exactly and one vector drives a dense
  neuron with a positive bias into the wrap, so a future RTL fix will make
  the `g3_mlp` group **fail**, forcing the golden and the contract
  documentation to be updated in the same change.
- Detail and reproduction: `G3_2_FEATURE_MLP_CONTRACT.md` §8a.

## 6. Environment fixes made to the shared runner (`sim/run_g23.py`)

These are runner/tooling fixes, not RTL changes:

1. **`--out` path must not contain spaces.** Some checkout locations
   include a space in the path; ModelSim re-opens the `-modelsimini` file
   while loading a design and fails with `(vsim-7) EINVAL` on a spaced
   path. The runner now rejects a spaced `--out` with an explicit message.
2. **`(vlog-12110)`** — ModelSim SE forces `-novopt` and counts the
   deprecation notice as an error (exit 1 on success). Suppressed via
   `[msg_system] suppress = 12110` in the generated ini.
3. **`(vlog-13006)` "package (std)"** — the SystemVerilog `std` package
   lives in the **`sv_std`** library, which the stock `modelsim.ini` maps via
   the unset `$MODEL_TECH`. The generated ini now maps `sv_std` explicitly,
   and the Gowin `prim_sim.v` is compiled as **Verilog-2001** separately
   (under `-sv` the identifier `std` in its port declarations is parsed as a
   package import and every module fails).
4. **Tcl `do` path** — backslashes are escape characters in Tcl; the runner
   now always passes a forward-slash path.
5. **`sim/run_g23_gowin.py`** — same space-free-path rule, plus the gate
   count update described in §1.

## 7. BLOCKED — Gowin synthesis / P&R (TASK 7)

**Status: BLOCKED — not verified. No FPGA timing or area claim is made.**

The G3 RTL is byte-identical to the G2.3 baseline, so no implementation
delta exists to characterise; but the task's gate (run the Gowin flow and
compare area / Fmax / WNS / TNS / critical path against the G2.3 report)
could not be completed in this environment:

- The repo's runner `sim/run_g23_gowin.py` emits a Tcl that opens the
  project with `open_project`. The **installed** Gowin is **V1.9.9**
  (`C:\Gowin\Gowin_V1.9.12.01_x64` is a junction to it) while the repo
  expects **V1.9.12.01**. This build has no `open_project` command at all,
  and `gw_sh` fails immediately with `invalid command name "open_project"`.
- A manual equivalent was attempted with the commands this build does
  provide (`create_project` / `add_file` / `set_option` / `run all`).
  `create_project` then rejected the project part
  `GW5A-LV25UG324C2/I1` with *"The target device does not have device
  version"* / *"device GW5A-LV25UG324C2/I1 has not version"* for every
  `-device_version` value tried (NA/B/C/D and the bare part number). The
  device database directory lists `GW5A-25A` and `GW5A-LV25UG324C2/I1` is
  the part recorded in `Bao_rom.gprj`, so the part/version handling in this
  older build does not match the project's device string.
- This build's `set_option` also has no `-global_freq` option (a V1.9.12
  option the G2.1 contract depends on); it exposes `-frequency` instead.
  Reproducing the G2.3 comparison would therefore also require a documented
  decision on the frequency option.

**Deliberately not done:** the brief for this checkpoint forbids changing
the RTL or the Gowin project merely to work around a tool-configuration
problem. The device/project strings and the synthesis options were left
untouched, and no generated build output is committed.

**Consequence for the record:** the G3 checkpoint has **no** synthesis,
place-and-route, timing or resource data. Any statement about area, Fmax,
WNS, TNS or the critical path for G3 would be unfounded — the correct
statement is that the G3 RTL is unchanged from G2.3, whose implementation
results remain the reference.

## 8. Summary of the G3 verification position

| Claim | Status | Evidence |
|---|---|---|
| G2.3 behaviour unchanged by G3 | **PASS** | 26/26 pre-existing groups PASS; `src/` byte-identical to `a9c39b6` |
| MLP fixed-point arithmetic correct | **PASS** | 184 bit-exact checks vs an independent Python golden; 4/4 mutations caught |
| Bench is not vacuous | **PASS** | 4 RTL mutations each produce failures; all-zero expectation file is now fatal |
| Trained-model integration | **BLOCKED** | `weight.mi` provenance unprovable — see `G3_4_WEIGHT_PROVENANCE.md` |
| Bias-add wrap after MAC saturation | **IDENTIFIED, NOT FIXED** | pinned by the bench; latent for realistic weights — see §5 |
| Synthesis / P&R / timing | **BLOCKED** | Gowin V1.9.9 vs expected V1.9.12.01; see §7 |
