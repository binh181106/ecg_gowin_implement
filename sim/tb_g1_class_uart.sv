`timescale 1ns/1ps
module tb_g1_class_uart;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, stimulus_done=0;
    reg [1:0] stimulus_class=0;
    wire tx;
    top_ecg_rom_demo #(.ROM_HEX("src/ecg_rom.hex"), .PREPROCESS_MODE(0)) dut (
        .sys_clk(clk), .sys_rst_n(rst_n), .uart_txd(tx), .uart_rxd(1'b1),
        .status_led(), .demo_done(), .demo_overflow(), .demo_class());
    GSR GSR (.GSRI(rst_n));
    reg [7:0] expected [0:32];
    reg [7:0] received, checksum;
    integer bytes=0, requests=0, packets=0, checks=0, b, c;
    localparam integer BIT_NS=437*20;
    // Isolate completion-to-UART transport; inference is tested separately.
    initial begin
        force dut.sys_done=stimulus_done;
        force dut.sys_class_code=stimulus_class;
    end
    always @(posedge clk) if(rst_n) begin
        if(dut.pkt_req) begin
            assert(!dut.pkt_busy_r) else $fatal(1,"CLASS packet overlap");
            requests++;
            expected[0]=8'he7; expected[1]=8'ha5; expected[2]=1; expected[3]=28;
            expected[4]=dut.win_index[7:0]; expected[5]=dut.win_index[15:8];
            for(integer k=0;k<24;k++) expected[k+6]=dut.features_flat[k*8+:8];
            expected[30]={6'd0,stimulus_class}; expected[31]=0;
            checksum=0;
            for(integer k=2;k<=31;k++) checksum=checksum+expected[k];
            expected[32]=checksum;
        end
        if(dut.pkt_done_r) packets++;
    end
    initial forever begin
        @(negedge tx); #(BIT_NS/2);
        assert(tx===0) else $fatal(1,"CLASS UART start");
        for(b=0;b<8;b++) begin #(BIT_NS); received[b]=tx; end
        #(BIT_NS);
        assert(tx===1) else $fatal(1,"CLASS UART stop");
        checks++;
        assert(received===expected[bytes%33])
            else $fatal(1,"CLASS transport class=%0d byte=%0d actual=%02h expected=%02h",
                        stimulus_class,bytes%33,received,expected[bytes%33]);
        bytes++;
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(30) @(negedge clk);
        for(c=0;c<4;c++) begin
            stimulus_class=c; stimulus_done=1;
            @(negedge clk); stimulus_done=0;
            wait(packets==c+1);
            repeat(20) @(negedge clk);
            assert(bytes==33*(c+1)) else $fatal(1,"CLASS packet length");
        end
        assert(requests==4 && packets==4 && bytes==132) else $fatal(1,"CLASS duplicate/missing packets");
        $display("G1 CLASS UART PASS classes=0,1,2,3 checks=%0d packets=4 bytes=132",checks);
        $finish;
    end
    initial begin #20000000; $fatal(1,"CLASS watchdog"); end
endmodule
