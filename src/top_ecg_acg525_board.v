`timescale 1ns / 1ps

module top_ecg_acg525_board #(
    parameter integer LED_ACTIVE_LOW = 0
) (
    input  wire       sys_clk,
    input  wire       key0_n,
    output wire       uart_txd,
    output wire [3:0] status_led
);

    reg [7:0]  startup_shift = 8'd0;
    reg [24:0] heartbeat_count = 25'd0;
    reg [2:1]  sticky_stage;

    wire       demo_rst_n;
    wire [3:0] demo_status;
    wire [3:0] debug_led;

    assign demo_rst_n = startup_shift[7];

    always @(posedge sys_clk) begin
        startup_shift   <= {startup_shift[6:0], 1'b1};
        heartbeat_count <= heartbeat_count + 25'd1;
    end

    top_ecg_rom_demo #(
        .CLK_HZ(50_000_000),
        .TARGET_HZ(360),
        .ROM_WORDS(2048),
        .ROM_DW(8),
        .ROM_HEX("src/ecg_rom.hex"),
        .UART_CLKS_PER_BIT(437)
    ) u_demo (
        .sys_clk(sys_clk),
        .sys_rst_n(demo_rst_n),
        .uart_txd(uart_txd),
        .uart_rxd(1'b1),
        .status_led(demo_status),
        .demo_done(),
        .demo_overflow(),
        .demo_class()
    );

    always @(posedge sys_clk or negedge demo_rst_n) begin
        if (!demo_rst_n)
            sticky_stage <= 2'b00;
        else
            sticky_stage <= sticky_stage | demo_status[2:1];
    end

    assign debug_led = {heartbeat_count[24], sticky_stage, demo_rst_n};
    assign status_led = LED_ACTIVE_LOW ? ~debug_led : debug_led;

endmodule