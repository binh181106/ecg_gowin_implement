`timescale 1ns / 1ps
// ACG525 minimal pin wrapper for the EXISTING ECG ROM demo.
// Does not modify ECG feature math, AI weights, APB, or UART protocol.
//
// Pin list (user-provided ACG525 table):
//   50 MHz clock T9, KEY0 B16, UART TX V8,
//   LED0 D14, LED1 C14, LED2 B9, LED3 A9.
// KEY0 is assumed to be active-low (verify on your exact board).
// LED_ACTIVE_LOW can be changed after verifying actual LED polarity.
//
// Sticky LEDs after KEY0 reset:
//   LED0: first 512-sample window became ready
//   LED1: first feature vector became valid
//   LED2: first MLP inference completed (zero weights)
//   LED3: first complete UART packet transmitted
// These LEDs do NOT count 7 packets. Use UART capture for that.
//
// IMPORTANT: the model uses placeholder zero weights by design.
// It demonstrates pipeline transport, NOT real ECG classification.
module top_ecg_acg525_board #(
    parameter integer LED_ACTIVE_LOW = 0
) (
    input  wire       sys_clk,
    input  wire       key0_n,
    output wire       uart_txd,
    output wire [3:0] status_led
);
    wire [3:0] demo_status;
    wire       first_packet_done;

    top_ecg_rom_demo #(
        .CLK_HZ(50_000_000),
        .TARGET_HZ(360),
        .ROM_WORDS(2048),
        .ROM_DW(8),
        .ROM_HEX("ecg_rom.hex"),
        .UART_CLKS_PER_BIT(437)
    ) u_demo (
        .sys_clk(sys_clk),
        .sys_rst_n(key0_n),
        .uart_txd(uart_txd),
        .uart_rxd(1'b1),        // Not needed for ROM-only demo
        .status_led(demo_status),
        .demo_done(first_packet_done),
        .demo_overflow(),
        .demo_class()
    );

    reg [3:0] sticky_stage;
    always @(posedge sys_clk or negedge key0_n) begin
        if (!key0_n)
            sticky_stage <= 4'b0000;
        else
            sticky_stage <= sticky_stage | {
                first_packet_done, // LED3: UART packet sent
                demo_status[0],   // LED2: sys_done / MLP result
                demo_status[2],   // LED1: feature_valid
                demo_status[1]    // LED0: window_ready
            };
    end

    assign status_led = LED_ACTIVE_LOW ? ~sticky_stage : sticky_stage;
endmodule
