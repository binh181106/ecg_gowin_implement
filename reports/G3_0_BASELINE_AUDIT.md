# G3.0 — Baseline Audit

Date: 2026-11-12
Branch: `feat/g3-trained-mlp`
Baseline commit: `a9c39b60f4d250c7224a4a09969a83edfa4fc2c1`
Repository: https://github.com/binh181106/ecg_gowin_implement

## 1. Repository state

| Item | Value |
|---|---|
| Working copy used | a separate `git worktree` of this repository on branch `feat/g3-trained-mlp` (the main worktree stays on `main` and was not touched) |
| HEAD at start | `a9c39b6` feat(g2.3): implement continuous RR tracker and zero crossing |
| `origin/feat/g3-trained-mlp` | `a9c39b6` (identical to HEAD) |
| `origin/improve/g2-feature-extraction` | `a9c39b6` (identical) |
| `origin/fix/g1-control-apb-mlp` | `1fb2594` (G1 tip) |
| `origin/main` | `409877a` "Handoff" |
| Local `main` worktree | `ecg_gowin_implement`, has **uncommitted build artifacts** in `impl/` |

The task statement said "verify actual state, do not assume". Verified: the
review note that G3 and G2 point at the same commit **is still correct** —
`feat/g3-trained-mlp` == `improve/g2-feature-extraction` == `a9c39b6`.

**Action taken:** all G3 work was done in a dedicated `git worktree`
(`g3_wt`) on a local branch `feat/g3-trained-mlp` tracking the remote. The
original `ecg_gowin_implement` worktree was **not** modified, so the
uncommitted `impl/` artifacts there are preserved untouched.

Commit chain on the branch:

```
a9c39b6 feat(g2.3): implement continuous RR tracker and zero crossing
1834285 fix(g2.2): correct RMS variance and crest arithmetic
a6d604f feat(g2.1): implement signed ECG preprocessing
1fb2594 fix(g1): verify control FSM APB and UART class handshake
409877a Handoff            <- origin/main
```

## 2. Module function table and dataflow

| Module | File | Role |
|---|---|---|
| `ecg_rom` | `src/ecg_rom.v` | 2048x8 ROM of unsigned ADC codes (`src/ecg_rom.hex`) |
| `sample_pacer` | `src/sample_pacer.v` | Fractional-N clock enable; paces ROM at `TARGET_HZ` |
| `adc_interface` | `src/adc_interface.v` | Sample capture / overflow flag |
| `window_buffer` | `src/window_buffer.v` | Dual-bank 512-sample RAM, 256 stride; signed preprocess; exports the accepted sample stream for RR |
| `rr_tracker` | `src/rr_tracker.v` | **New in G2.3.** Continuous chronological peak detection, refractory, RR history |
| `feature_extraction` | `src/feature_extraction.v` | 12 signed16 features (RMS, var, peak, ZC, ptp, crest, half-ratio, max, RR x4) |
| `ai_classifier` | `src/ai_classifier.v` | 12->8->4 MLP: normalize, FC1, ReLU, FC2, argmax |
| `control_fsm` | `src/control_fsm.v` | Orchestrates window -> feature -> MLP -> result; timeouts; fail-stop error state |
| `apb_slave_if` | `src/apb_slave_if.v` | APB CSR block (enable/start/threshold/baud/class/overflow) |
| `demo_apb_seq` | `src/demo_apb_seq.v` | APB sequencer that programs the demo |
| `demo_uart_packetizer` | `src/demo_uart_packetizer.v` | 33-byte packet builder (12 features + class + flags + checksum) |
| `uart_tx` | `src/uart_tx.v` | 8N1 UART transmitter |
| `top_ecg_rom_demo` | `src/top_ecg_rom_demo.v` | Demo integration top |
| `top_ecg_acg525_board` | `src/top_ecg_acg525_board.v` | Board top (synthesis top) |

Dataflow (verified by reading the RTL):

```
ecg_rom -> sample_pacer -> adc_interface -> window_buffer (signed, dual bank)
                                        |-> preprocessed_sample -> rr_tracker
window_ready -> [RR snapshot latch]
feature_start -> feature_extraction (reads 512 samples from the RAM)
             -> feature_valid -> features_flat[191:0]
             -> control_fsm mlp_start -> ai_classifier -> class_code/mlp_done
             -> demo_uart_packetizer -> uart_tx -> 33-byte packet
```

## 3. Build/project wiring

`Bao_rom.gprj` lists **all 15 RTL sources plus `src/weight.mi`**:

