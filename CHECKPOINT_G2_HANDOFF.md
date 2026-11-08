# CHECKPOINT G2 HANDOFF — ECG Feature Extraction (RMS / variance / peak / max / PTP / crest)

> **Ngày:** 08/11/2026 · **Mục tiêu:** Chốt định dạng số học G2 (P0, §7.3 của
> handoff gốc), bảo đảm `golden_model.py` / `expected JSON+SV` / decoder / tài
> liệu thống nhất với RTL. Chưa mở rộng sang half-ratio/ZC/RR/preprocessing/
> weight-model thật. **Frame UART 33 byte + baseline legacy 169 giữ nguyên.**
> **Tự động kiểm chứng bằng Questa (Questa 10.7c) + Python, không cần người chạy.**

---

## 1. Đã sửa gì (danh sách file)

| File | Thay đổi | Trạng thái |
|---|---|---|
| `src/feature_extraction.v` | RMS đổi sang **Q8.8 nội bộ**; crest chia cho giá trị đó (không phải RMS integer đã làm tròn); var ≥0; register sqrt nâng 32→16; state machine mới | ✅ |
| `src/golden_model.py` | Công thức G2 (RMS Q8.8, var ≥0, crest / rms_fp); regen JSON+SV | ✅ |
| `src/golden/expected_packets.json` | 7 window regen (crest mới: 3820/3678/2612/2577/2452/2464/2616) | ✅ |
| `src/golden/expected_packets.sv` | TB include, regen cùng JSON | ✅ |
| `sim/tb_g1_rom_golden.sv` | Cập nhật expected crest G2 + chạy lại (7 window, ROM-driven) | ✅ |
| `sim/tb_feature_checkpoint.sv` | Viết lại table-driven, 10 case góc (đặc biệt RMS không nguyên, mẫu âm/-128, 2 cửa sổ liên tiếp, reset-giữa-lúc-tính) | ✅ |
| `sim/gen_g2_expect.py` | **Reference độc lập** (mirror `golden_model.py`), sinh expected cho mọi case SV | ✅ |
| `sim/g2_vlog.log`, `sim/g2_rom_golden.log`, `sim/g2_checkpoint.log` | Log compile + chạy (mới) | ✅ |

File không đổi: `src/uart_decode.py` (đã đọc JSON, không hard-code công thức —
self-test PASS không cần sửa), `src/ecg_rom.hex` (input), `src/top_ecg_rom_demo.v`
(vẫn `.f10(f_rr_ratio)` — không phải diagnostic).

---

## 2. Đặc tả định dạng số cuối cùng (G2)

| Field | Định nghĩa | Công thức |
|---|---|---|
| **f_rms** | Phần **nguyên** của RMS thật | `rms_fp = isqrt(mean_sq << 16)` (Q8.8, 32-bit radicand, 16 lặp restoring sqrt); **`f_rms = rms_fp >> 8`** |
| **f_crest** | Crest factor (tỉ lệ peak/rms) Q8.0 | **`f_crest = sign(peak) · floor(\|peak\| · 2^16 / rms_fp)`** — chia cho `rms_fp` (Q8.8 **nội bộ**, chưa làm tròn), **không** chia cho `f_rms`. `rms_fp == 0 → 0`. int16-safe (max 127·256 = 32512) |
| **f_var** | Phương sai mẫu (population) | `(512·sum_sq − sum²) >> 18` — luôn **≥ 0** (Cauchy-Schwarz), max 16256, vừa int16 |
| **f_peak / f_max** | Giá trị đỉnh (signed) | `peak_reg` |
| **f_ptp** | Peak-to-peak | `peak − min` (unsigned magnitude) |
| **f_rr_ratio** | Chưa đổi (RR nằm ngoài phạm vi G2) | `rr_prev == 0 → 4096`; khác thì `(rr_cur·4096)//rr_prev` (bộ chia 28-bit) |

**Điểm mấu chốt (thanh toán):** crest **không** chia cho RMS output đã làm tròn
số nguyên (`f_rms`). Thay vào đó dùng `rms_fp` (Q8.8, 8 bit fraction) để giữ
độ chính xác nội bộ. Khi `f_rms` sai do làm tròn (vd mean_sq=19 → rms_fp=1115
≈ 4.36, f_rms=4), crest Q8.8 chia cho 1115 **trúng** giá trị chính xác hơn
khi chia cho 4·256=1024. Đây là "độ chính xác nội bộ đã đặc tả" theo yêu cầu.

---

## 3. Test thực sự đã chạy (Questa 10.7c, lib `sim/work_g2`)

**Compile:**
```
vlib sim/work_g2
vlog -sv -work sim/work_g2 src/feature_extraction.v sim/tb_g1_rom_golden.sv sim/tb_feature_checkpoint.sv -l sim/g2_vlog.log
```
→ `Errors: 0, Warnings: 0` (`sim/g2_vlog.log`).

**Chạy (mỗi lần có timeout, log + exit code):**
```
vsim -c -l sim/g2_rom_golden.log  sim/work_g2.tb_g1_rom_golden    -do "onerror {quit -code 1 -f}; run -all; quit -code 0 -f"
vsim -c -l sim/g2_checkpoint.log  sim/work_g2.tb_feature_checkpoint -do "onerror {quit -code 1 -f}; run -all; quit -code 0 -f"
```

| Test | Kết quả | Log | Đường dẫn |
|---|---|---|---|
| `tb_g1_rom_golden` (7 window ROM) | **PASS** 91 checks, 0 errors, exit 0 | `sim/g2_rom_golden.log` | ✅ |
| `tb_feature_checkpoint` (10 case góc) | **PASS** 131 checks, 0 errors, exit 0 | `sim/g2_checkpoint.log` | ✅ |
| `golden_model.py` regen | 7 window, crest khớp, **PASS** | (stdout) | ✅ |
| `uart_decode.py` self-test | decode 7 golden PASS, corrupt reject PASS, resync PASS | (stdout) | ✅ |

