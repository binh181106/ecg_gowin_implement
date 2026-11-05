`timescale 1ns / 1ps
module ai_classifier #(
    parameter FEATURE_WIDTH = 16,
    parameter HIDDEN_NEURONS = 8,
    parameter OUTPUT_NEURONS = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              soft_reset,
    input  wire              start,
    input  wire              enable,
    input wire [12*FEATURE_WIDTH-1:0] features_flat,
    output reg  [1:0]        class_code,
    output reg               done,
    output reg               overflow,
    output wire [32*HIDDEN_NEURONS-1:0] fc1_out_flat,
    output wire [32*OUTPUT_NEURONS-1:0] fc2_out_flat
);

    wire signed [FEATURE_WIDTH-1:0] features [0:11];
    reg signed [31:0] fc1_out [0:HIDDEN_NEURONS-1];
    reg signed [31:0] fc2_out [0:OUTPUT_NEURONS-1];
    genvar g;
    generate
      for (g=0; g<12; g=g+1) begin: FEATURE_UNPACK
        assign features[g] = features_flat[g*FEATURE_WIDTH +: FEATURE_WIDTH];
      end
      for (g=0; g<HIDDEN_NEURONS; g=g+1) begin: FC1_PACK
        assign fc1_out_flat[g*32 +: 32] = fc1_out[g];
      end
      for (g=0; g<OUTPUT_NEURONS; g=g+1) begin: FC2_PACK
        assign fc2_out_flat[g*32 +: 32] = fc2_out[g];
      end
    endgenerate

    localparam S_IDLE     = 4'd0;
    localparam S_LOAD    = 4'd1;
    localparam S_NORM    = 4'd2;
    localparam S_FC1     = 4'd3;
    localparam S_FC1_B   = 4'd4;
    localparam S_RELU    = 4'd5;
    localparam S_FC2     = 4'd6;
    localparam S_FC2_B   = 4'd7;
    localparam S_ARGMAX  = 4'd8;
    localparam S_DONE    = 4'd9;
    reg [3:0] state;
    reg signed [31:0] features_norm [0:11];
    reg signed [31:0] hidden_out [0:HIDDEN_NEURONS-1];
    reg signed [31:0] fc1_out_raw [0:HIDDEN_NEURONS-1];
    reg signed [31:0] fc2_out_raw [0:OUTPUT_NEURONS-1];
    reg [7:0] cnt;
    // Weight/bias storage. Indexed [0:95],[0:7],[0:31],[0:3] to match the
    // MAC loop bounds; only the elements actually read (fc1_weights[0:95],
    // fc1_biases[0:7], fc2_weights[0:31], fc2_biases[0:3]) are driven in
    // the initial block. Unused high indices are 0.
    reg signed [15:0] fc1_weights [0:95];
    reg signed [15:0] fc1_biases  [0:7];
    reg signed [15:0] fc2_weights [0:31];
    reg signed [15:0] fc2_biases  [0:3];
    reg signed [15:0] mean_vals   [0:11];
    reg signed [15:0] inv_scale   [0:11];
    integer i;
    initial begin
        for (i = 0; i < 12; i = i + 1) begin
            mean_vals[i] = 16'd0;
            inv_scale[i] = 16'd4096;
        end
        for (i = 0; i < 96; i = i + 1) begin
            fc1_weights[i] = 16'd0;
        end
        for (i = 0; i < 8; i = i + 1) begin
            fc1_biases[i] = 16'd0;
        end
        for (i = 0; i < 32; i = i + 1) begin
            fc2_weights[i] = 16'd0;
        end
        for (i = 0; i < 4; i = i + 1) begin
            fc2_biases[i] = 16'd0;
        end
    end
    // (fix EX1998) rom_we / rom_wdata / rom_addr were undriven regs feeding a
    // dead ROM-load case (the "external ROM" write port of the classifier,
    // which never fires because weights are zero-by-design in this demo).
    // The whole block + its three *_w alias wires are removed, so the
    // undriven nets are gone. The initial-block zero fills above still give
    // the classifier its placeholder weights.

    reg signed [47:0] mac_temp;
    reg                overflow_latch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            overflow   <= 1'b0;
            class_code <= 2'b0;
            cnt        <= 8'd0;
            overflow_latch <= 1'b0;
            for (i = 0; i < 12; i = i + 1)
                features_norm[i] <= 32'd0;
            for (i = 0; i < 8; i = i + 1) begin
                hidden_out[i] <= 32'd0;
                fc1_out[i] <= 32'd0;
                fc1_out_raw[i] <= 32'd0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                fc2_out[i] <= 32'd0;
                fc2_out_raw[i] <= 32'd0;
            end
        end else if (soft_reset) begin
            state          <= S_IDLE;
            done           <= 1'b0;
            cnt            <= 8'd0;
            overflow       <= 1'b0;
            overflow_latch <= 1'b0;
        end else begin
            done     <= 1'b0;
            overflow <= overflow_latch;
            case (state)
                S_IDLE: begin
                    cnt <= 8'd0;
                    if (start && enable) begin
                        overflow_latch <= 1'b0;
                        state <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    state <= S_NORM;
                end
                S_NORM: begin
                    cnt <= cnt + 8'd1;
                    if (cnt < 8'd12) begin
                        features_norm[cnt] <=
                            ($signed(features[cnt]) - $signed(mean_vals[cnt])) *
                            $signed(inv_scale[cnt]);
                    end else begin
                        cnt <= 8'd0;
                        state <= S_FC1;
                    end
                end
                S_FC1: begin
                    cnt <= cnt + 8'd1;
                    if (cnt == 8'd0) begin
                        for (i = 0; i < HIDDEN_NEURONS; i = i + 1)
                            fc1_out_raw[i] <= 32'd0;
                    end else if (cnt <= 8'd96) begin
                        begin : GOWIN_FC1_MAC
                            reg signed [47:0] mac_prod;
                            reg signed [47:0] mac_next;
                            mac_prod = $signed(features_norm[(cnt-1)%12]) *
                                       $signed(fc1_weights[cnt-1]);
                            mac_next = fc1_out_raw[(cnt-1)/12] + (mac_prod >>> 12);
                            if (mac_next > 48'sd2147483647) begin
                                fc1_out_raw[(cnt-1)/12] <= 32'h7FFFFFFF;
                                overflow_latch <= 1'b1;
                            end else if (mac_next < -48'sd2147483648) begin
                                fc1_out_raw[(cnt-1)/12] <= 32'h80000000;
                                overflow_latch <= 1'b1;
                            end else begin
                                fc1_out_raw[(cnt-1)/12] <= mac_next[31:0];
                            end
                        end
                    end else begin
                        cnt <= 8'd0;
                        state <= S_FC1_B;
                    end
                end
                S_FC1_B: begin
                    cnt <= cnt + 8'd1;
                    if (cnt < 8'd8) begin
                        fc1_out_raw[cnt] <= fc1_out_raw[cnt] + $signed(fc1_biases[cnt]);
                    end else begin
                        cnt <= 8'd0;
                        state <= S_RELU;
                    end
                end
                S_RELU: begin
                    cnt <= cnt + 8'd1;
                    if (cnt < 8'd8) begin
                        if (fc1_out_raw[cnt] > 32'sd0) begin
                            hidden_out[cnt] <= fc1_out_raw[cnt];
                            fc1_out[cnt] <= fc1_out_raw[cnt];
                        end else begin
                            hidden_out[cnt] <= 32'd0;
                            fc1_out[cnt] <= 32'd0;
                        end
                    end else begin
                        cnt <= 8'd0;
                        state <= S_FC2;
                    end
                end
                S_FC2: begin
                    cnt <= cnt + 8'd1;
                    if (cnt == 8'd0) begin
                        for (i = 0; i < OUTPUT_NEURONS; i = i + 1)
                            fc2_out_raw[i] <= 32'd0;
                    end else if (cnt <= 8'd32) begin
                        begin : GOWIN_FC2_MAC
                            reg signed [47:0] mac_prod;
                            reg signed [47:0] mac_next;
                            mac_prod = $signed(hidden_out[(cnt-1)%8]) *
                                       $signed(fc2_weights[cnt-1]);
                            mac_next = fc2_out_raw[(cnt-1)/8] + (mac_prod >>> 12);
                            if (mac_next > 48'sd2147483647) begin
                                fc2_out_raw[(cnt-1)/8] <= 32'h7FFFFFFF;
                                overflow_latch <= 1'b1;
                            end else if (mac_next < -48'sd2147483648) begin
                                fc2_out_raw[(cnt-1)/8] <= 32'h80000000;
                                overflow_latch <= 1'b1;
                            end else begin
                                fc2_out_raw[(cnt-1)/8] <= mac_next[31:0];
                            end
                        end
                    end else begin
                        cnt <= 8'd0;
                        state <= S_FC2_B;
                    end
                end
                S_FC2_B: begin
                    cnt <= cnt + 8'd1;
                    if (cnt < 8'd4) begin
                        fc2_out_raw[cnt] <= fc2_out_raw[cnt] + $signed(fc2_biases[cnt]);
                        fc2_out[cnt] <= fc2_out_raw[cnt] + $signed(fc2_biases[cnt]);
                    end else begin
                        cnt <= 8'd0;
                        state <= S_ARGMAX;
                    end
                end
                S_ARGMAX: begin
                    if (fc2_out_raw[0] >= fc2_out_raw[1] &&
                        fc2_out_raw[0] >= fc2_out_raw[2] &&
                        fc2_out_raw[0] >= fc2_out_raw[3]) begin
                        class_code <= 2'd0;
                    end else if (fc2_out_raw[1] >= fc2_out_raw[2] &&
                               fc2_out_raw[1] >= fc2_out_raw[3]) begin
                        class_code <= 2'd1;
                    end else if (fc2_out_raw[2] >= fc2_out_raw[3]) begin
                        class_code <= 2'd2;
                    end else begin
                        class_code <= 2'd3;
                    end
                    state <= S_DONE;
                end
                S_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
