`timescale 1ns/1ps
module tb_g1_reset;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0;
    wire tx, overflow;
    top_ecg_rom_demo #(.CLK_HZ(50_000_000), .TARGET_HZ(20_000),
        .ROM_HEX("src/ecg_rom.hex")) dut (.sys_clk(clk), .sys_rst_n(rst_n),
        .uart_txd(tx), .uart_rxd(1'b1), .status_led(), .demo_done(),
        .demo_overflow(overflow), .demo_class());
    defparam dut.u_ctrl_fsm.MLP_TIMEOUT=220;
    GSR GSR (.GSRI(rst_n));
    `include "src/golden/expected_packets.sv"
    reg bus_sel=0, bus_en=0;
    integer results=0, requests=0, bytes=0, checks=0;
    integer b;
    reg [7:0] received;
    task automatic check(input bit ok, input string msg);
        checks++;
        assert(ok) else $fatal(1,"RESET: %s",msg);
    endtask
    // Testbench takeover issues a real APB reset write at accepted ACCESS.
    task reset_via_apb;
        @(negedge clk);
        force dut.apb_psel=bus_sel;
        force dut.apb_penable=bus_en;
        force dut.apb_pwrite=1'b1;
        force dut.apb_paddr=32'd0;
        force dut.apb_pwdata=32'h11;
        bus_sel=1; bus_en=0;
        @(negedge clk); bus_en=1;
        @(posedge clk);
        while(!dut.csr_pready) @(posedge clk);
        #1; check(dut.soft_reset,"accepted reset write");
        @(negedge clk); bus_sel=0; bus_en=0;
        release dut.apb_psel; release dut.apb_penable; release dut.apb_pwrite;
        release dut.apb_paddr; release dut.apb_pwdata;
        @(posedge clk); #1;
        check(dut.u_ctrl_fsm.state==0 && !dut.u_ctrl_fsm.feat_started &&
              dut.u_feature.state==0 && dut.u_ai.state==0,"all processing stages aborted");
        check(!dut.pkt_busy_r && !dut.mlp_start && !dut.sys_done && !overflow,
              "no stale UART/result/error after reset");
        check(dut.win_index==0 && dut.u_window.samples_collected==0 &&
              dut.u_adc_if.sample_count==0,"ROM/sample/window numbering restarts");
    endtask
    always @(posedge clk) if(rst_n) begin
        if(dut.sys_done) results++;
        if(dut.pkt_req) requests++;
    end
    initial forever begin
        @(negedge tx); #(437*20/2);
        assert(tx===0) else $fatal(1,"RESET UART start");
        for(b=0;b<8;b++) begin #(437*20); received[b]=tx; end
        #(437*20);
        assert(tx===1) else $fatal(1,"RESET UART stop");
        check(bytes<33 && received===exp_pkt[0][bytes],"fresh first golden packet after recovery");
        bytes++;
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        wait(dut.feat_read_en); repeat(30) @(negedge clk);
        reset_via_apb();
        wait(dut.mlp_start); repeat(25) @(negedge clk);
        reset_via_apb();
        check(results==0 && requests==0,"aborted features/MLP cannot emit packets");
        // Hide real MLP completion to exercise top-level error visibility.
        force dut.mlp_done=1'b0;
        wait(dut.pipeline_error); repeat(20) @(negedge clk);
        check(overflow && dut.sys_overflow && !dut.sys_done && requests==0,
              "timeout visible at top/CSR, never a success packet");
        release dut.mlp_done;
        reset_via_apb();
        wait(dut.pkt_done_r); repeat(20) @(negedge clk);
        check(results==1 && requests==1 && bytes==33 && !overflow,"one recovered inference and packet");
        $display("G1 RESET PASS checks=%0d feature_abort=1 mlp_abort=1 timeout=1 recovered_packets=1",checks);
        $finish;
    end
    initial begin #150000000; $fatal(1,"RESET watchdog"); end
endmodule
