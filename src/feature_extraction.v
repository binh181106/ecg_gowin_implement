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

    reg signed [63:0] mean_val;
    reg signed [31:0] rms_calc;

    reg [27:0] div_dividend;
    reg [27:0] div_quot;
    reg [15:0] div_divisor;
    reg [16:0] div_rem;
    reg [5:0] div_cnt;

    wire [7:0] mag_peak =
        peak_reg[7] ? (8'd0 - peak_reg) : peak_reg;

    wire signed [31:0] rms_now =
        $signed(sum_square[31:0] >> 9);

    wire signed [63:0] var_now =
        (sum_square <<< 3) - ((mean_val * mean_val) >>> 12);

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
                    mean_val <= $signed(sum) <<< 3;

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

                S_CALC_VAR: begin
                    f_var <= $signed(var_now[15:0]);
                    state <= S_CALC_RMS;
                end

                S_CALC_RMS: begin
                    rms_calc <= $signed(sum_square[31:0] >> 9);
                    f_rms    <= $signed(rms_now[15:0]);
                    state    <= S_DIV_CREST;
                end

                // Bo chia giu nguyen ban goc; se sua o buoc tiep theo.
                S_DIV_CREST: begin
                    if (div_cnt == 6'd0) begin
                        div_divisor <=
                            (rms_now[15:0] == 16'd0)
                            ? 16'd1 : rms_now[15:0];

                        div_dividend <= {12'd0, mag_peak, 12'd0};
                        div_quot     <= 28'd0;
                        div_rem      <= 17'd0;

                        div_cnt <=
                            (rms_now[15:0] == 16'd0)
                            ? 6'd28 : 6'd1;

                        if (rms_now[15:0] == 16'd0)
                            f_crest <= 16'd0;
                    end else if (div_cnt <= 6'd28) begin
                        div_dividend <= div_dividend << 1;

                        if ({div_rem[15:0], div_dividend[27]} >=
                            {1'b0, div_divisor}) begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]} -
                                {1'b0, div_divisor};

                            div_quot <=
                                div_quot |
                                (28'h1 << (6'd27 - div_cnt));
                        end else begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]};
                            div_quot <= div_quot;
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
                        div_divisor <=
                            (rr_previous == 16'd0)
                            ? 16'd1 : rr_previous;

                        div_dividend <= {rr_current, 12'd0};
                        div_quot     <= 28'd0;
                        div_rem      <= 17'd0;

                        div_cnt <=
                            (rr_previous == 16'd0)
                            ? 6'd28 : 6'd1;

                        if (rr_previous == 16'd0)
                            f_rr_ratio <= 16'd4096;
                    end else if (div_cnt <= 6'd28) begin
                        div_dividend <= div_dividend << 1;

                        if ({div_rem[15:0], div_dividend[27]} >=
                            {1'b0, div_divisor}) begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]} -
                                {1'b0, div_divisor};

                            div_quot <=
                                div_quot |
                                (28'h1 << (6'd27 - div_cnt));
                        end else begin
                            div_rem <=
                                {div_rem[15:0], div_dividend[27]};
                            div_quot <= div_quot;
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