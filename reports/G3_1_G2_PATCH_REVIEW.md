# G3.1 — G2.2 / G2.3 Patch Review

Date: 2026-11-12
Reviewer scope: direct RTL and testbench inspection (not report reading only).

## 0. Method

Every claim below was checked against the RTL at `a9c39b6` and, where a
behavioural statement is made, against a re-executed simulation or an
independent Python computation. Commands and logs are in
`G3_FINAL_REPORT.md`.

Commits reviewed:
- G2.1 `a6d604f` feat(g2.1): implement signed ECG preprocessing
- G2.2 `1834285` fix(g2.2): correct RMS variance and crest arithmetic
- G2.3 `a9c39b6` feat(g2.3): implement continuous RR tracker and zero crossing

---

## 1. G2.2 — `src/feature_extraction.v`

### 1.1 RMS Q8.8, `isqrt`, radicand and rounding

| Item | Before (`a6d604f`) | After (`1834285`) |
|---|---|---|
| Radicand | `{mean_sq, 16'd0}` where `mean_sq = sum_square[24:9]` | `rms_radicand = {1'b0, sum_square[23:0], 7'd0}` = `sum_square << 7` |
| Root width | `sq_cand/sq_trial` 20 bit | 18 bit |
| Output | `f_rms <= sq_root[15:8]` | unchanged |

**Old algorithm:** the integer mean-square was computed *first*
(`sum_square >> 9`), throwing away the fractional part, then squared up by
`<<16`. Result: `RMS = isqrt(floor(S2/512) * 65536)`, i.e. a systematic
downward bias of up to ~0.1 % of RMS and a coarse quantisation step of
`sqrt(65536) = 256` in the radicand.

**New algorithm:** `RMS = isqrt(S2 << 7)`, which is exactly
`isqrt(S2 * 65536 / 512)` — the fractional mean-square is preserved because
the division is folded into the radicand. Verified numerically against
`math.isqrt` in `src/g22_reference.py` (`rms_fp = isqrt(energy*128)`) and by
the `arithmetic` / `g21_vectors_g22_math` benches.

**Rounding:** the restoring square-root is a floor operation by
construction (`sq_root = floor(sqrt(prefix))` invariant, commented at
`src/feature_extraction.v:111-115`). The Python golden uses `math.isqrt`,
also floor. **No rounding bias was introduced** — truncation is the
documented contract for both.

**Risk:** `sq_rem` is 16 bits and the comment claims `<= 65534 for radicand
<= 2^30`. For radicand `R <= 2^30`, the remainder satisfies
`rem <= 2*sqrt(R) <= 2*32768 = 65536`, which **exceeds 16 bits by one bit**
in the extreme. The bound `<= 65534` holds because `R <= 2^30` gives
`rem = R - root^2` with `root <= 32768`, so `rem <= 65535` — i.e. the claim
is marginally tight but the value cannot exceed 0xFFFF, so no truncation
occurs. Verified: the legal window bound is `S2 <= 512*128^2 = 2^23`, so
`R = S2<<7 <= 2^30`, `root = isqrt(R) <= 32768`, `rem = R - root^2 <= 65535`.
Safe.

### 1.2 Signed 8-bit and the `-128` case

| Item | Before | After |
|---|---|---|
| Magnitude | `wire [7:0] mag_peak = peak_reg[7] ? (8'd0 - peak_reg) : peak_reg;` | `wire signed [8:0] sample_extended = {sample_in[7], sample_in};` then `sample_magnitude = sample_extended < 0 ? -sample_extended : sample_extended;` |
| Tracking | none (peak only) | `abs_peak_reg` updated per sample |

**Old algorithm:** `peak_reg` holds the **maximum** (most positive) sample.
For an all-negative window, `peak_reg` is initialised to `-8'sd128` and never
updated, so `mag_peak` computed `8'd0 - 8'd128 = 8'd128` — this happened to
work, but for a window containing `-128` *and* a positive value, `mag_peak`
used the positive peak, not the true absolute maximum. `8'd0 - 8'd128` also
relies on the operand being treated as unsigned, so `-128` negated in 8 bits
stays `0x80` = 128 — representable, but only by accident of unsigned
arithmetic.

**New algorithm:** the magnitude is computed per sample from the sign-extended
9-bit value, so `abs(-128) = 128` exactly (9 bits are enough), and the true
maximum absolute value is tracked in `abs_peak_reg`.

**Result:** crest is now `max(|x|)` over the window instead of `|max(x)|`.
These differ whenever the most negative sample is larger in magnitude than
the most positive one — a common case for ECG. The G2.2 contract documents
this ("Absolute peak and crest").

