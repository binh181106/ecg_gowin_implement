`timescale 1ns/1ps
module tb_g1_apb;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, psel=0, penable=0, pwrite=0;
    reg [7:0] paddr=0;
    reg [31:0] pwdata=0;
    wire [31:0] prdata;
    wire pready, pslverr, irq, enable, start, reset_soft, ble, uart;
    wire [15:0] threshold, baud;
    reg sys_done=0;
    reg [1:0] class_code=0;
    integer starts=0, resets=0, checks=0, transfers=0;
    reg prev_start=0, prev_reset=0;
    apb_slave_if dut (.pclk(clk), .presetn(rst_n), .paddr(paddr),
        .psel(psel), .penable(penable), .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr), .p_irq(irq),
        .sys_enable(enable), .sys_start(start), .soft_reset(reset_soft),
        .ecg_threshold(threshold), .baud_div(baud), .ble_enable(ble),
        .uart_enable(uart), .sys_busy(1'b1), .sys_done(sys_done),
        .sys_class_code(class_code), .sys_overflow(1'b1));
    task automatic check(input bit ok, input string msg);
        checks++;
        assert(ok) else $fatal(1,"APB: %s",msg);
    endtask
    always @(posedge clk) if(rst_n) begin
        assert(!(prev_start && start)) else $fatal(1,"SYS_START not one cycle");
        assert(!(prev_reset && reset_soft)) else $fatal(1,"soft reset not one cycle");
        prev_start<=start; prev_reset<=reset_soft;
        if(start) starts++;
        if(reset_soft) resets++;
        if(psel && penable && pready) transfers++;
    end
    // Leaves PSEL asserted for true back-to-back transfers. Sample BEFORE NBA,
    // at the same rising edge as an APB master would, never one edge later.
    task automatic transfer(input bit wr, input [7:0] addr, input [31:0] data,
                            output reg [31:0] result);
        integer waits;
        @(negedge clk); psel=1; penable=0; pwrite=wr; paddr=addr; pwdata=data;
        @(negedge clk); penable=1; waits=0;
        @(posedge clk);
        while(pready!==1) begin
            waits++;
            if(waits>8) $fatal(1,"APB wait watchdog");
            @(posedge clk);
        end
        result=prdata;
        check(!pslverr,"no unexpected slave error");
        check(waits==1,"registered PREADY inserts one ACCESS wait cycle");
    endtask
    reg [31:0] rd;
    integer c;
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        // An extended/aborted SETUP must have no write side effect.
        @(negedge clk); psel=1; pwrite=1; paddr=0; pwdata=32'h13;
        repeat(3) @(negedge clk);
        check(!enable && !start && !reset_soft,"SETUP cannot write CTRL");
        psel=0; repeat(2) @(negedge clk);
        // Also prove the first, unaccepted ACCESS edge cannot write.
        psel=1; paddr=8'h08; pwdata=123;
        @(negedge clk); penable=1;
        @(posedge clk); check(!pready,"first ACCESS is not accepted");
        #1; check(threshold==80,"wait-state edge cannot commit write");
        @(posedge clk); check(pready,"next ACCESS is accepted");
        #1; check(threshold==123,"write commits at acceptance");
        @(negedge clk); penable=0;
        transfer(0,8'h08,0,rd); check(rd==123,"threshold readback");
        transfer(0,8'h18,0,rd); check(rd==2 && uart,"CONFIG reset readback");
        transfer(1,0,7,rd); transfer(1,0,7,rd); transfer(1,0,7,rd);
        transfer(0,0,0,rd); check(rd==5 && enable,"CTRL strobe bits self clear");
        check(starts==3,"three repeated CTRL writes produce three starts");
        transfer(1,8'h0c,16'd434,rd); transfer(0,8'h0c,0,rd);
        check(rd==434 && baud==434,"BAUD back-to-back write/read");
        transfer(1,8'h18,1,rd); transfer(0,8'h18,0,rd);
        check(rd==1 && ble && !uart,"CONFIG write/read");
        for(c=0;c<4;c++) begin
            class_code=c;
            transfer(0,8'h10,0,rd); check(rd==c,"class sampled at accepted read edge");
        end
        transfer(0,8'h14,0,rd); check(rd==32'h200,"VERSION");
        sys_done=1; transfer(0,8'h04,0,rd); check(rd==11 && irq,"STATUS and IRQ");
        sys_done=0;
        transfer(1,0,32'h11,rd); transfer(1,0,32'h11,rd);
        transfer(0,0,0,rd); check(rd==1 && resets==2,"consecutive soft-reset strobes");
        @(negedge clk); psel=0; penable=0; repeat(3) @(negedge clk);
        check(prdata==0 && !pready && !irq,"idle bus outputs");
        $display("G1 APB PASS checks=%0d transfers=%0d starts=%0d resets=%0d",checks,transfers,starts,resets);
        $finish;
    end
    initial begin #100000; $fatal(1,"APB watchdog"); end
endmodule
