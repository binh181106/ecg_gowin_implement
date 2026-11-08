`timescale 1ns / 1ps

module feature_extraction #(
    parameter DATA_IN_WIDTH  = 8,
    parameter DATA_OUT_WIDTH = 16,
    parameter NUM_SAMPLES    = 512
) (
    input  wire clk,
    input  wire rst_n,
    input  wire soft_reset,

    input  wire start_compute,
    input  wire [15:0] ecg_threshold,

    input  wire read_enable,
    output reg  [8:0] sample_addr,
    input  wire [DATA_IN_WIDTH-1:0] sample_in,
    output reg  read_en,

    output reg signed [DATA_OUT_WIDTH-1:0] f_rms,
    output reg signed [DATA_OUT_WIDTH-1:0] f_var,
    output reg signed [DATA_OUT_WIDTH-1:0] f_peak,
    output reg signed [DATA_OUT_WIDTH-1:0] f_zc,
    output reg signed [DATA_OUT_WIDTH-1:0] f_ptp,
    output reg signed [DATA_OUT_WIDTH-1:0] f_crest,
    output reg signed [DATA_OUT_WIDTH-1:0] f_half_ratio,
    output reg signed [DATA_OUT_WIDTH-1:0] f_max,
    output reg signed [DATA_OUT_WIDTH-1:0] f_rr,
    output reg signed [DATA_OUT_WIDTH-1:0] f_rr_prev,
    output reg signed [DATA_OUT_WIDTH-1:0] f_rr_ratio,
    output reg signed [DATA_OUT_WIDTH-1:0] f_rr_diff,

    output reg feature_valid,
    output reg overflow
);

    localparam S_IDLE            = 4'd0;
    localparam S_ACCUMULATE_ADDR = 4'd1;
    localparam S_ACCUMULATE_READ = 4'd2;
    localparam S_CALC_BASE       = 4'd3;
    localparam S_CALC_VAR        = 4'd4;
    localparam S_CALC_RMS        = 4'd5;
    localparam S_CALC_CREST      = 4'd6;
    localparam S_DONE            = 4'd7;
    localparam S_DIV_CREST       = 4'd8;
    localparam S_DIV_RR          = 4'd9;
    localparam S_ACCUMULATE_WAIT = 4'd10;
    localparam S_CALC_SQRT       = 4'd11;
    localparam DIV_BITS          = 28;

    reg [3:0] state;
    reg [9:0] sample_cnt;

    reg signed [31:0] sum;
    reg signed [63:0] sum_square;
    reg signed [7:0] peak_reg;
    reg signed [7:0] min_reg;

    reg [15:0] zc_cnt;
    reg prev_sign;
    reg [15:0] pos_cnt;

    reg [15:0] rr_timer;
    reg [15:0] rr_current;
    reg [15:0] rr_previous;
    reg [7:0] sample_delayed;

    reg [31:0] sq_in;       // sqrt radicand = mean_square << 16 (32-bit)
    reg [15:0] sq_rem;      // sqrt remainder (< 4*root+3, 16 bits for 16-bit root)
    reg [15:0] sq_root;      // sqrt result Q8.8 (0..32768), internal RMS
    reg [4:0]  sq_cnt;       // sqrt iteration count (2 bits/iter, 16 iters)
    reg [15:0] rms_reg;      // = sq_root, the internal Q8.8 RMS used as crest divisor

    reg [27:0] div_dividend;
    reg [27:0] div_quot;
    reg [15:0] div_divisor;
    reg [16:0] div_rem;
    reg [5:0] div_cnt;

    wire [7:0] mag_peak =
        peak_reg[7] ? (8'd0 - peak_reg) : peak_reg;

    // mean_square = sum_square / 512 (512 samples).
    // Bound: sum_square <= 512 * 128^2 = 8,388,608 -> mean_sq <= 16384.
    wire [15:0] mean_sq = sum_square[24:9];

    // f_var (G2): population variance, always >= 0 by Cauchy-Schwarz
    // ((512*sum_sq) >= sum^2).  var = (512*sum_sq - sum^2) / 512^2
    //        = (sum_sq*512 - sum^2) >> 18 (floor).
    // Max for x in [-128..127], N=512: 16256 (fits signed 16-bit).
    // NOTE: sum*sum must be computed in 64-bit -- in 32-bit it overflows
    // (|sum| <= 65536 -> sum^2 up to 2^32).
    wire signed [63:0] sum_sq64 = $signed({{32{sum[31]}}, sum});
    wire signed [63:0] var_num =
        ($signed(sum_square) <<< 9) - (sum_sq64 * sum_sq64);

    // Digit-by-step square root (restoring), 2 radicand bits per cycle.
    // Operates on a 32-bit radicand (sq_in = mean_square << 16) -> 16-bit
    // root in Q8.8. 16 iterations; each feeds the next 2 bits of sq_in.
    // Invariant: sq_root = floor(sqrt(prefix));  candidate remainder
    // (sq_rem*4 | top2) vs trial (sq_root*4 | 1). Verifies isqrt() exactly.
    wire [1:0]  sq_top   = sq_in[31:30];
    wire [19:0] sq_cand  = {sq_rem, sq_top};
    wire [19:0] sq_trial = {sq_root, 2'd1};
    wire        sq_acc    = sq_cand >= sq_trial;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            sample_addr    <= 9'd0;
            sample_cnt     <= 10'd0;
            read_en        <= 1'b0;
            feature_valid  <= 1'b0;

            sum            <= 32'd0;
            sum_square     <= 64'd0;
            peak_reg       <= -8'sd128;
            min_reg        <= 8'sd127;
            zc_cnt         <= 16'd0;
            pos_cnt        <= 16'd0;
            prev_sign      <= 1'b0;

            rr_timer       <= 16'd0;
            rr_current     <= 16'd0;
            rr_previous    <= 16'd0;
            sample_delayed <= 8'd0;

            sq_in          <= 32'd0;
            sq_rem         <= 16'd0;
            sq_root        <= 16'd0;
            sq_cnt         <= 5'd0;
            rms_reg        <= 16'd0;

            div_dividend   <= 28'd0;
            div_quot       <= 28'd0;
            div_divisor    <= 16'd0;
            div_rem        <= 17'd0;
            div_cnt        <= 6'd0;

            f_rms          <= 16'd0;
            f_var          <= 16'd0;
            f_peak         <= 16'd0;
            f_zc           <= 16'd0;
            f_ptp          <= 16'd0;
            f_crest        <= 16'd0;
            f_half_ratio   <= 16'd0;
            f_max          <= 16'd0;
            f_rr           <= 16'd0;
            f_rr_prev      <= 16'd0;
            f_rr_ratio     <= 16'd0;
            f_rr_diff      <= 16'd0;
        end else if (soft_reset) begin
            state          <= S_IDLE;
            sample_addr    <= 9'd0;
            sample_cnt     <= 10'd0;
            read_en        <= 1'b0;
            feature_valid  <= 1'b0;

            sum            <= 32'd0;
            sum_square     <= 64'd0;

            rr_timer       <= 16'd0;
            rr_current     <= 16'd0;
            rr_previous    <= 16'd0;
            sample_delayed <= 8'd0;

            sq_in          <= 32'd0;
            sq_rem         <= 16'd0;
            sq_root        <= 16'd0;
            sq_cnt         <= 5'd0;
            rms_reg        <= 16'd0;

            div_dividend   <= 28'd0;
            div_quot       <= 28'd0;
            div_divisor    <= 16'd0;
            div_rem        <= 17'd0;
            div_cnt        <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    read_en       <= 1'b0;
                    feature_valid <= 1'b0;
                    sample_addr   <= 9'd0;
                    sample_cnt    <= 10'd0;

                    if (start_compute) begin
                        state          <= S_ACCUMULATE_ADDR;
                        sum            <= 32'd0;
                        sum_square     <= 64'd0;
                        peak_reg       <= -8'sd128;
                        min_reg        <= 8'sd127;
                        zc_cnt         <= 16'd0;
                        pos_cnt        <= 16'd0;
                        prev_sign      <= 1'b0;
                        rr_timer       <= 16'd0;
                        rr_current     <= 16'd0;
                        rr_previous    <= 16'd0;
                        sample_delayed <= 8'd0;
                        sq_in          <= 32'd0;
                        sq_rem         <= 16'd0;
                        sq_root        <= 16'd0;
                        sq_cnt         <= 5'd0;
                        rms_reg        <= 16'd0;
                        sample_addr    <= 9'd0;
                    end
                end

                S_ACCUMULATE_ADDR: begin
                    read_en     <= 1'b1;
                    sample_addr <= sample_cnt[8:0];
                    state       <= S_ACCUMULATE_WAIT;
                end

                // Cho RAM dong bo nhan dia chi va cap nhat du lieu.
                S_ACCUMULATE_WAIT: begin
                    state <= S_ACCUMULATE_READ;
                end

                S_ACCUMULATE_READ: begin
                    sum <= sum +
                        $signed({{24{sample_in[7]}}, sample_in});

                    sum_square <= sum_square +
                        ($signed({{56{sample_in[7]}}, sample_in}) *
                         $signed({{56{sample_in[7]}}, sample_in}));

                    if ($signed(sample_in) > peak_reg)
                        peak_reg <= $signed(sample_in);

                    if ($signed(sample_in) < min_reg)
                        min_reg <= $signed(sample_in);

                    if (sample_cnt > 10'd0) begin
                        if (prev_sign ^ sample_in[7])
                            zc_cnt <= zc_cnt + 16'd1;
                    end

                    prev_sign <= sample_in[7];

                    if (!sample_in[7])
                        pos_cnt <= pos_cnt + 16'd1;

                    if (sample_delayed > ecg_threshold[7:0] &&
                        sample_in <= ecg_threshold[7:0]) begin
                        rr_previous <= rr_current;
                        rr_current  <= rr_timer;
                        rr_timer    <= 16'd0;
                    end else begin
                        rr_timer <= rr_timer + 16'd1;
                    end

                    sample_delayed <= sample_in;

                    if (sample_cnt == NUM_SAMPLES - 1) begin
                        read_en <= 1'b0;
                        state   <= S_CALC_BASE;
                    end else begin
                        sample_cnt <= sample_cnt + 10'd1;
                        state      <= S_ACCUMULATE_ADDR;
                    end
                end

                S_CALC_BASE: begin
                    f_peak <= $signed({{8{peak_reg[7]}}, peak_reg});
                    f_max  <= $signed({{8{peak_reg[7]}}, peak_reg});

                    f_ptp <=
                        $signed({{8{peak_reg[7]}}, peak_reg}) -
                        $signed({{8{min_reg[7]}}, min_reg});

                    f_zc         <= $signed(zc_cnt);
                    f_half_ratio <= $signed(pos_cnt <<< 3);
                    f_rr         <= $signed(rr_current);
                    f_rr_prev    <= $signed(rr_previous);
                    f_rr_diff    <= $signed(rr_current - rr_previous);
                    state        <= S_CALC_VAR;
                end

                // f_var = (512*sum_sq - sum^2) >> 18  (population variance,
                // always >= 0). var_num < 2^32 so [33:18] is the exact value.
                S_CALC_VAR: begin
                    f_var <= $signed(var_num[33:18]);
                    state <= S_CALC_RMS;
                end

                // Start the square root of mean_square. Operate on a 32-bit
                // radicand (mean_square << 16) so the root is the RMS in
                // Q8.8 (internal fixed-point precision), 16 iterations.
                S_CALC_RMS: begin
                    sq_in   <= {mean_sq, 16'd0};
                    sq_rem  <= 16'd0;
                    sq_root <= 16'd0;
                    sq_cnt  <= 5'd0;
                    state   <= S_CALC_SQRT;
                end

                // Digit-by-step restoring sqrt, 2 radicand bits per cycle,
                // 16 cycles on the 32-bit input. Invariant:
                //   sq_root = floor(sqrt(prefix)),  sq_rem = prefix - sq_root^2.
                // f_rms = integer part (sq_root >> 8); rms_reg keeps the full
                // Q8.8 value so crest divides by internal precision.
                S_CALC_SQRT: begin
                    if (sq_cnt == 5'd16) begin
                        rms_reg <= sq_root;
                        f_rms    <= $signed({8'd0, sq_root[15:8]});
                        state    <= S_DIV_CREST;
                    end else begin
                        sq_rem  <= sq_acc ? (sq_cand - sq_trial) : sq_cand;
                        sq_root <= sq_acc ? {sq_root[14:0], 1'b1}
                                         : {sq_root[14:0], 1'b0};
                        sq_in   <= sq_in << 2;
                        sq_cnt  <= sq_cnt + 5'd1;
                    end
                end

                // Crest factor = |peak| / rms, using the INTERNAL Q8.8 rms
                // (rms_reg) as the divisor -- NOT the integer f_rms, which is
                // rounded and would inject truncation error. Numerator
                // mag_peak << 16; the quotient is the crest factor in Q8
                // (ratio * 256). int16-safe: max ratio 127 (rms_fp>=256)
                // -> 127*256 = 32512 < 32768.
                               S_DIV_CREST: begin
                    if (div_cnt == 6'd0) begin
                        if (rms_reg == 16'd0) begin
                            f_crest <= 16'd0;
                            div_cnt <= 6'd0;
                            state   <= S_DIV_RR;
                        end else begin
                            div_divisor  <= rms_reg;
                            div_dividend <= {4'd0, mag_peak, 16'd0};
                            div_quot     <= 28'd0;
                            div_rem      <= 17'd0;
                            div_cnt      <= 6'd1;
                        end
                    end else if (div_cnt <= 6'd28) begin
                        div_dividend <= div_dividend << 1;

                        if ({div_rem[15:0], div_dividend[27]} >=
                            {1'b0, div_divisor}) begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]} -
                                {1'b0, div_divisor};

                            div_quot <=
                                div_quot |
                                (28'h1 << (6'd28 - div_cnt));
                        end else begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]};
                        end

                        div_cnt <= div_cnt + 6'd1;
                    end else begin
                        f_crest <=
                            $signed(peak_reg) < 0
                            ? -$signed(div_quot[15:0])
                            :  $signed(div_quot[15:0]);

                        state   <= S_DIV_RR;
                        div_cnt <= 6'd0;
                    end
                end

                S_DIV_RR: begin
                    if (div_cnt == 6'd0) begin
                        if (rr_previous == 16'd0) begin
                            f_rr_ratio <= 16'd4096;
                            div_cnt    <= 6'd0;
                            state      <= S_DONE;
                        end else begin
                            div_divisor  <= rr_previous;
                            div_dividend <= {rr_current, 12'd0};
                            div_quot     <= 28'd0;
                            div_rem      <= 17'd0;
                            div_cnt      <= 6'd1;
                        end
                    end else if (div_cnt <= 6'd28) begin
                        div_dividend <= div_dividend << 1;

                        if ({div_rem[15:0], div_dividend[27]} >=
                            {1'b0, div_divisor}) begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]} -
                                {1'b0, div_divisor};

                            div_quot <=
                                div_quot |
                                (28'h1 << (6'd28 - div_cnt));
                        end else begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]};
                        end

                        div_cnt <= div_cnt + 6'd1;
                    end else begin
                        f_rr_ratio <= div_quot[15:0];
                        state      <= S_DONE;
                        div_cnt    <= 6'd0;
                    end
                end

                S_DONE: begin
                    feature_valid <= 1'b1;
                    state         <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            overflow <= 1'b0;
        else
            overflow <= (sum_square[63:62] != 2'b00)
                        ? 1'b1 : 1'b0;
    end

endmodule