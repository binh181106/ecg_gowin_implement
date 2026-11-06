`timescale 1ns / 1ps

module ecg_rom #(
    parameter ROM_WORDS = 2048,
    parameter ROM_DW    = 8,
    parameter ROM_HEX   = "src/ecg_rom.hex"
) (
    input  wire                          clk,
    input  wire [$clog2(ROM_WORDS)-1:0]   rom_addr,
    output wire [ROM_DW-1:0]             rom_out
);

    reg [ROM_DW-1:0] rom [0:ROM_WORDS-1];
    reg [ROM_DW-1:0] rom_out_r;

    initial begin
        $readmemh(ROM_HEX, rom);
    end

    always @(posedge clk) begin
        rom_out_r <= rom[rom_addr];
    end

    assign rom_out = rom_out_r;

endmodule