**Risk:** `abs_peak_reg` is 8 bits and `sample_magnitude` is 9 bits; the
comparison is `sample_magnitude > {1'b0, abs_peak_reg}` (9-bit compare) and
the assignment takes `sample_magnitude[7:0]`. Since the true magnitude is at
most 128, the 8-bit truncation is lossless. Correct.

### 1.3 Absolute peak and crest

**Old:** `crest = sign(max(x)) * floor(|max(x)| * 65536 / R)`, i.e. crest was
**negative** whenever the window's maximum was negative.

**New:** `crest = floor(A * 65536 / R)` with `A = max|x| >= 0`, always
non-negative, stored signed16 with F=8.

**Old algorithm:** `f_crest = (abs(peak)*65536)//rms_fp` with a negative sign
applied when `peak < 0`.
**New algorithm:** `f_crest = min(32767, A*65536 // R)`, `R = 0 -> 0`.

The sign flip is a genuine semantic change (crest factor is by definition
non-negative) and is documented in `G2_2_DESIGN_CONTRACT.txt` and the golden
`formulas`.

**Saturation:** `div_quot > 28'd32767 ? 16'sd32767 : ...`. For legal windows
`A <= 128` and `R >= 256`, so `A*65536/R <= 32768`; the clamp is defensive.

**Rounding:** the 28-bit restoring divider computes `floor(A*65536/R)`.
Python golden: `absolute_peak*65536 // rms_fp`. Same. **Verdict: correct.**

**Risk:** none identified. The divider is reused for the RR ratio, unchanged.

### 1.4 Population variance, overflow and saturation

**Old:** `f_var <= $signed(var_num[33:18]);` — a bare bit slice.

**New:**

```verilog
if (var_num[63])       f_var <= 16'sd0;      // negative numerator: fault
else if (|var_num[62:33]) f_var <= 16'sd32767; // too large: saturate
else                   f_var <= $signed({1'b0, var_num[32:18]});
```

**Old algorithm:** `var_num = (sum_square << 9) - sum^2`, then bits `[33:18]`.
For legal windows `var_num <= 4261478400 < 2^32`, so bit 33 was always 0 and
the slice was exact — the old code was *not* numerically wrong for legal
input, but it silently truncated for illegal input and had no fault signal.

**New algorithm:** explicit three-way guard. The negative-numerator branch
**also sets the overflow flag** via `variance_invalid` in the separate
`overflow` always-block (`src/feature_extraction.v:429-438`). Cauchy-Schwarz
guarantees `var_num >= 0` for a genuine population variance, so a negative
numerator means the arithmetic is broken — the fault path is correct.

**Independent check:** `src/g22_reference.py` computes
`numerator = 512*energy - total*total`, asserts `0 <= numerator <= 4261478400`,
and returns `min(32767, numerator // 262144)`. The RTL's `>>18` equals
`// 262144`. Verified equal on all 7 ROM windows and on the directed vectors.

**Risk:** none for legal windows.

### 1.5 Reset, latency and window independence

- Hard reset (`!rst_n`) clears all accumulators including the new
  `abs_peak_reg`.
- Soft reset clears `abs_peak_reg`, `zc_cnt`, `prev_sign`, `have_nonzero` and
  the RR registers. **Note:** the soft-reset branch does *not* clear
  `peak_reg` / `min_reg`, but both are re-initialised at `start_compute`
  (`S_IDLE` branch, lines 210-211), so no stale value can escape. Verified.
- `start_compute` re-initialises `sum`, `sum_square`, `peak_reg`, `min_reg`,
  `abs_peak_reg`, `zc_cnt`, `pos_cnt`, `prev_sign`, `have_nonzero`, the
  sqrt state and the divider state. **Every window is therefore independent**
  — no carry-over between windows. Verified by the `windows` bench and by
  the golden's `assert all(new[k]==old[k] for k in [0,1,2,4,5,6,7])` in
  `src/g23_reference.py:84` (which asserts the seven non-G2.3 features are
  bit-identical to G2.2 on every window).

### 1.6 G2.2 verdict

**No bug found in the G2.2 arithmetic.** The patch fixes three genuine
semantic errors (fractional mean-square loss, absolute-peak handling of
`-128`, signed crest) and adds two defensive guards. The independent golden
`src/g22_reference.py` reproduces the RTL exactly on all exercised vectors.

---

## 2. G2.3 — `src/rr_tracker.v`, `src/window_buffer.v`, `src/top_ecg_rom_demo.v`, `src/feature_extraction.v`

### 2.1 Peak detection uses only accepted chronological samples — **VERIFIED**

