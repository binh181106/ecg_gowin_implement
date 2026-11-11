`timescale 1ns/1ps
// G2.3: chronological accepted samples only; see G2_3_DESIGN_CONTRACT.txt.
module rr_tracker #(
    parameter integer REFRACTORY_SAMPLES = 72,
    parameter integer MAX_RR_SAMPLES = 1800
) (
    input wire clk, rst_n, soft_reset,
    input wire sample_accept,
    input wire signed [7:0] sample_in,
    input wire signed [15:0] threshold,
    output reg [63:0] next_sample_index,
    output reg peak_event,
    output reg [63:0] event_timestamp,
    output reg [15:0] rr_current, rr_previous,
    output reg current_valid, previous_valid,
    output reg timestamp_overflow
);
    reg signed [7:0] older_sample, previous_sample;
    reg [1:0] history_count;
    reg have_peak;
    reg [63:0] last_peak;
    wire threshold_valid = threshold >= 16'sd1 && threshold <= 16'sd127;
    wire [63:0] candidate_time = next_sample_index - 64'd1;
    wire [63:0] distance = candidate_time - last_peak;
    wire expired = have_peak && next_sample_index != 0 && distance > MAX_RR_SAMPLES;
    wire candidate = history_count == 2 && threshold_valid &&
        $signed({{8{previous_sample[7]}},previous_sample}) >= threshold &&
        previous_sample > older_sample && previous_sample >= sample_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset) begin
            next_sample_index <= 0;
            peak_event <= 0;
            event_timestamp <= 0;
            rr_current <= 0; rr_previous <= 0;
            current_valid <= 0; previous_valid <= 0;
            timestamp_overflow <= 0;
            older_sample <= 0; previous_sample <= 0; history_count <= 0;
            have_peak <= 0; last_peak <= 0;
        end else begin
            peak_event <= 0;
            if (sample_accept) begin
                if (&next_sample_index) begin
                    // Halt rather than wrap/reuse timestamps. Reset is required.
                    timestamp_overflow <= 1;
                    rr_current <= 0; rr_previous <= 0;
                    current_valid <= 0; previous_valid <= 0;
                    have_peak <= 0; history_count <= 0;
                end else begin
                    next_sample_index <= next_sample_index + 64'd1;
                    older_sample <= previous_sample;
                    previous_sample <= sample_in;
                    if (history_count < 2) history_count <= history_count + 1'b1;
                    if (!threshold_valid) begin
                        history_count <= 0; have_peak <= 0;
                        rr_current <= 0; rr_previous <= 0;
                        current_valid <= 0; previous_valid <= 0;
                    end else begin
                        if (expired) begin
                            have_peak <= 0;
                            rr_current <= 0; rr_previous <= 0;
                            current_valid <= 0; previous_valid <= 0;
                        end
                        if (candidate && (!have_peak || expired || distance >= REFRACTORY_SAMPLES)) begin
                            peak_event <= 1;
                            event_timestamp <= candidate_time;
                            last_peak <= candidate_time;
                            have_peak <= 1;
                            if (have_peak && !expired) begin
                                rr_current <= distance[15:0];
                                current_valid <= 1;
                                rr_previous <= current_valid ? rr_current : 16'd0;
                                previous_valid <= current_valid;
                            end else begin
                                rr_current <= 0; rr_previous <= 0;
                                current_valid <= 0; previous_valid <= 0;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
