`timescale 1ns / 1ps

// =============================================================================
// Window Buffer Module - 50% Overlap Circular Buffer
// =============================================================================
// Application: ECG R-peak detection
// Sample Rate: 360 Hz
//
// Overlap Strategy:
// - Circular Buffer chứa 512 samples mới nhất
// - Mỗi 256 samples (711ms) -> output window với 50% overlap
// - R-peaks không bị miss vì overlap đủ rộng (1/2 beat)
//
// Timing:
//   - ECG ~60-120 bpm = 1-2 beats/second
//   - R-peak width ~100ms = 36 samples @ 360Hz
//   - 256 samples overlap = 711ms = đủ để capture R-peak
//
// Implementation:
//   - Sử dụng IP Gowin_SDPB (512x8) làm bộ đệm vòng (circular buffer)
//   - Cổng A: Ghi (Write) từ ADC
//   - Cổng B: Đọc (Read) ra cho Feature Extraction
//   - Độ trễ đọc (Read Latency): 1 chu kỳ xung nhịp (Bypass mode)
// =============================================================================

module window_buffer #(
    parameter DATA_WIDTH = 8,
    parameter WINDOW_SIZE = 512,
    parameter OVERLAP = 256,       // 50% overlap
    parameter BASELINE_OFFSET = 169 // AD8232 baseline offset (~169-170 for 0V output)
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              enable,
    input  wire              soft_reset,
    input  wire [DATA_WIDTH-1:0] sample_in,
    input  wire              sample_valid,
    input  wire              read_en,
    input  wire [8:0]        read_addr,
    output wire [DATA_WIDTH-1:0] frame_out,
    output reg               window_ready,
    output reg               ready_bank,     // Alias for window_ready (backward compat)
    output reg  [31:0]       samples_collected,
    output reg  [8:0]        sample_cnt      // Debug
);

    // =============================================================================
    // Constants
    // =============================================================================
    localparam ADDR_W = 9;  // 9 bits for 512 addresses
    localparam ADDR_MAX = WINDOW_SIZE - 1;  // 511

    // =============================================================================
    // Baseline Subtraction
    // =============================================================================
    // AD8232 outputs ~169-170 at 0V, so we subtract to get true ECG signal
    // Result is signed: sample - baseline (can be negative)
    // Saturate at 0 if below baseline.
    localparam [DATA_WIDTH-1:0] BASELINE_OFF_W = BASELINE_OFFSET;
    wire [DATA_WIDTH:0] baseline_sub;
    assign baseline_sub = {1'b0, sample_in} - {1'b0, BASELINE_OFF_W};
    wire [DATA_WIDTH-1:0] baseline_corrected;
    assign baseline_corrected = (sample_in >= BASELINE_OFF_W) ?
                                baseline_sub[DATA_WIDTH-1:0] :
                                {DATA_WIDTH{1'b0}};

    // =============================================================================
    // Write Pointer - circular, 0 to 511
    // =============================================================================
    reg [ADDR_W-1:0] write_ptr;

    // =============================================================================
    // Write Logic
    // =============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset) begin
            write_ptr         <= 9'd0;
            sample_cnt        <= 9'd0;
            window_ready      <= 1'b0;
            ready_bank        <= 1'b0;
            samples_collected <= 32'd0;
        end else begin
            window_ready <= 1'b0;
            ready_bank <= 1'b0;

            if (enable && sample_valid) begin
                // Advance circular pointer
                if (write_ptr == ADDR_MAX)
                    write_ptr <= 9'd0;
                else
                    write_ptr <= write_ptr + 9'd1;

                // Count samples
                if (sample_cnt < ADDR_MAX)
                    sample_cnt <= sample_cnt + 9'd1;

                samples_collected <= samples_collected + 32'd1;

                // Overlap trigger: cửa sổ đầy đủ WINDOW_SIZE (512) mẫu, phát lại
                // mỗi OVERLAP (256) mẫu.
                if ((samples_collected + 32'd1) >= WINDOW_SIZE &&
                    ((samples_collected + 32'd1) - WINDOW_SIZE) % OVERLAP == 0) begin
                    window_ready <= 1'b1;
                    ready_bank <= 1'b1;
                end
            end
        end
    end

    // =============================================================================
    // Read Logic
    // =============================================================================
    // Feature Extraction đọc từ buffer:
    // - window_ready = 1 -> start reading 512 samples
    // - read_addr 0 = oldest sample in window
    // - read_addr 511 = newest sample

    // Calculate oldest sample address in current window
    wire [ADDR_W-1:0] oldest_addr;
    assign oldest_addr = (sample_cnt >= ADDR_MAX) ?
                         // Buffer full: oldest is at current write position
                         write_ptr :
                         // Buffer not full yet: oldest is at address 0
                         9'd0;

    // Actual read address with circular wrap
    wire [ADDR_W-1:0] actual_read_addr;
    assign actual_read_addr = (oldest_addr + read_addr) % WINDOW_SIZE;

    // =============================================================================
    // RAM for circular buffer (Gowin SDPB IP)
    // =============================================================================
    Gowin_SDPB u_hw_buffer (
        // --- PORT A: GHI (WRITE) ---
        .clka(clk),
        .cea(enable & sample_valid),
        .ada(write_ptr),
        .din(baseline_corrected),
        
        // --- PORT B: ĐỌC (READ) ---
        .clkb(clk),
        .ceb(read_en),
        .oce(1'b1),
        .adb(actual_read_addr),
        .dout(frame_out),
        
        // --- ĐIỀU KHIỂN CHUNG ---
        .reset(~rst_n | soft_reset)
    );

endmodule