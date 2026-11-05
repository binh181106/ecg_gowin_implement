//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.9 (64-bit)
//Part Number: GW5A-LV25UG324C2/I1
//Device: GW5A-25
//Device Version: A
//Created Time: Thu Nov  5 22:28:44 2026

module Gowin_DPB (douta, doutb, clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb, ada, dina, adb, dinb);

output [15:0] douta;
output [15:0] doutb;
input clka;
input ocea;
input cea;
input reseta;
input wrea;
input clkb;
input oceb;
input ceb;
input resetb;
input wreb;
input [7:0] ada;
input [15:0] dina;
input [7:0] adb;
input [15:0] dinb;

wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;

DPB dpb_inst_0 (
    .DOA(douta[15:0]),
    .DOB(doutb[15:0]),
    .CLKA(clka),
    .OCEA(ocea),
    .CEA(cea),
    .RESETA(reseta),
    .WREA(wrea),
    .CLKB(clkb),
    .OCEB(oceb),
    .CEB(ceb),
    .RESETB(resetb),
    .WREB(wreb),
    .BLKSELA({gw_gnd,gw_gnd,gw_gnd}),
    .BLKSELB({gw_gnd,gw_gnd,gw_gnd}),
    .ADA({gw_gnd,gw_gnd,ada[7:0],gw_gnd,gw_gnd,gw_vcc,gw_vcc}),
    .DIA(dina[15:0]),
    .ADB({gw_gnd,gw_gnd,adb[7:0],gw_gnd,gw_gnd,gw_vcc,gw_vcc}),
    .DIB(dinb[15:0])
);

defparam dpb_inst_0.READ_MODE0 = 1'b1;
defparam dpb_inst_0.READ_MODE1 = 1'b0;
defparam dpb_inst_0.WRITE_MODE0 = 2'b00;
defparam dpb_inst_0.WRITE_MODE1 = 2'b00;
defparam dpb_inst_0.BIT_WIDTH_0 = 16;
defparam dpb_inst_0.BIT_WIDTH_1 = 16;
defparam dpb_inst_0.BLK_SEL_0 = 3'b000;
defparam dpb_inst_0.BLK_SEL_1 = 3'b000;
defparam dpb_inst_0.RESET_MODE = "SYNC";
defparam dpb_inst_0.INIT_RAM_00 = 256'h7FFF045B01DD07FEFFFF10840C9A0C9960350E882BCE7FFF00277D6D582C34EE;
defparam dpb_inst_0.INIT_RAM_01 = 256'h0316FC1105760047FB37F68CFE6F0A3151A3357A49AC4A070406344C0E0102C5;
defparam dpb_inst_0.INIT_RAM_02 = 256'h0BF7E522FFD709C3E82101C4051B05D90CE3F3770745F4E6CAA21E03F4E8D75D;
defparam dpb_inst_0.INIT_RAM_03 = 256'hFD3F0C350687F5BE0D24F61CF0F3F75F132000EBFEE7FB7AFD60F374E377107B;
defparam dpb_inst_0.INIT_RAM_04 = 256'h05E300F5F8D3DB2B05D714A7F496F819D93B2BFFF848DA29FB98FDDEFB2CF81D;
defparam dpb_inst_0.INIT_RAM_05 = 256'hFD68FDEEEE3DEE0DF722F24308DFFA95F85DF8A2106706480F35DB5402FD0C30;
defparam dpb_inst_0.INIT_RAM_06 = 256'h00A203B1FD0BFE01F82A2FDC23991EB9FEA3FFE1FDCBFE44002C024400A5FDF0;
defparam dpb_inst_0.INIT_RAM_07 = 256'h4D1245D0FDD7039F295DF900F6C5E0ABE4F3FC25E247D51A005A000AFE5AFD07;
defparam dpb_inst_0.INIT_RAM_08 = 256'h07F69C16FEE9F15D15791228066AF5151E07079917C50B8ACDC31095F030DADC;
defparam dpb_inst_0.INIT_RAM_09 = 256'hFDB61875F13DE1282172E2C5148832E19E610DFF08F31C0AF197FBCDF041FFFC;
defparam dpb_inst_0.INIT_RAM_0A = 256'h000000000000000000000000000000000000000000000000DD9E1166EF6A28F1;

endmodule //Gowin_DPB
