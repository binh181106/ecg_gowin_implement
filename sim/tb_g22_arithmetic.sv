`timescale 1ns/1ps
module tb_g22_arithmetic;
    `include "sim/g22_vectors/counts.svh"
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, start=0;
    reg [7:0] sample=0;
    wire [8:0] addr;
    wire read_en, valid, overflow;
    wire signed [15:0] f[0:11];
    reg [7:0] samples[0:NUM_CASES*512-1];
    reg [15:0] expected[0:NUM_CASES*12-1];
    reg [63:0] internals[0:NUM_CASES*6-1];
    integer case_id=0, consumed=0, sqrt_steps=0, div_steps=0, elapsed=0;
    integer checks=0, n, cycles;
    bit tracking=0;
    longint unsigned prefix_value, root_value, quotient_value;
    feature_extraction dut (.clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),
        .start_compute(start),.ecg_threshold(16'd80),.read_enable(1'b0),
        .sample_addr(addr),.sample_in(sample),.read_en(read_en),
        .f_rms(f[0]),.f_var(f[1]),.f_peak(f[2]),.f_zc(f[3]),.f_ptp(f[4]),
        .f_crest(f[5]),.f_half_ratio(f[6]),.f_max(f[7]),.f_rr(f[8]),
        .f_rr_prev(f[9]),.f_rr_ratio(f[10]),.f_rr_diff(f[11]),
        .feature_valid(valid),.overflow(overflow));
    always @(posedge clk) if(read_en) sample<=samples[case_id*512+addr];
    task automatic check(input bit ok,input string msg);
        checks++;
        assert(ok) else $fatal(1,"ARITH case=%0d %s",case_id,msg);
    endtask
    always @(posedge clk) if(rst_n && !soft_reset) begin
        if(start && dut.state==dut.S_IDLE) begin
            tracking=1; elapsed=0; consumed=0; sqrt_steps=0; div_steps=0;
        end else if(tracking) elapsed++;
        if(dut.state==dut.S_ACCUMULATE_READ) begin
            check(sample===samples[case_id*512+consumed],"exact consumed sample order");
            consumed++;
        end
        if(dut.state==dut.S_CALC_VAR) begin
            check(dut.sum===internals[case_id*6][31:0],"signed sum");
            check(dut.sum_square===internals[case_id*6+1],"energy includes final sample");
            check(dut.var_num===internals[case_id*6+2],"wide population variance numerator");
            check(dut.abs_peak_reg===internals[case_id*6+3][7:0],"absolute peak including -128 and final sample");
        end
        if(dut.state==dut.S_CALC_SQRT) begin
            root_value=dut.sq_root;
            prefix_value=(internals[case_id*6+1]*128) >> (32-2*dut.sq_cnt);
            check(root_value*root_value+dut.sq_rem==prefix_value,"sqrt prefix/remainder invariant");
            check(dut.sq_rem<=2*root_value,"sqrt floor bound");
            if(dut.sq_cnt<16) sqrt_steps++;
            else check(dut.sq_root===internals[case_id*6+4][15:0],"final Q8.8 root");
        end
        if(dut.state==dut.S_DIV_CREST) begin
            check(dut.rms_reg===internals[case_id*6+4][15:0],"internal fractional RMS");
            if(dut.div_cnt>=1 && dut.div_cnt<=28) begin
                div_steps++;
                check(dut.div_rem<dut.div_divisor,"divider remainder bound");
            end
            if(dut.div_cnt>28) begin
                quotient_value=dut.div_quot;
                check(quotient_value==internals[case_id*6+3]*65536/internals[case_id*6+4],
                      "all 28 crest quotient bits");
                check(quotient_value*dut.div_divisor+dut.div_rem==internals[case_id*6+3]*65536,
                      "division Euclidean identity");
            end
        end
        if(dut.state==dut.S_DONE) tracking=0;
    end
    initial begin
        $readmemh("sim/g22_vectors/samples.hex",samples);
        $readmemh("sim/g22_vectors/features.hex",expected);
        $readmemh("sim/g22_vectors/internals.hex",internals);
        repeat(4) @(negedge clk); rst_n=1;
        // Consecutive windows without reset also detect stale accumulators/peak.
        for(case_id=0;case_id<NUM_CASES;case_id++) begin
            @(negedge clk); start=1; @(negedge clk); start=0;
            cycles=0;
            while(!valid && cycles<2000) begin @(negedge clk); cycles++; end
            check(valid && !overflow && consumed==512,"one complete legal window");
            check(sqrt_steps==16,"exactly sixteen sqrt iterations");
            check(div_steps==(internals[case_id*6+4] ? 28 : 0),"crest divider iteration count");
            check(elapsed==internals[case_id*6+5],$sformatf("latency got=%0d expected=%0d",elapsed,internals[case_id*6+5]));
            for(n=0;n<12;n++) check(f[n]===expected[case_id*12+n],
                $sformatf("feature=%0d got=%0d expected=%0d",n,f[n],$signed(expected[case_id*12+n])));
            check(f[1]>=0 && f[5]>=0,"variance and crest nonnegative");
            @(negedge clk); check(!valid,"single-cycle valid");
        end
        $display("G22 ARITHMETIC PASS cases=%0d checks=%0d internal_sqrt_divider_latency=PASS",NUM_CASES,checks);
        $finish;
    end
    initial begin #20000000; $fatal(1,"ARITH watchdog"); end
endmodule
