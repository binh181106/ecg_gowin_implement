`timescale 1ns/1ps
module tb_g1_seq;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, sys_done=0, end_of_data=0;
    wire [7:0] addr;
    wire [31:0] wdata;
    wire sel, en, wr, req;
    wire [1:0] result_class;
    integer waits=0, accepted=0, reads=0, writes=0, requests=0;
    integer wait_target=0;
    // Legal slave behavior: PREADY high in SETUP, including before writes.
    wire ready = !en || (waits>=wait_target);
    wire [31:0] rdata = sel && !wr ? 32'd3 : 32'd0;
    demo_apb_seq dut (.pclk(clk), .presetn(rst_n), .paddr(addr),
        .psel(sel), .penable(en), .pwrite(wr), .pwdata(wdata),
        .pready(ready), .prdata(rdata), .sys_done(sys_done),
        .end_of_data(end_of_data),
        .pkt_req(req), .result_class(result_class));
    reg was_sel=0, was_en=0, was_ready=0, was_wr=0, was_req=0;
    reg [7:0] was_addr=0;
    reg [31:0] was_data=0;
    always @(posedge clk) if (rst_n) begin
        if(!en) waits<=0;
        else if(!ready) waits<=waits+1;
        if(was_sel && !was_en)
            assert(sel && en && addr==was_addr && wr==was_wr && wdata==was_data)
                else $fatal(1,"SEQ skipped ACCESS when PREADY high during SETUP");
        if(was_sel && was_en && !was_ready)
            assert(sel && en && addr==was_addr && wr==was_wr && wdata==was_data)
                else $fatal(1,"SEQ changed transfer while waiting");
        if(sel && en && ready) begin
            accepted++;
            wait_target<=accepted%3;
            if(wr) begin
                writes++;
                if(writes==2) assert(addr==8'h0c && wdata==437)
                    else $fatal(1,"SEQ bad BAUD transfer");
                else assert(addr==0 && wdata==3)
                    else $fatal(1,"SEQ bad CTRL transfer");
            end else begin
                reads++;
                assert(addr==8'h10) else $fatal(1,"SEQ bad RESULT address");
            end
        end
        if(req) begin
            requests++;
            assert(!was_req && result_class==3 && rdata==0)
                else $fatal(1,"SEQ result snapshot/pulse incorrect after PRDATA clears");
        end
        was_sel<=sel; was_en<=en; was_ready<=ready; was_wr<=wr;
        was_addr<=addr; was_data<=wdata; was_req<=req;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        // Completion during bring-up must be retained.
        @(negedge clk); sys_done=1; @(negedge clk); sys_done=0;
        wait(requests==1); wait(writes==3);
        @(negedge clk); sys_done=1; @(negedge clk); sys_done=0;
        wait(requests==2); wait(writes==4);
        repeat(20) @(negedge clk);
        assert(reads==2 && requests==2 && writes==4 && accepted==6)
            else $fatal(1,"SEQ counts accepted=%0d requests=%0d",accepted,requests);
        // The final result still transmits, but cannot restart an empty ROM.
        end_of_data=1; sys_done=1; @(negedge clk); sys_done=0;
        wait(requests==3); repeat(20) @(negedge clk);
        assert(reads==3 && writes==4 && accepted==7)
            else $fatal(1,"SEQ restarted after end of ROM");
        $display("G1 SEQ PASS accepted=%0d reads=%0d writes=%0d requests=%0d",accepted,reads,writes,requests);
        $finish;
    end
    initial begin #100000; $fatal(1,"SEQ watchdog"); end
endmodule