```
src/adc_interface.v  src/ai_classifier.v  src/apb_slave_if.v
src/control_fsm.v    src/demo_apb_seq.v   src/demo_uart_packetizer.v
src/ecg_board.cst    src/ecg_board.sdc    src/ecg_rom.hex
src/ecg_rom.v        src/feature_extraction.v  src/golden_model.py
src/gowin_dpb/gowin_dpb.v   src/gowin_sdpb/gowin_sdpb.v
src/rr_tracker.v     src/sample_pacer.v   src/top_ecg_acg525_board.v
src/top_ecg_rom_demo.v  src/uart_decode.py  src/uart_tx.v
src/weight.mi        src/window_buffer.v
```

- `src/weight.mi` is present with `type="file.other"` — Gowin treats it as an
  opaque file, **it is not a Verilog memory-init file and is never compiled**.
- `src/ecg_board.sdc`: `create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]`
  => 50 MHz.
- `src/ecg_board.cst`: `IO_LOC "sys_clk" T9;`
- `src/ecg_rom.hex` path used by `ecg_rom.v` via the `ROM_HEX` parameter
  (`"demo/ecg_rom.hex"` default, overridden to `src/ecg_rom.hex` by the tops).
  **Note:** the default parameter value `demo/ecg_rom.hex` does not exist in
  the repository; every instantiation overrides it, so this is dormant.

## 4. Clock / UART consistency — **finding**

| Source | Value |
|---|---|
| SDC `create_clock` | 20.000 ns => **50.000 MHz** |
| `CLK_HZ` parameter | `50_000_000` (top_ecg_rom_demo, top_ecg_acg525_board, sample_pacer) |
| UART `CLKS_PER_BIT` | `437` |
| APB `baud_div` default | `16'd437` |
| `demo_apb_seq` `D_BAUD` | `32'h0000_01B5` = 437, commented "437 = 115200 @ 50.4 MHz" |

437 clks/bit at 50 MHz = **114416.5 baud**, i.e. **-0.68 %** from 115200.
Conversely 437 clks/bit at 115200 baud implies a **50.3424 MHz** clock, which
matches the `demo_apb_seq` comment ("@ 50.4 MHz") but contradicts the SDC
(20 ns = 50 MHz) and `CLK_HZ` (50 MHz).

So the UART divisor was derived for a ~50.34 MHz oscillator while the
constraint and the RTL parameter say 50 MHz. The resulting baud error
(-0.68 %) is within normal UART tolerance, but **the three sources are not
consistent with each other** and the true board oscillator was not verified.
Recorded as an open item in `G3_FINAL_REPORT.md`; **not** changed here
(changing the clock target is explicitly forbidden by the task).

## 5. Prior reports read — evidence quality

| Report | Claim | Assessment |
|---|---|---|
| `CHECKPOINT_G2_HANDOFF.md` | G2 handoff, states weight-model is not real | Consistent with the RTL: zero placeholder weights |
| `G2_2_DESIGN_CONTRACT.txt` | Written before the G2.2 edit; lists audited defects | Genuinely pre-edit; the listed defects (unsigned peak, `mean_sq` truncation, `abs(-128)`) are all visible in the `1834285` diff |
| `G2_2_REPORT.txt` | 21 regression groups, synthesis Fmax 84.031 MHz | Has command/log evidence; the impl/ artifacts are committed |
| `G2_3_DESIGN_CONTRACT.txt` | Written before the G2.3 edit; enumerates confirmed bugs | Genuinely pre-edit and specific (e.g. "first event is a distance from window start, not an RR interval") |
| `G2_3_REPORT.txt` | 25/25 groups PASS; "no trained MLP integration" | Re-executed independently in this audit — see `G3_2_FEATURE_MLP_CONTRACT.md` |

The contracts are honest pre-edit documents, not post-hoc rationalisation.

## 6. Baseline synthesis numbers (for later comparison)

From the committed `impl/pnr/` artifacts of `a9c39b6` (Gowin V1.9.9,
GW5A-LV25UG324C2/I1):

- Logic 1997/23040 (9%), Register 1089/23685 (5%), CLS 1396/11520 (13%),
  I/O 7, BSRAM 4% (1 SDPB, 1 pROM), DSP 17%
- **Fmax 76.809 MHz**, Setup WNS **+6.981 ns**, Hold WNS **+0.238 ns**,
  Setup/Hold TNS **0/0**
- (G2.2 baseline was Fmax 84.031 MHz, Setup WNS +8.100 ns, Hold WNS +0.203 ns)

## 7. TASK 0 conclusion

- Baseline preserved; no source, golden, waveform, report or build artifact
  was modified or overwritten in this phase.
- The G2.3 head is confirmed at `a9c39b6` on both G3 and G2 branches.
- One pre-existing inconsistency found (SDC/`CLK_HZ` 50 MHz vs UART divisor
  437 derived for 50.3424 MHz). Not modified; carried forward.
