`timescale 1ns/1ps
module tb_g22_reset_faults;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, start=0;
    reg [7:0] sample=0, memory[0:511];
    wire [8:0] addr;
    wire read_en, valid, overflow;
    wire signed [15:0] f[0:11];
    reg signed [63:0] injected_variance;
    reg [27:0] injected_quotient;
    reg signed [63:0] injected_energy;
    integer checks=0, completed=0, aborted=0, faults=0;
    feature_extraction dut (.clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),
        .start_compute(start),.ecg_threshold(16'd80),.read_enable(1'b0),
        .sample_addr(addr),.sample_in(sample),.read_en(read_en),
        .f_rms(f[0]),.f_var(f[1]),.f_peak(f[2]),.f_zc(f[3]),.f_ptp(f[4]),
        .f_crest(f[5]),.f_half_ratio(f[6]),.f_max(f[7]),.f_rr(f[8]),
        .f_rr_prev(f[9]),.f_rr_ratio(f[10]),.f_rr_diff(f[11]),
        .feature_valid(valid),.overflow(overflow));
    always @(posedge clk) if(read_en) sample<=memory[addr];
    task automatic check(input bit ok,input string msg);
        checks++;
        assert(ok) else $fatal(1,"RESET/FAULT %s",msg);
    endtask
    task automatic fill(input [7:0] value);
        for(integer i=0;i<512;i++) memory[i]=value;
    endtask
    task launch;
        @(negedge clk); start=1; @(negedge clk); start=0;
        check(!overflow,"accepted new start clears previous fault");
    endtask
    task automatic wait_stage(input integer stage,input integer count);
        integer cycles;
        cycles=0;
        while(!(dut.state==stage && (count<0 ||
              (stage==dut.S_CALC_SQRT ? dut.sq_cnt==count : dut.div_cnt==count))) && cycles<2000) begin
            @(negedge clk); cycles++;
        end
        check(cycles<2000,"reached requested arithmetic stage");
    endtask
    task automatic finish_window(input bit fault_expected);
        integer cycles;
        cycles=0;
        while(!valid && cycles<2000) begin @(negedge clk); cycles++; end
        check(valid && overflow==fault_expected,"completion and arithmetic status");
        completed++;
        @(negedge clk); check(!valid,"no duplicate valid");
    endtask
    task reset_soft;
        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0;
        check(dut.state==dut.S_IDLE && !read_en && !valid && !overflow &&
              dut.sq_cnt==0 && dut.div_cnt==0 && dut.rms_reg==0 && dut.abs_peak_reg==0,
              "soft reset clears arithmetic and fault state");
        repeat(35) begin @(negedge clk); check(!valid,"aborted computation cannot complete"); end
    endtask
    task recover_negative_constant;
        fill(-8'sd10); launch(); finish_window(0);
        check(f[0]==10 && f[1]==0 && f[2]==-10 && f[3]==0 && f[4]==0 && f[5]==256 &&
              f[6]==0 && f[7]==-10 && f[8]==0 && f[9]==0 && f[10]==4096 && f[11]==0,
              "all twelve features recover correctly");
    endtask
    task automatic variance_fault(input longint signed numerator,input integer expected,input bit bad);
        fill(10); launch(); wait_stage(dut.S_CALC_VAR,-1);
        injected_variance=numerator; force dut.var_num=injected_variance;
        @(posedge clk); #1;
        check(f[1]==expected && overflow==bad,"variance guard before signed narrowing");
        @(negedge clk); release dut.var_num;
        finish_window(bad);
        check(overflow==bad,"fault retained until result is consumed");
        faults++; recover_negative_constant();
    endtask
    task automatic crest_fault(input [27:0] quotient,input integer expected,input bit bad);
        fill(10); launch(); wait_stage(dut.S_DIV_CREST,29);
        injected_quotient=quotient; force dut.div_quot=injected_quotient;
        @(posedge clk); #1;
        check(f[5]==expected && overflow==bad,"full 28-bit quotient guard");
        @(negedge clk); release dut.div_quot;
        finish_window(bad); faults++; recover_negative_constant();
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        // Reset real computations during sqrt, crest division and RR division.
        for(integer stage=0;stage<3;stage++) begin
            fill(0); memory[10]=100; memory[30]=100; memory[60]=100;
            launch();
            if(stage==0) wait_stage(dut.S_CALC_SQRT,7);
            if(stage==1) wait_stage(dut.S_DIV_CREST,14);
            if(stage==2) wait_stage(dut.S_DIV_RR,14);
            check(!valid,"reset while computation still active");
            reset_soft(); aborted++; recover_negative_constant();
        end
        // Explicitly NONPHYSICAL fault injection: these numerators/quotients
        // cannot arise from a legal int8 window. Verify defensive saturation.
        variance_fault(-64'sd1,0,1);
        variance_fault(64'sd8589934591,32767,0);
        variance_fault(64'sd8589934592,32767,1);
        crest_fault(28'd32767,32767,0);
        crest_fault(28'd32768,32767,1);
        crest_fault(28'd65536,32767,1); // high bit set, low16=0 must not wrap
        crest_fault(28'h8000000,32767,1);
        // Energy bound violations are flagged independently of variance.
        injected_energy=64'sd8388609; force dut.sum_square=injected_energy;
        @(negedge clk); check(overflow,"energy above 2^23 detected");
        release dut.sum_square; reset_soft(); faults++;
        injected_energy=-64'sd1; force dut.sum_square=injected_energy;
        @(negedge clk); check(overflow,"negative energy detected");
        release dut.sum_square; reset_soft(); faults++;
        recover_negative_constant();
        $display("G22 RESET FAULTS PASS checks=%0d reset_stages=%0d defensive_cases=%0d recovered_completions=%0d",checks,aborted,faults,completed);
        $finish;
    end
    initial begin #3000000; $fatal(1,"RESET/FAULT watchdog"); end
endmodule
