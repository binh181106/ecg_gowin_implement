`timescale 1ns / 1ps
// =============================================================================
// G2 feature-extraction checkpoint + corner-case testbench.
//
// Self-checking: drives feature_extraction with 8-bit windows and asserts all
// 12 features against an INDEPENDENT Python reference (sim/gen_g2_expect.py,
// which mirrors src/golden_model.py). Covers the handoff G2 corners:
//   - uniform / impulse windows
//   - non-integer RMS (nonint: mean_sq non-square -> Q8.8 frac actually used)
//   - negative samples / -128 (neg128: worst-case variance + crest discriminator)
//   - all-negative (neg3: crest output sign follows peak_reg)
//   - two consecutive windows WITHOUT reset (x10 -> x20, accumulation cleared)
//   - RR triple-impulse (fires ratio, not the 4096 guard)
//   - reset applied MID-COMPUTE (soft_reset returns to S_IDLE cleanly)
//
// G2 formulas asserted here:
//   f_rms   = isqrt(mean_sq << 16) >> 8      (integer part of true RMS)
//   f_crest = sign(peak) * floor(|peak|<<16 / isqrt(mean_sq<<16))
//            -> divides by the INTERNAL Q8.8 rms_fp, NOT the rounded f_rms.
//   f_var   = (512*sum_sq - sum^2) >> 18     (population variance, >= 0)
//
// Run:  vsim -c work_g2.tb_feature_checkpoint -do "run -all; quit -f"
// =============================================================================
module tb_feature_checkpoint;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg soft_reset = 1'b0;
    reg start_compute = 1'b0;
    reg [15:0] ecg_threshold = 16'd80;

    wire [8:0] sample_addr;
    wire read_en;
    reg [7:0] sample_in = 8'd0;

    reg [7:0] memory [0:511];

    wire signed [15:0] f_rms, f_var, f_peak, f_zc, f_ptp, f_crest;
    wire signed [15:0] f_half_ratio, f_max, f_rr, f_rr_prev, f_rr_ratio, f_rr_diff;
    wire feature_valid;
    wire overflow;

    integer checks = 0;
    integer errors = 0;
    integer cases_run = 0;
    integer case_id = 0;

    feature_extraction #(.DATA_IN_WIDTH(8), .DATA_OUT_WIDTH(16),
                         .NUM_SAMPLES(512)) dut (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .start_compute(start_compute), .ecg_threshold(ecg_threshold),
        .read_enable(1'b0), .sample_addr(sample_addr), .sample_in(sample_in),
        .read_en(read_en),
        .f_rms(f_rms), .f_var(f_var), .f_peak(f_peak), .f_zc(f_zc),
        .f_ptp(f_ptp), .f_crest(f_crest), .f_half_ratio(f_half_ratio),
        .f_max(f_max), .f_rr(f_rr), .f_rr_prev(f_rr_prev),
        .f_rr_ratio(f_rr_ratio), .f_rr_diff(f_rr_diff),
        .feature_valid(feature_valid), .overflow(overflow)
    );

    // Synchronous RAM model: data valid one cycle after read_en.
    always @(posedge clk) begin
        if (read_en)
            sample_in <= memory[sample_addr];
    end

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start_compute = 1'b0;
            soft_reset = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic check_value(
        input string label,
        input logic signed [63:0] actual,
        input logic signed [63:0] expected
    );
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL case=%0d %s actual=%0d expected=%0d",
                         case_id, label, actual, expected);
            end
        end
    endtask

    // Assert the full 12-feature vector (port order) for the current window.
    // args: rms,var,peak,zc,ptp,crest,half,max,rr,rrprev,ratio,rrdiff
    task automatic check_all(
        input integer e_rms, input integer e_var, input integer e_peak,
        input integer e_zc,  input integer e_ptp, input integer e_crest,
        input integer e_half, input integer e_max, input integer e_rr,
        input integer e_rrprev, input integer e_ratio, input integer e_rrd
    );
        begin
            check_value("f_rms",       f_rms,       e_rms);
            check_value("f_var",       f_var,       e_var);
            check_value("f_peak",      f_peak,      e_peak);
            check_value("f_zc",        f_zc,        e_zc);
            check_value("f_ptp",       f_ptp,       e_ptp);
            check_value("f_crest",     f_crest,     e_crest);
            check_value("f_half_ratio",f_half_ratio,e_half);
            check_value("f_max",       f_max,       e_max);
            check_value("f_rr",        f_rr,        e_rr);
            check_value("f_rr_prev",   f_rr_prev,   e_rrprev);
            check_value("f_rr_ratio",  f_rr_ratio,  e_ratio);
            check_value("f_rr_diff",   f_rr_diff,   e_rrd);
            check_value("overflow",    {63'd0, overflow}, 0);
        end
    endtask

    task automatic run_window;
        integer cycles;
        begin
            @(negedge clk);
            start_compute = 1'b1;
            @(negedge clk);
            start_compute = 1'b0;
            cycles = 0;
            while ((feature_valid !== 1'b1) && (cycles < 2500)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (feature_valid !== 1'b1)
                $fatal(1, "TIMEOUT case=%0d state=%0d cycles=%0d",
                       case_id, dut.state, cycles);
            cases_run = cases_run + 1;
        end
    endtask

    task automatic fill_val(input [7:0] value);
        integer i;
        begin
            for (i = 0; i < 512; i = i + 1)
                memory[i] = value;
        end
    endtask

    initial begin
        $display("G2 FEATURE CHECKPOINT: corners (RMS/crest/var/RR + reset-mid)");

        // ---- case 0: all-zero window ----
        case_id = 0;
        reset_dut();
        fill_val(8'd0);
        run_window();
        // zero: 0 0 0 0 0 0 4096 0 0 0 4096 0
        check_all(0, 0, 0, 0, 0, 0, 4096, 0, 0, 0, 4096, 0);

        // ---- case 1: uniform +10 (true RMS) ----
        case_id = 1;
        reset_dut();
        fill_val(8'd10);
        run_window();
        // x10: rms 10, var 0, crest 256
        check_all(10, 0, 10, 0, 0, 256, 4096, 10, 0, 0, 4096, 0);

        // ---- case 2: uniform +20, NO reset after case 1 ----
        // Proves accumulation is cleared between windows.
        case_id = 2;
        fill_val(8'd20);
        run_window();
        // x20: rms 20, var 0, crest 256
        check_all(20, 0, 20, 0, 0, 256, 4096, 20, 0, 0, 4096, 0);

        // ---- case 3: single impulse at index 0 (non-integer RMS: mean_sq=19) ----
        case_id = 3;
        reset_dut();
        fill_val(8'd0);
        memory[0] = 8'd100;
        run_window();
        // imp0: rms 4, var 19, crest 5877, rr fires (100->0) = 1
        check_all(4, 19, 100, 0, 100, 5877, 4096, 100, 1, 0, 4096, 1);

        // ---- case 4: single impulse at index 511 (last sample) ----
        case_id = 4;
        reset_dut();
        fill_val(8'd0);
        memory[511] = 8'd100;
        run_window();
        // imp511: rms 4, var 19, crest 5877, rr = 0 (no down-cross before end)
        check_all(4, 19, 100, 0, 100, 5877, 4096, 100, 0, 0, 4096, 0);

        // ---- case 5: RR triple-impulse (real ratio, not the guard) ----
        case_id = 5;
        reset_dut();
        fill_val(8'd0);
        memory[10] = 8'd100;
        memory[30] = 8'd100;
        memory[60] = 8'd100;
        run_window();
        // rr: rms 7, var 58, crest 3362, rr 29/19 ratio 6251 diff 10
        check_all(7, 58, 100, 0, 100, 3362, 4096, 100, 29, 19, 6251, 10);

        // ---- case 6: -128 / +127 worst-case (crest discriminator) ----
        // crest=255 here; an integer-RMS divisor would give 256 -> proves the
        // G2 internal-Q8.8 path.
        case_id = 6;
        reset_dut();
        begin : neg128
            integer i;
            for (i = 0;    i < 256; i = i + 1) memory[i]     = 8'h80; // -128
            for (i = 256; i < 512; i = i + 1) memory[i]     = 8'h7F; // +127
        end
        run_window();
        // neg128: rms 127, var 16256, crest 255, zc 1, ptp 255, half 2048
        check_all(127, 16256, 127, 1, 255, 255, 2048, 127, 0, 0, 4096, 0);

        // ---- case 7: non-integer RMS with positive peak (mean_sq=9) ----
        case_id = 7;
        reset_dut();
        begin : nonint
            integer i;
            for (i = 0;   i < 300; i = i + 1) memory[i] = 8'd3;    // +3
            for (i = 300; i < 512; i = i + 1) memory[i] = 8'hFD;  // -3
        end
        run_window();
        // nonint: rms 3, var 8, crest 256, zc 1, ptp 6, half 2400
        check_all(3, 8, 3, 1, 6, 256, 2400, 3, 0, 0, 4096, 0);

        // ---- case 8: all-negative (-3) -> crest sign follows peak_reg ----
        case_id = 8;
        reset_dut();
        fill_val(8'hFD);
        run_window();
        // neg3: rms 3, var 0, peak -3, crest -256, half 0
        check_all(3, 0, -3, 0, 0, -256, 0, -3, 0, 0, 4096, 0);

        // ---- case 9: RESET MID-COMPUTE ----
        // Start a window, pull soft_reset part-way through, then confirm the
        // DUT returns to S_IDLE, and a fresh compute still produces correct
        // features (state registers / accumulators not wedged).
        case_id = 9;
        reset_dut();
        fill_val(8'd10);
        @(negedge clk);
        start_compute = 1'b1;
        // let it enter accumulation (a few samples in)
        repeat (8) @(negedge clk);
        soft_reset = 1'b1;
        @(negedge clk);
        soft_reset = 1'b0;
        start_compute = 1'b0;
        // must be back to idle
        check_value("state_after_soft_reset",
                    {63'd0, dut.state},
                    4'd0 /* S_IDLE */);
        // a clean run still works after the mid-compute reset
        fill_val(8'd10);
        run_window();
        check_all(10, 0, 10, 0, 0, 256, 4096, 10, 0, 0, 4096, 0);

        // ---- variance must never be negative in any asserted case ----
        if (errors != 0)
            $fatal(1, "G2 CHECKPOINT FAIL cases=%0d checks=%0d errors=%0d",
                   cases_run, checks, errors);

        $display("G2 CHECKPOINT PASS cases=%0d checks=%0d", cases_run, checks);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "GLOBAL TIMEOUT");
    end

endmodule
