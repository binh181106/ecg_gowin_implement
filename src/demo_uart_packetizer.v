`timescale 1ns / 1ps
module demo_uart_packetizer (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             pkt_req,
    input  wire [15:0]      win_index,
    input  wire signed [15:0] f0,
    input  wire signed [15:0] f1,
    input  wire signed [15:0] f2,
    input  wire signed [15:0] f3,
    input  wire signed [15:0] f4,
    input  wire signed [15:0] f5,
    input  wire signed [15:0] f6,
    input  wire signed [15:0] f7,
    input  wire signed [15:0] f8,
    input  wire signed [15:0] f9,
    input  wire signed [15:0] f10,
    input  wire signed [15:0] f11,
    input  wire [1:0]       class_code,
    input  wire             err_adc,
    input  wire             err_feat,
    input  wire             err_mlp,
    output reg              tx_start,
    output reg       [7:0]  tx_data,
    input  wire             tx_done_tick,
    output reg              pkt_busy,
    output reg              pkt_done,
    output reg              pkt_drop
);
    localparam [7:0] SYNC1 = 8'hE7;
    localparam [7:0] SYNC2 = 8'hA5;
    localparam [7:0] TYPE  = 8'h01;
    localparam [7:0] LEN   = 8'd28;
    localparam [5:0] LAST  = 6'd32;
    reg [15:0]      w_idx;
    reg  [7:0]      lf8 [0:23];
    reg [1:0]       l_class;
    reg [2:0]       l_flags;
    reg [5:0]       pump_idx;
    reg             pumping;
    function [7:0] byte_at;
        input [5:0] n;
        begin
            case (n)
                6'd0:  byte_at = SYNC1;
                6'd1:  byte_at = SYNC2;
                6'd2:  byte_at = TYPE;
                6'd3:  byte_at = LEN;
                6'd4:  byte_at = w_idx[7:0];
                6'd5:  byte_at = w_idx[15:8];
                6'd30: byte_at = {6'd0, l_class};
                6'd31: byte_at = {5'd0, l_flags};
                6'd32: byte_at = 8'd0;
                default: byte_at = lf8[(n - 6'd6)];
            endcase
        end
    endfunction
    wire [31:0] chk_sum =
        {24'd0, TYPE}
      + {24'd0, LEN}
      + {24'd0, w_idx[7:0]}  + {24'd0, w_idx[15:8]}
      + {24'd0, lf8[0]} + {24'd0, lf8[1]}
      + {24'd0, lf8[2]} + {24'd0, lf8[3]}
      + {24'd0, lf8[4]} + {24'd0, lf8[5]}
      + {24'd0, lf8[6]} + {24'd0, lf8[7]}
      + {24'd0, lf8[8]} + {24'd0, lf8[9]}
      + {24'd0, lf8[10]}+ {24'd0, lf8[11]}
      + {24'd0, lf8[12]}+ {24'd0, lf8[13]}
      + {24'd0, lf8[14]}+ {24'd0, lf8[15]}
      + {24'd0, lf8[16]}+ {24'd0, lf8[17]}
      + {24'd0, lf8[18]}+ {24'd0, lf8[19]}
      + {24'd0, lf8[20]}+ {24'd0, lf8[21]}
      + {24'd0, lf8[22]}+ {24'd0, lf8[23]}
      + {28'd0, 4'd0} + 32'd0
      + {30'd0, l_class}
      + {29'd0, l_flags};
    wire [7:0] chk_byte = chk_sum[7:0];
integer reset_byte_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pkt_busy   <= 1'b0;
            pkt_done   <= 1'b0;
            pkt_drop   <= 1'b0;
            tx_start   <= 1'b0;
            tx_data    <= 8'd0;
            pumping    <= 1'b0;
            pump_idx   <= 6'd0;
            w_idx      <= 16'd0;
            l_class    <= 2'd0;
            l_flags    <= 3'd0;
            for (reset_byte_idx = 0; reset_byte_idx < 24; reset_byte_idx = reset_byte_idx + 1) lf8[reset_byte_idx] <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            pkt_done <= 1'b0;
            if (pkt_req && pkt_busy)
                pkt_drop <= 1'b1;
            if (pkt_req && !pkt_busy) begin
                w_idx   <= win_index;
                l_class <= class_code;
                l_flags <= {err_mlp, err_feat, err_adc};
                lf8[0]  <= f0[7:0];   lf8[1]  <= f0[15:8];
                lf8[2]  <= f1[7:0];   lf8[3]  <= f1[15:8];
                lf8[4]  <= f2[7:0];   lf8[5]  <= f2[15:8];
                lf8[6]  <= f3[7:0];   lf8[7]  <= f3[15:8];
                lf8[8]  <= f4[7:0];   lf8[9]  <= f4[15:8];
                lf8[10] <= f5[7:0];   lf8[11] <= f5[15:8];
                lf8[12] <= f6[7:0];   lf8[13] <= f6[15:8];
                lf8[14] <= f7[7:0];   lf8[15] <= f7[15:8];
                lf8[16] <= f8[7:0];   lf8[17] <= f8[15:8];
                lf8[18] <= f9[7:0];   lf8[19] <= f9[15:8];
                lf8[20] <= f10[7:0];  lf8[21] <= f10[15:8];
                lf8[22] <= f11[7:0];  lf8[23] <= f11[15:8];
                pump_idx <= 6'd0;
                pumping  <= 1'b1;
                tx_start <= 1'b1;
                tx_data  <= byte_at(6'd0);
                pkt_busy <= 1'b1;
            end else if (pumping) begin
                if (tx_done_tick) begin
                    if (pump_idx == LAST) begin
                        pumping  <= 1'b0;
                        pkt_busy <= 1'b0;
                        pkt_done <= 1'b1;
                    end else begin
                        pump_idx <= pump_idx + 6'd1;
                        tx_start <= 1'b1;
                        tx_data  <= (pump_idx + 6'd1) == LAST ? chk_byte
                                                               : byte_at(pump_idx + 6'd1);
                    end
                end
            end
        end
    end
endmodule