`src/window_buffer.v` exports the preprocessed sample and the write strobe;
`rr_tracker` consumes `sample_accept` / `sample_in`. The tracker's index
`next_sample_index` increments **only** inside `if (sample_accept)`.
Verified independently: the `replay` bench asserts
`dut.u_rr.next_sample_index == writes` on every negedge, i.e. the tracker's
accepted-sample count equals the number of RAM writes. **PASS.**

Critically, the tracker is fed the **RAM write stream**, never the feature
module's RAM *read* stream, so the 256-sample overlap is never re-counted.
Verified by the `replay` bench: `consumed == 3584` (7 windows x 512 reads,
with overlaps) while the RR event timestamps are exactly
`231, 515, 809, 1045, 1403, 1706, 1998` — 7 distinct events on 2048
accepted samples, **no duplicates** from the overlap.

### 2.2 RR history is not reset at each window — **VERIFIED**

`rr_tracker` has its own reset (`rst_n`, `soft_reset`) and is **not**
reset by `start_compute`. `feature_extraction` only *reads* a snapshot.

The `replay` bench asserts the window-end snapshots are
`(0,0,invalid)`, `(284,0,valid/invalid)`, `(294,284,valid/valid)`,
`(236,294,...)`, `(358,236,...)`, `(303,358,...)`, `(292,303,...)` — i.e.
history genuinely accumulates across windows. **PASS.**

### 2.3 Overlapping windows do not double-count peaks — **VERIFIED**

Because the tracker runs on the accepted write stream (2048 samples, one
increment per write) while windows read 3584 samples, the overlap cannot
create or duplicate events. The `replay` bench asserts exactly 7 RR events
with the exact timestamps above and fails on any duplicate
(`default: $fatal(1,"duplicate RR event")`). **PASS.**

### 2.4 Refractory, timeout, signed threshold, timestamp

| Requirement | Implementation | Verdict |
|---|---|---|
| Refractory | `distance >= REFRACTORY_SAMPLES` (default 72) required to accept a candidate; a rejected candidate never moves `last_peak` | OK |
| Timeout | `expired = have_peak && next_sample_index != 0 && distance > MAX_RR_SAMPLES` (default 1800); on expiry history is cleared *before* the candidate is considered | OK |
| Signed threshold | `threshold_valid = threshold >= 16'sd1 && threshold <= 16'sd127`; comparison is `$signed(...) >= threshold` with an explicit 16-bit sign extension `{{8{previous_sample[7]}}, previous_sample}` | OK — negative bytes can no longer masquerade as positive peaks |
| Timestamp | `candidate_time = next_sample_index - 1` (uint64), `event_timestamp <= candidate_time`; monotonic, never wrapped | OK |
| Terminal peak | not flushed (a candidate needs a following sample) | OK — matches contract |
| Flat-top tie | `previous_sample > older_sample && previous_sample >= sample_in` — the **first** plateau sample wins | OK |
| 64-bit saturation | `&next_sample_index` -> halt, clear validity, latch `timestamp_overflow` | OK — fault-tested in `tb_g23_tracker` |

**Independent verification:** `src/g23_reference.py:36-42` enumerates
candidates in Python and filters by refractory, then derives the RR history
from the event timestamp list. It produces
`events=[231, 515, 809, 1045, 1403, 1706, 1998]` for the ROM — **identical**
to the RTL. The reference never simulates the RTL state machine.

### 2.5 Window-end RR snapshot

`src/top_ecg_rom_demo.v:91-101` registers `rr_current`/`rr_previous` and
their valid bits when `window_ready` is observed. The comment states the
tracker state already includes the final write's confirmation. Because
`window_ready` is registered by the final RAM write and the tracker updates
on the same edge, the snapshot includes the write at the window's last
sample. The `replay` bench asserts the exact snapshot values per window.
**PASS.**

### 2.6 RR validity and saturation

`feature_extraction` guards before narrowing/dividing:

```verilog
wire snapshot_current_ok = rr_snapshot_current_valid &&
    rr_snapshot_current != 0 && !rr_snapshot_current[15];
wire snapshot_pair_ok = snapshot_current_ok && rr_snapshot_previous_valid &&
    rr_snapshot_previous != 0 && !rr_snapshot_previous[15];
```

`f_rr` = current if `current_valid` else 0; `f_rr_prev` = previous only if the
*pair* is valid; `f_rr_ratio` = `min(32767, floor(current*4096/previous))`
only if the pair is valid, else 0; `f_rr_diff` = `current - previous` only if
the pair is valid, else 0. The zero denominator is structurally impossible
(the ratio division is guarded by `!rr_valid || rr_previous == 0`).
`rr_ratio_saturated` is a **separate** diagnostic that does **not** raise the
UART hardware error flags. **VERIFIED** against
`src/g23_reference.py:25-30` (`rr_fields`), which implements the same rules.