**Case góc đã xác nhận qua sim:**
- `neg128` (-128/+127): var=16256 (trần), crest=**255** (chia cho rms_fp nội bộ 32639) — **khác** nếu dùng integer RMS (sẽ cho 256). Chứng minh crest dùng rms_fp, không dùng f_rms.
- `nonint` (300×(+3), 212×(−3)): mean_sq=9, rms_fp=768 (Q8.8 fraction = 0.75·… → không phải số nguyên) — crest=256.
- `neg3` (toàn −3): crest=**−256** (dấu theo `peak_reg`), var=0.
- `x10→x20` không reset: chứng minh `sum`/`sum_square` được **xóa giữa 2 window** (f_rms=10 rồi f_rms=20, var=0).
- `reset-mid` (case 9): `soft_reset` giữa lúc tính → DUT về `S_IDLE`, chạy lại sạch, f_rms=10 đúng.
- `rr` (3 xung @10/30/60): rr_cur=29, rr_prev=19, ratio=6251 (không phải guard 4096).

**Giá trị crest G2 trên ROM (7 window, từ golden + testbench):**
```
w1..w7 crest = 3820 3678 2612 2577 2452 2464 2616
w1..w7 f_rms  =   4    5    8    8    7    8    8
w1..w7 f_var  =  19   27   69   72   62   63   65   (đều ≥ 0)
```

---

## 4. Việc còn thiếu, blocker, lệnh tiếp tục

**Đã đủ trong phạm vi G2 được giao** (RMS/var/peak/max/PTP/crest thống nhất
RTL↔golden↔decoder↔TB). **Không có blocker** cho các mục trên.

**Điểm chưa làm (ngoài phạm vi, ghi để biết):**
- **Test tích hợp ROM → feature → packetizer → UART chưa có testbench.**
  Repo không có TB chạy cả con đường `top_ecg_rom_demo` (packetizer + uart_tx).
  Chỉ có 2 TB cô lập ở cấp module `feature_extraction`. Frame 33 byte được
  **xác nhận bằng decoder Python** (231 byte = 7×33, checksum scope bytes[2..31],
  strict_mask toàn 1), không phải bằng TB SystemVerilog.
  → **Lệnh tiếp tục (nếu muốn TB tích hợp, tự động):**
  ```
  vsim -c -l sim/g2_top.log \
    sim/work_g2.tb_ecg_rom_demo -do "onerror {quit -code 1 -f}; run -all; quit -code 0 -f"
  ```
  (phải tạo `sim/tb_ecg_rom_demo.sv` instantiate `top_ecg_rom_demo` + UART monitor; chưa tồn tại.)
- **G3 (board + P&R):** chưa chạy (đúng chỉ thị "không tự chạy synthesis/P&R,
  Programmer, board"). `.fs` hiện tại (rev `483e045`) **chưa** chứa RTL G2.
  Capture cũ (nếu có) **sai lệch** với golden mới (crest đổi từ G1 → G2) →
  capture phải nạp lại bitstream G2 rồi thu mới.

**Lệnh xác minh lại toàn bộ (self-contained, không cần board):**
```
cd "h:\IC Design\Code\Gowin_Work\ecg_gowin_implement"
python -I src/golden_model.py        # regen JSON+SV (idempotent)
python -I src/uart_decode.py         # decoder self-test
H:\questasim64_10.7c\win64\vlib  sim/work_g2
H:\questasim64_10.7c\win64\vlog -sv -work sim/work_g2 src/feature_extraction.v sim/tb_g1_rom_golden.sv sim/tb_feature_checkpoint.sv
H:\questasim64_10.7c\win64\vsim -c sim/work_g2.tb_g1_rom_golden    -do "run -all; quit -f"
H:\questasim64_10.7c\win64\vsim -c sim/work_g2.tb_feature_checkpoint -do "run -all; quit -f"
```

---

## 5. Điểm chưa kiểm chứng trên Gowin / hardware

| Hạng mục | Trạng thái | Lý do |
|---|---|---|
| **Timing STA (WNS/TNS/Fmax)** cho RTL G2 mới | **CHƯA CHẠY** | Chỉ thị cấm tự chạy synthesis/P&R; sqrt 32-bit (16 lặp) + bộ chia có thể làm chậm path → cần Gowin P&R lại để xem Fmax 50 MHz còn đạt không |
| **Resource (FF/LUT)** tăng do sqrt 16-bit + Q8.8 | **CHƯA ĐO** | `sq_rem`/`sq_root` 16-bit, `sq_cnt` 5-bit thay 4-bit — cần P&R report |
| **Nạp `.fs` G2 + capture UART thật** | **CHƯA CHẠY** | G3; cần board + Programmer; capture mới phải khớp golden G2 (7 packet, 231 byte, 0 strict mismatch, crest byte[16:17] = 3820/3678/…) |
| **Dấu crest âm trên board** | **CHƯA** | Case `neg3` (crest −256) chỉ có trong TB cô lập; ECG ROM (baseline-corrected, min=0) **không** có mẫu âm nên board demo luôn crest ≥ 0 |
| **overflow flag** | OK trong sim | `overflow = sum_square[63:62]!=0`; ECG baseline-corrected (min=0) không bao giờ kích hoạt → flags=0 luôn hợp lệ, đúng như capture cũ |

**Rủi ro cần review trước G3:** sqrt từ 8→16 bit có thể kéo dài critical
path (16 chu kỳ tính + so sánh 18-bit). Cần Gowin P&R report WNS ≥ 0 trước khi
coi là đạt G3.
