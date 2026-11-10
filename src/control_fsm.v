`timescale 1ns / 1ps

// One feature transaction -> one MLP start -> one successful completion.
// The classifier owns normalization/MAC timing. Legacy state codes 0..9
// remain useful for debug; state 10 is a fail-stop error until soft reset.
module control_fsm #(
    parameter [27:0] LOAD_TIMEOUT = 28'd100_000_000,
    parameter [27:0] MLP_TIMEOUT  = 28'd10_000
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire feat_valid,
    input wire apb_enable,
    input wire window_ready,
    input wire mlp_done,
    input wire soft_reset,
    output wire fsm_idle,
    output wire window_en,
    output reg feature_start,
    output wire feature_read_en,
    output reg mlp_start,
    output reg mlp_valid,
    output reg uart_send,
    output reg done,
    output wire [8:0] read_addr,
    output wire [3:0] current_state,
    output wire [3:0] next_state_debug,
    output reg pipeline_error
);
    localparam S_IDLE   = 4'd0, S_LOAD   = 4'd1, S_NORM = 4'd2,
               S_FC1    = 4'd3, S_FC1_B  = 4'd4, S_RELU = 4'd5,
               S_FC2    = 4'd6, S_FC2_B  = 4'd7, S_ARGMAX = 4'd8,
               S_DONE   = 4'd9, S_ERROR  = 4'd10;

    reg [3:0] state, next_state;
    reg [27:0] timeout_cnt;
    reg feat_started, mlp_active, window_pending, start_d;
    wire start_event = start && !start_d;

    assign fsm_idle = (state == S_IDLE);
    assign window_en = apb_enable && !soft_reset && !pipeline_error;
    assign feature_read_en = 1'b0; // feature_extraction owns the RAM port
    assign read_addr = 9'd0;
    assign current_state = state;
    assign next_state_debug = next_state;

    always @* begin
        next_state = state;
        case (state)
            S_IDLE: if (start_event && apb_enable) next_state = S_LOAD;
            S_LOAD: begin
                if (feat_started && feat_valid) next_state = S_NORM;
                else if (timeout_cnt == 0) next_state = S_ERROR;
            end
            S_NORM: next_state = S_FC1;
            S_FC1: begin
                // A completion on the final permitted edge wins over timeout.
                if (mlp_active && mlp_done) next_state = S_FC1_B;
                else if (timeout_cnt == 0) next_state = S_ERROR;
            end
            S_FC1_B: next_state = S_RELU;
            S_RELU: next_state = S_FC2;
            S_FC2: next_state = S_FC2_B;
            S_FC2_B: next_state = S_ARGMAX;
            S_ARGMAX: next_state = S_DONE;
            S_DONE: next_state = S_IDLE;
            S_ERROR: next_state = S_ERROR;
            default: next_state = S_ERROR;
        endcase
        if (soft_reset) next_state = S_IDLE;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            timeout_cnt <= 0;
            feat_started <= 0;
            mlp_active <= 0;
            window_pending <= 0;
            start_d <= 0;
            feature_start <= 0;
            mlp_start <= 0;
            mlp_valid <= 0;
            uart_send <= 0;
            done <= 0;
            pipeline_error <= 0;
        end else if (soft_reset) begin
            // Abort every outstanding transaction, including a pending window.
            state <= S_IDLE;
            timeout_cnt <= 0;
            feat_started <= 0;
            mlp_active <= 0;
            window_pending <= 0;
            start_d <= 0;
            feature_start <= 0;
            mlp_start <= 0;
            mlp_valid <= 0;
            uart_send <= 0;
            done <= 0;
            pipeline_error <= 0;
        end else begin
            state <= next_state;
            start_d <= start;
            feature_start <= 0;
            mlp_start <= 0;
            uart_send <= 0;
            done <= 0;
            if (timeout_cnt != 0) timeout_cnt <= timeout_cnt - 1'b1;

            // Preserve a one-cycle ready event across IDLE/APB re-arming.
            // This is an event latch, not storage for multiple sample windows.
            if (window_ready && apb_enable) window_pending <= 1;

            case (state)
                S_IDLE: begin
                    feat_started <= 0;
                    mlp_active <= 0;
                    mlp_valid <= 0;
                    if (start_event && apb_enable) timeout_cnt <= LOAD_TIMEOUT;
                end
                S_LOAD: begin
                    if (feat_started && feat_valid) begin
                        feat_started <= 0;
                        mlp_valid <= 1;
                    end else if (!feat_started && (window_pending || window_ready)
                                 && timeout_cnt != 0) begin
                        feature_start <= 1;
                        feat_started <= 1;
                        window_pending <= 0;
                        timeout_cnt <= LOAD_TIMEOUT;
                    end
                end
                S_NORM: begin
                    // Accepted by ai_classifier on the following rising edge.
                    mlp_start <= 1;
                    mlp_active <= 1;
                    timeout_cnt <= MLP_TIMEOUT;
                end
                S_FC1: if (mlp_active && mlp_done) begin
                    mlp_active <= 0;
                    mlp_valid <= 0;
                end
                S_DONE: begin
                    done <= 1;
                    uart_send <= 1;
                end
                default: begin end
            endcase

            if (next_state == S_ERROR) begin
                pipeline_error <= 1;
                feature_start <= 0;
                mlp_start <= 0;
                mlp_valid <= 0;
                feat_started <= 0;
                mlp_active <= 0;
                window_pending <= 0;
                done <= 0;
                uart_send <= 0;
            end
        end
    end
endmodule
