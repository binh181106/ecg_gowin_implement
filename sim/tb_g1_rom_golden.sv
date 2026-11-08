`timescale 1ns / 1ps
// =============================================================================
// G1/G2 testbench: ROM-driven, self-checking feature_extraction regression.
//
// Drives the DUT with the EXACT 7 windows the board demo produces from
// src/ecg_rom.hex (baseline-corrected, 512 samples, stride 256) and checks
// every feature against the values the independent Python golden computes.
//
// Checks the handoff G1 chain for f_rr_ratio:
//   window_id -> rr_previous -> f_rr_ratio@feature_valid
//             -> f_rr_ratio@the cycle feature_valid is sampled
//             -> (packetizer latch is a separate TB)
// and the G2 arithmetic: f_rms (true RMS), f_var (never negative),
// f_crest (Q7.8).
//
// Run:  vsim -c work_g1.tb_g1_rom_golden -do "run -all; quit -f"
// =============================================================================
module tb_g1_rom_golden;

    localparam CLK_HZ    = 50_000_000;
    localparam TARGET_HZ = 360;
    localparam N_WINDOW  = 7;
    localparam WINDOW    = 512;
    localparam STRIDE    = 256;
    localparam BASELINE  = 169;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg soft_reset = 1'b0;
    reg start_compute = 1'b0;
    reg [15:0] ecg_threshold = 16'd80;

    wire [8:0] sample_addr;
    wire read_en;
    reg  [7:0] sample_in = 8'd0;

    // Pre-loaded window memory (baseline-corrected), fed synchronously.
    reg [7:0] memory [0:WINDOW-1];

    wire signed [15:0] f_rms;
    wire signed [15:0] f_var;
    wire signed [15:0] f_peak;
    wire signed [15:0] f_zc;
    wire signed [15:0] f_ptp;
    wire signed [15:0] f_crest;
    wire signed [15:0] f_half_ratio;
    wire signed [15:0] f_max;
    wire signed [15:0] f_rr;
    wire signed [15:0] f_rr_prev;
    wire signed [15:0] f_rr_ratio;
    wire signed [15:0] f_rr_diff;

    wire feature_valid;
    wire overflow;

    integer checks = 0;
    integer errors = 0;
    integer win_id = 0;
    integer cycles;
    integer i;

    // ---- expected values (independent Python golden, G2 formulas) -------
    //        rms  var  peak  zc  ptp  crest  half  max  rr  rrprev ratio rrdiff
    integer exp_rms   [0:N_WINDOW-1];
    integer exp_var   [0:N_WINDOW-1];
    integer exp_peak  [0:N_WINDOW-1];
    integer exp_zc    [0:N_WINDOW-1];
    integer exp_ptp   [0:N_WINDOW-1];
    integer exp_crest [0:N_WINDOW-1];
    integer exp_half  [0:N_WINDOW-1];
    integer exp_max   [0:N_WINDOW-1];
    integer exp_rr    [0:N_WINDOW-1];
    integer exp_rprev [0:N_WINDOW-1];
    integer exp_ratio [0:N_WINDOW-1];
    integer exp_rrd   [0:N_WINDOW-1];

    feature_extraction #(
        .DATA_IN_WIDTH(8),
        .DATA_OUT_WIDTH(16),
        .NUM_SAMPLES(WINDOW)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .soft_reset(soft_reset),
        .start_compute(start_compute),
        .ecg_threshold(ecg_threshold),
        .read_enable(1'b0),
        .sample_addr(sample_addr),
        .sample_in(sample_in),
        .read_en(read_en),
        .f_rms(f_rms), .f_var(f_var), .f_peak(f_peak), .f_zc(f_zc),
        .f_ptp(f_ptp), .f_crest(f_crest), .f_half_ratio(f_half_ratio),
        .f_max(f_max), .f_rr(f_rr), .f_rr_prev(f_rr_prev),
        .f_rr_ratio(f_rr_ratio), .f_rr_diff(f_rr_diff),
        .feature_valid(feature_valid),
        .overflow(overflow)
    );

    // Synchronous RAM model: data valid one cycle after read_en.
    always @(posedge clk) begin
        if (read_en)
            sample_in <= memory[sample_addr];
    end

    task automatic check_value(
        input string label,
        input logic signed [63:0] actual,
        input logic signed [63:0] expected
    );
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL win=%0d %s actual=%0d expected=%0d",
                         win_id, label, actual, expected);
            end
        end
    endtask

    // ---- ROM byte stream (read once, before any window runs) -----------
    reg [7:0] rom [0:2047];
    integer fh;
    integer r;

    task automatic load_rom;
        begin
            fh = $fopen("src/ecg_rom.hex", "r");
            if (fh == 0)
                $fatal(1, "cannot open src/ecg_rom.hex");
            for (i = 0; i < 2048; i = i + 1) begin
                r = $fscanf(fh, "%h", rom[i]);
                if (r != 1) $fatal(1, "ROM read failed at %0d", i);
            end
            $fclose(fh);
        end
    endtask

    task automatic run_window;
        begin
            @(negedge clk);
            start_compute = 1'b1;
            @(negedge clk);
            start_compute = 1'b0;

            cycles = 0;
            while ((feature_valid !== 1'b1) && (cycles < 4000)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (feature_valid !== 1'b1)
                $fatal(1, "TIMEOUT win=%0d state=%0d cycles=%0d",
                       win_id, dut.state, cycles);
        end
    endtask

    initial begin
        load_rom();

        // ---------------- expected values (G2 golden) ------------------
        exp_rms[0]=4;   exp_var[0]=19;  exp_peak[0]=65; exp_zc[0]=0;
        exp_ptp[0]=65;  exp_crest[0]=4160; exp_half[0]=4096; exp_max[0]=65;
        exp_rr[0]=0;    exp_rprev[0]=0; exp_ratio[0]=4096; exp_rrd[0]=0;

        exp_rms[1]=5;   exp_var[1]=27;  exp_peak[1]=76; exp_zc[1]=0;
        exp_ptp[1]=76;  exp_crest[1]=3891; exp_half[1]=4096; exp_max[1]=76;
        exp_rr[1]=0;    exp_rprev[1]=0; exp_ratio[1]=4096; exp_rrd[1]=0;

        exp_rms[2]=8;   exp_var[2]=69;  exp_peak[2]=86; exp_zc[2]=0;
        exp_ptp[2]=86;  exp_crest[2]=2752; exp_half[2]=4096; exp_max[2]=86;
        exp_rr[2]=299;  exp_rprev[2]=0; exp_ratio[2]=4096; exp_rrd[2]=299;

        exp_rms[3]=8;   exp_var[3]=72;  exp_peak[3]=86; exp_zc[3]=0;
        exp_ptp[3]=86;  exp_crest[3]=2752; exp_half[3]=4096; exp_max[3]=86;
        exp_rr[3]=43;   exp_rprev[3]=0; exp_ratio[3]=4096; exp_rrd[3]=43;

        exp_rms[4]=7;   exp_var[4]=62;  exp_peak[4]=76; exp_zc[4]=0;
        exp_ptp[4]=76;  exp_crest[4]=2779; exp_half[4]=4096; exp_max[4]=76;
        exp_rr[4]=0;    exp_rprev[4]=0; exp_ratio[4]=4096; exp_rrd[4]=0;

        exp_rms[5]=8;   exp_var[5]=63;  exp_peak[5]=77; exp_zc[5]=0;
        exp_ptp[5]=77;  exp_crest[5]=2464; exp_half[5]=4096; exp_max[5]=77;
        exp_rr[5]=0;    exp_rprev[5]=0; exp_ratio[5]=4096; exp_rrd[5]=0;

        exp_rms[6]=8;   exp_var[6]=65;  exp_peak[6]=83; exp_zc[6]=0;
        exp_ptp[6]=83;  exp_crest[6]=2656; exp_half[6]=4096; exp_max[6]=83;
        exp_rr[6]=463;  exp_rprev[6]=0; exp_ratio[6]=4096; exp_rrd[6]=463;

        $display("G1/G2 ROM GOLDEN: 7 windows, G2 arithmetic (RMS/var/crest)");
        $display("  chain: window -> rr_previous -> f_rr_ratio@feature_valid");

        // ---- reset ----
        @(negedge clk);
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (win_id = 1; win_id <= N_WINDOW; win_id = win_id + 1) begin
            // Baseline-correct the ROM segment for this window.
            for (i = 0; i < WINDOW; i = i + 1) begin
                if (rom[(win_id - 1) * STRIDE + i] >= BASELINE)
                    memory[i] = rom[(win_id - 1) * STRIDE + i] - BASELINE;
                else
                    memory[i] = 8'd0;
            end

            run_window();

            check_value("f_rms",       f_rms,       exp_rms[win_id-1]);
            check_value("f_var",       f_var,       exp_var[win_id-1]);
            check_value("f_peak",      f_peak,      exp_peak[win_id-1]);
            check_value("f_zc",        f_zc,        exp_zc[win_id-1]);
            check_value("f_ptp",       f_ptp,       exp_ptp[win_id-1]);
            check_value("f_crest",     f_crest,     exp_crest[win_id-1]);
            check_value("f_half_ratio",f_half_ratio,exp_half[win_id-1]);
            check_value("f_max",       f_max,       exp_max[win_id-1]);
            check_value("f_rr",        f_rr,        exp_rr[win_id-1]);
            check_value("f_rr_prev",   f_rr_prev,   exp_rprev[win_id-1]);
            check_value("f_rr_ratio",  f_rr_ratio,  exp_ratio[win_id-1]);
            check_value("f_rr_diff",   f_rr_diff,   exp_rrd[win_id-1]);
            check_value("overflow",    {63'd0, overflow}, 0);

            // G1 evidence line: what the board must see on the UART.
            $display("G1 win=%0d rr_previous=%0d f_rr_ratio@feature_valid=%0d (0x%04x)",
                     win_id, dut.rr_previous, f_rr_ratio, f_rr_ratio);
        end

        // ---- variance must never be negative (G2) ----
        for (i = 0; i < N_WINDOW; i = i + 1) begin
            if (exp_var[i] < 0) begin
                errors = errors + 1;
                $display("FAIL golden var negative at win=%0d", i + 1);
            end
        end

        if (errors != 0)
            $fatal(1, "G1/G2 CHECK FAIL checks=%0d errors=%0d", checks, errors);

        $display("G1/G2 CHECK PASS checks=%0d errors=%0d", checks, errors);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "GLOBAL TIMEOUT");
    end

endmodule