**Intervals are restricted to 1..32767**, so `current - previous` is within
`[-32766, 32766]` and cannot overflow signed16. Correct.

### 2.7 Zero crossing ignores zero per the contract — **VERIFIED**

```verilog
if ($signed(sample_in) != 0) begin
    if (have_nonzero && (prev_sign != ($signed(sample_in) < 0)))
        zc_cnt <= zc_cnt + 16'd1;
    prev_sign <= ($signed(sample_in) < 0);
    have_nonzero <= 1;
end
```

Zeros are skipped entirely and the sign history tracks the last **nonzero**
sample, which is exactly "delete zeros, then count adjacent opposite signs".
Independent golden `src/g23_reference.py:20-22` implements the same by
filtering zeros. The contract's worked examples hold:
`-1,0,0,+1 -> 1`, `+1,0,-1 -> 1`, `-1,0,-1 -> 0`.

The half-ratio convention (zero counts as non-negative) is **unchanged**:
`if (!sample_in[7]) pos_cnt <= pos_cnt + 1;` — `sample_in[7] == 0` means
`>= 0`. Correct and consistent with the frozen G2.1 contract.

### 2.8 The 7 non-G2.3 features were not changed — **VERIFIED**

`src/g23_reference.py:84` asserts, for every window:
`all(new[k] == old[k] for k in [0,1,2,4,5,6,7])` — RMS, var, peak, ptp,
crest, half_ratio, max are bit-identical to G2.2. This assertion runs inside
`make_golden`, so it is executed by `src/g23_reference.py --check` (re-run
here: **PASS**).

### 2.9 G2.3 verdict

**No bug found in the G2.3 patch.** All eight items required by the review
were checked directly in the RTL and confirmed by an independent Python
golden plus re-executed benches.

**Residual algorithmic limitations (documented, not defects):** the threshold
local-maximum detector is a heuristic, not a validated QRS detector, and
`MAX_RR_SAMPLES` is a technical stale-data limit, not a clinically validated
range. `G2_3_DESIGN_CONTRACT.txt` already states this.

---

## 3. Change table (G2.2 + G2.3)

| File | Line (after) | Old logic | New logic | Reason | Test evidence |
|---|---|---|---|---|---|
| `src/feature_extraction.v` | 94 | `wire [15:0] mean_sq = sum_square[24:9];` | `wire [31:0] rms_radicand = {1'b0, sum_square[23:0], 7'd0};` | keep fractional mean-square | `arithmetic`, `g21_vectors_g22_math`, `g2_checkpoint` |
| `src/feature_extraction.v` | 90-92 | `mag_peak` from `peak_reg` (unsigned 8-bit negate) | 9-bit sign-extended per-sample magnitude | correct `abs(-128)`, true abs peak | `arithmetic` (crest cases), `g2_checkpoint` |
| `src/feature_extraction.v` | 255-256 | (none) | `abs_peak_reg` tracking | absolute peak | `arithmetic` |
| `src/feature_extraction.v` | 371-372 | signed crest `sign(max(x))*...` | `min(32767, A*65536//R)`, non-negative | crest factor is non-negative | `arithmetic` |
| `src/feature_extraction.v` | 296-303 | `f_var <= var_num[33:18]` | 3-way guard (0 / 32767 / exact) | detect and flag illegal variance | `reset_faults` |
| `src/feature_extraction.v` | 259-264 | `prev_sign ^ sample_in[7]` (zero = positive) | skip zeros, track last nonzero sign | G2.3 ZC contract | `windows`, `g21_vectors_g22_math` |
| `src/feature_extraction.v` | 217-220, 288-290 | per-window RR counters | latch window-end snapshot | continuous RR history | `replay`, `windows` |
| `src/feature_extraction.v` | 379-417 | (none) | 28-bit divider for `f_rr_ratio`, clamped | RR ratio F=12 | `arithmetic`, `reset_faults` |
| `src/rr_tracker.v` | 1-84 | (new file) | continuous chronological peak/RR tracker | G2.3 core | `tracker`, `replay` |
| `src/window_buffer.v` | +7 | (none) | export `preprocessed_sample` / write strobe | feed tracker with accepted samples only | `replay` |
| `src/top_ecg_rom_demo.v` | 91-101, 149-153 | (none) | RR snapshot latch, `features_flat` | G2.3 integration | `replay` |

*(No G2.2/G2.3 RTL was changed by this audit — the review found no defect
requiring a fix. The G3 RTL changes are listed in `G3_FINAL_REPORT.md`.)*
