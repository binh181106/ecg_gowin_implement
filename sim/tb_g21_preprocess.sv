`timescale 1ns/1ps
module tb_g21_preprocess;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, enable=1, sample_valid=0, read_en=0;
    reg [7:0] raw=0;
    reg [8:0] read_addr=0;
    wire signed [7:0] frame [0:5], converted [0:5];
    wire [31:0] collected [0:5];
    wire [5:0] ready;
    reg [7:0] expected [0:1535];
    reg [7:0] history [0:767];
    integer checks=0, windows=0, i, g;
    GSR GSR (.GSRI(rst_n));
    generate for(genvar m=0;m<6;m++) begin: DUTS
        localparam MODE=(m<2)?m:2;
        localparam ZERO=(m==2)?0:(m==3)?128:(m==4)?169:255;
        window_buffer #(.PREPROCESS_MODE(MODE),.ADC_ZERO_CODE(ZERO)) dut (
            .clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),.enable(enable),
            .sample_in(raw),.sample_valid(sample_valid),.read_en(read_en),
            .read_addr(read_addr),.frame_out(frame[m]),.window_ready(ready[m]),
            .samples_collected(collected[m]),.ready_bank(),.sample_cnt());
        assign converted[m]=dut.preprocessed_sample;
    end endgenerate
    task automatic check(input bit ok,input string msg);
        checks++;
        assert(ok) else $fatal(1,"PREPROCESS %s",msg);
    endtask
    always @(posedge clk) begin
        #1;
        if(!rst_n || soft_reset) windows=0;
        else begin
            check(ready=={6{ready[0]}},"modes preserve identical window timing");
            if(ready[0]) windows++;
        end
    end
    task automatic push(input [7:0] value);
        @(negedge clk); raw=value; sample_valid=1;
        @(negedge clk); sample_valid=0;
        @(negedge clk);
    endtask
    task automatic read_window(input integer base);
        for(integer n=0;n<512;n++) begin
            @(negedge clk); read_addr=n; read_en=1;
            @(posedge clk); #2;
            for(integer m=0;m<6;m++)
                check(frame[m]===expected[m*256+history[base+n]],
                      $sformatf("RAM mode=%0d sample=%0d got=%0d expected=%0d",m,n,
                       $signed(frame[m]),$signed(expected[m*256+history[base+n]])));
        end
        @(negedge clk); read_en=0;
    endtask
    initial begin
        $readmemh("sim/g21_vectors/conversion.hex",expected);
        repeat(4) @(negedge clk); rst_n=1;
        // Exhaust all unsigned codes against an independent Python truth table.
        for(i=0;i<256;i++) begin
            @(negedge clk); raw=i; #1;
            for(g=0;g<6;g++) check(converted[g]===expected[g*256+i],
                $sformatf("conversion mode=%0d raw=%0d",g,i));
        end
        check(collected[0]==0,"invalid samples do not write");
        // Abort a partially filled window, then start a clean stream.
        for(i=0;i<100;i++) push(i);
        soft_reset=1; @(negedge clk); soft_reset=0;
        check(collected[0]==0 && windows==0,"soft reset clears partial window");
        for(i=0;i<512;i++) begin history[i]=i%256; push(history[i]); end
        check(windows==1 && collected[0]==512,"first ready at sample 512");
        read_window(0);
        enable=0;
        for(i=0;i<8;i++) push(8'hff);
        enable=1;
        check(collected[0]==512,"disabled writes ignored");
        for(i=512;i<768;i++) begin history[i]=(i*37+19)%256; push(history[i]); end
        check(windows==2 && collected[0]==768,"next ready at stride 256");
        read_window(256);
        $display("G21 PREPROCESS PASS checks=%0d modes=6 all_raw_codes=256 overlap_windows=2",checks);
        $finish;
    end
    initial begin #1000000; $fatal(1,"PREPROCESS watchdog"); end
endmodule
