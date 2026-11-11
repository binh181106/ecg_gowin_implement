`timescale 1ns / 1ps
module top_ecg_rom_demo #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer TARGET_HZ = 360,
    parameter ROM_WORDS   = 2048,
    parameter ROM_DW      = 8,
    parameter ROM_HEX     = "demo/ecg_rom.hex",
    parameter integer UART_CLKS_PER_BIT = 437,
    parameter integer PREPROCESS_MODE = 1, // ROM unsigned codes -> signed raw-128
    parameter [ROM_DW-1:0] ADC_ZERO_CODE = 128,
    parameter integer RR_REFRACTORY_SAMPLES = 72,
    parameter integer RR_MAX_SAMPLES = 1800
) (
    input  wire             sys_clk,
    input  wire             sys_rst_n,
    output wire             uart_txd,
    input  wire             uart_rxd,
    output wire [3:0]       status_led,
    output wire             demo_done,
    output wire             demo_overflow,
    output wire [1:0]       demo_class
);
    wire clk   = sys_clk;
    wire rst_n = sys_rst_n;
    wire ble_enable, uart_enable, soft_reset;
    // A demo soft reset restarts the ROM and discards any partial UART frame.
    wire demo_rst_n = rst_n && !soft_reset;
    wire [$clog2(ROM_WORDS)-1:0] rom_addr;
    wire [ROM_DW-1:0] rom_out;
    wire [ROM_DW-1:0] pace_data;
    wire pace_valid;
    wire pace_eod;
    ecg_rom #(
        .ROM_WORDS(ROM_WORDS),
        .ROM_DW(ROM_DW),
        .ROM_HEX(ROM_HEX)
    ) u_rom (
        .clk(clk),
        .rom_addr(rom_addr),
        .rom_out(rom_out)
    );
    sample_pacer #(
        .CLK_HZ(CLK_HZ),
        .TARGET_HZ(TARGET_HZ),
        .ROM_WORDS(ROM_WORDS),
        .ROM_DW(ROM_DW)
    ) u_pacer (
        .clk(clk),
        .rst_n(demo_rst_n),
        .rom_out(rom_out),
        .rom_addr(rom_addr),
        .sample_data(pace_data),
        .sample_valid(pace_valid),
        .end_of_data(pace_eod)
    );
    wire [ROM_DW-1:0] adc_sample;
    wire adc_sample_valid, adc_overflow;
    wire window_enable, window_ready;
    wire feature_start, feat_valid, feature_overflow;
    wire mlp_start, mlp_done, mlp_overflow;
    wire pipeline_error;
    wire [1:0] sys_class_code;
    wire sys_done, sys_busy, sys_start, sys_enable;
    wire sys_overflow;
    wire [31:0] csr_prdata;
    wire csr_pready, csr_pslverr, csr_irq;
    wire uart_tx_busy, uart_tx_done;
    wire [15:0] ecg_threshold, baud_div;
    wire signed [15:0] f_rms, f_var, f_peak, f_zc, f_ptp, f_crest;
    wire signed [15:0] f_half_ratio, f_max, f_rr, f_rr_prev, f_rr_ratio, f_rr_diff;
    wire [8:0] feat_read_addr;
    wire feat_read_en;
    wire signed [ROM_DW-1:0] window_frame_wire;
    wire signed [ROM_DW-1:0] rr_stream_sample;
    wire rr_stream_accept;
    wire [15:0] rr_current, rr_previous;
    wire rr_current_valid, rr_previous_valid;
    reg [15:0] rr_snapshot_current, rr_snapshot_previous;
    reg rr_snapshot_current_valid, rr_snapshot_previous_valid;
    wire rr_valid, rr_ratio_saturated;
    rr_tracker #(.REFRACTORY_SAMPLES(RR_REFRACTORY_SAMPLES),
                 .MAX_RR_SAMPLES(RR_MAX_SAMPLES)) u_rr (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .sample_accept(rr_stream_accept), .sample_in(rr_stream_sample),
        .threshold($signed(ecg_threshold)), .rr_current(rr_current),
        .rr_previous(rr_previous), .current_valid(rr_current_valid),
        .previous_valid(rr_previous_valid), .next_sample_index(),
        .peak_event(), .event_timestamp(), .timestamp_overflow());
    // window_ready is registered by the final RAM write. At this edge the
    // tracker includes that write, including any newly confirmed peak.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset) begin
            rr_snapshot_current <= 0; rr_snapshot_previous <= 0;
            rr_snapshot_current_valid <= 0; rr_snapshot_previous_valid <= 0;
        end else if (window_ready) begin
            rr_snapshot_current <= rr_current;
            rr_snapshot_previous <= rr_previous;
            rr_snapshot_current_valid <= rr_current_valid;
            rr_snapshot_previous_valid <= rr_previous_valid;
        end
    end
    wire [31:0] apb_paddr, apb_pwdata;
    wire apb_psel, apb_penable, apb_pwrite;
    reg [15:0] win_index;
    always @(posedge clk or negedge demo_rst_n) begin
        if (!demo_rst_n)
            win_index <= 16'd0;
        else if (window_ready)
            win_index <= win_index + 16'd1;
    end
    adc_interface #(
        .DATA_WIDTH(ROM_DW),
        .DIV_WIDTH(2)
    ) u_adc_if (
        .clk(clk),
        .rst_n(demo_rst_n),
        .sample_rate_div(2'd1),
        .adc_data_in(pace_data),
        .adc_data_valid(pace_valid),
        .adc_clk(1'b0),
        .sample_out(adc_sample),
        .sample_valid(adc_sample_valid),
        .adc_overflow(adc_overflow),
        .sample_count()
    );
    window_buffer #(
        .DATA_WIDTH(ROM_DW),
        .WINDOW_SIZE(512),
        .OVERLAP(256),
        .PREPROCESS_MODE(PREPROCESS_MODE),
        .ADC_ZERO_CODE(ADC_ZERO_CODE)
    ) u_window (
        .clk(clk),
        .rst_n(rst_n),
        .enable(window_enable),
        .soft_reset(soft_reset),
        .sample_in(adc_sample),
        .sample_valid(adc_sample_valid),
        .read_en(feat_read_en),
        .read_addr(feat_read_addr),
        .frame_out(window_frame_wire),
        .window_ready(window_ready),
        .samples_collected(),
        .ready_bank(),
        .sample_cnt(),
        .stream_sample(rr_stream_sample), .stream_accept(rr_stream_accept)
    );
    // FPGA GOWIN: flatten packed features, feature zero is LSB.
wire [191:0] features_flat = {
  f_rr_diff,f_rr_ratio,f_rr_prev,f_rr,
  f_max,f_half_ratio,f_crest,f_ptp,
  f_zc,f_peak,f_var,f_rms
};

    feature_extraction #(
        .DATA_IN_WIDTH(ROM_DW),
        .DATA_OUT_WIDTH(16),
        .NUM_SAMPLES(512)
    ) u_feature (
        .clk(clk),
        .rst_n(rst_n),
        .soft_reset(soft_reset),
        .start_compute(feature_start),
        .ecg_threshold(ecg_threshold),
        .rr_snapshot_current(rr_snapshot_current),
        .rr_snapshot_previous(rr_snapshot_previous),
        .rr_snapshot_current_valid(rr_snapshot_current_valid),
        .rr_snapshot_previous_valid(rr_snapshot_previous_valid),
        .rr_valid(rr_valid), .rr_ratio_saturated(rr_ratio_saturated),
        .read_enable(1'b0),
        .sample_addr(feat_read_addr),
        .sample_in(window_frame_wire),
        .read_en(feat_read_en),
        .f_rms(f_rms), .f_var(f_var), .f_peak(f_peak), .f_zc(f_zc),
        .f_ptp(f_ptp), .f_crest(f_crest), .f_half_ratio(f_half_ratio),
        .f_max(f_max), .f_rr(f_rr), .f_rr_prev(f_rr_prev),
        .f_rr_ratio(f_rr_ratio), .f_rr_diff(f_rr_diff),
        .feature_valid(feat_valid),
        .overflow(feature_overflow)
    );
    wire fsm_idle;
    control_fsm u_ctrl_fsm (
        .clk(clk),
        .rst_n(rst_n),
        .start(sys_start),
        .feat_valid(feat_valid),
        .apb_enable(sys_enable),
        .window_ready(window_ready),
        .mlp_done(mlp_done),
        .soft_reset(soft_reset),
        .fsm_idle(fsm_idle),
        .window_en(window_enable),
        .feature_start(feature_start),
        .feature_read_en(),
        .mlp_start(mlp_start),
        .mlp_valid(),
        .uart_send(),
        .done(sys_done),
        .read_addr(),
        .current_state(),
        .next_state_debug(),
        .pipeline_error(pipeline_error)
    );
    ai_classifier #(
        .FEATURE_WIDTH(16),
        .HIDDEN_NEURONS(8),
        .OUTPUT_NEURONS(4)
    ) u_ai (
        .clk(clk),
        .rst_n(rst_n),
        .soft_reset(soft_reset),
        .start(mlp_start),
        .enable(sys_enable),
        .features_flat(features_flat),
        .class_code(sys_class_code),
        .done(mlp_done),
        .overflow(mlp_overflow),
        .fc1_out_flat(),
        .fc2_out_flat()
    );
    apb_slave_if #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_apb (
        .pclk(clk),
        .presetn(rst_n),
        .paddr(apb_paddr[7:0]),
        .psel(apb_psel),
        .penable(apb_penable),
        .pwrite(apb_pwrite),
        .pwdata(apb_pwdata),
        .prdata(csr_prdata),
        .pready(csr_pready),
        .pslverr(csr_pslverr),
        .p_irq(csr_irq),
        .sys_enable(sys_enable),
        .sys_start(sys_start),
        .ecg_threshold(ecg_threshold),
        .baud_div(baud_div),
        .ble_enable(ble_enable),
        .uart_enable(uart_enable),
        .soft_reset(soft_reset),
        .sys_busy(sys_busy),
        .sys_done(sys_done),
        .sys_class_code(sys_class_code),
        .sys_overflow(sys_overflow)
    );
    wire pkt_req;
    wire [1:0] result_class;
    demo_apb_seq u_seq (
        .pclk(clk),
        .presetn(demo_rst_n),
        .paddr(apb_paddr[7:0]),
        .psel(apb_psel),
        .penable(apb_penable),
        .pwrite(apb_pwrite),
        .pwdata(apb_pwdata),
        .pready(csr_pready),
        .prdata(csr_prdata),
        .sys_done(sys_done),
        .pkt_req(pkt_req),
        .end_of_data(pace_eod),
        .result_class(result_class)
    );
    wire pkt_tx_start;
    wire [7:0]  pkt_tx_data;
    wire pkt_done_r, pkt_drop_r, pkt_busy_r;
    demo_uart_packetizer u_pz (
        .clk(clk),
        .rst_n(demo_rst_n),
        .pkt_req(pkt_req),
        .win_index(win_index),
        .f0(f_rms), .f1(f_var), .f2(f_peak), .f3(f_zc), .f4(f_ptp),
        .f5(f_crest), .f6(f_half_ratio), .f7(f_max), .f8(f_rr),
        .f9(f_rr_prev), .f10(f_rr_ratio), .f11(f_rr_diff),
        .class_code(result_class),
        .err_adc(adc_overflow),
        .err_feat(feature_overflow),
        .err_mlp(mlp_overflow | pipeline_error),
        .tx_start(pkt_tx_start),
        .tx_data(pkt_tx_data),
        .tx_done_tick(uart_tx_done),
        .pkt_busy(pkt_busy_r),
        .pkt_done(pkt_done_r),
        .pkt_drop(pkt_drop_r)
    );
    uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(demo_rst_n),
        .baud_div(baud_div),
        .tx_data(pkt_tx_data),
        .tx_start(pkt_tx_start),
        .tx_enable(1'b1),
        .tx_busy(uart_tx_busy),
        .tx_done_tick(uart_tx_done),
        .uart_txd(uart_txd)
    );
    assign sys_busy     = ~fsm_idle;
    assign sys_overflow = adc_overflow | feature_overflow | mlp_overflow | pipeline_error;
    reg demo_done_r;
    always @(posedge clk or negedge demo_rst_n) begin
        if (!demo_rst_n) demo_done_r <= 1'b0;
        else if (pkt_done_r) demo_done_r <= 1'b1;
    end
    assign demo_done     = demo_done_r;
    assign demo_overflow = sys_overflow | pkt_drop_r;
    assign demo_class    = sys_class_code;
    assign status_led[0] = sys_done;
    assign status_led[1] = adc_sample_valid;
    assign status_led[2] = window_enable;
    assign status_led[3] = demo_done_r;
endmodule
