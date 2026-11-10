`timescale 1ns/1ps
module tb_g21_signed_features;
    `include "sim/g21_vectors/counts.svh"
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, sample_valid=0, start=0;
    reg [7:0] raw=128;
    wire [8:0] addr;
    wire read_en, valid, overflow;
    wire signed [7:0] sample;
    wire signed [15:0] f[0:11];
    reg [7:0] raw_expected[0:NUM_CASES*512-1], signed_expected[0:NUM_CASES*512-1];
    reg [15:0] feature_expected[0:NUM_CASES*12-1];
    integer case_id=0, checks=0, consumed=0, i, cycles, completed=0;
    GSR GSR (.GSRI(rst_n));
    window_buffer #(.PREPROCESS_MODE(1)) buffer (
        .clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),.enable(1'b1),
        .sample_in(raw),.sample_valid(sample_valid),.read_en(read_en),.read_addr(addr),
        .frame_out(sample),.window_ready(),.samples_collected(),.ready_bank(),.sample_cnt());
    feature_extraction feature (.clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),
        .start_compute(start),.ecg_threshold(16'd80),.read_enable(1'b0),
        .sample_addr(addr),.sample_in(sample),.read_en(read_en),
        .f_rms(f[0]),.f_var(f[1]),.f_peak(f[2]),.f_zc(f[3]),.f_ptp(f[4]),
        .f_crest(f[5]),.f_half_ratio(f[6]),.f_max(f[7]),.f_rr(f[8]),
        .f_rr_prev(f[9]),.f_rr_ratio(f[10]),.f_rr_diff(f[11]),
        .feature_valid(valid),.overflow(overflow));
    task automatic check(input bit ok,input string msg);
        checks++;
        assert(ok) else $fatal(1,"SIGNED FEATURE case=%0d %s",case_id,msg);
    endtask
    // Check the exact pre-edge sample consumed by the accumulator, not merely
    // the RAM address or post-edge registered data.
    always @(posedge clk) if(rst_n && !soft_reset) begin
        if(feature.state==2) begin
            check(consumed<512 && sample===signed_expected[case_id*512+consumed],
                  $sformatf("consumed sample %0d",consumed));
            consumed++;
        end
    end else consumed=0;
    task reset_soft;
        @(negedge clk); soft_reset=1; start=0; sample_valid=0;
        @(negedge clk); soft_reset=0;
        check(!valid && !read_en && feature.state==0,"reset aborts computation");
    endtask
    task fill_window;
        for(integer n=0;n<512;n++) begin
            @(negedge clk); raw=raw_expected[case_id*512+n]; sample_valid=1;
            @(negedge clk); sample_valid=0;
        end
    endtask
    task launch;
        @(negedge clk); start=1; @(negedge clk); start=0;
    endtask
    initial begin
        $readmemh("sim/g21_vectors/raw.hex",raw_expected);
        $readmemh("sim/g21_vectors/signed.hex",signed_expected);
        $readmemh("sim/g21_vectors/features.hex",feature_expected);
        repeat(4) @(negedge clk); rst_n=1;
        for(case_id=0;case_id<NUM_CASES;case_id++) begin
            reset_soft(); fill_window(); launch();
            if(case_id==NUM_CASES-1) begin
                repeat(25) @(negedge clk);
                check(consumed>0 && !valid,"reset occurs during active accumulation");
                reset_soft(); repeat(10) @(negedge clk);
                check(!valid,"no completion from aborted window");
                fill_window(); launch();
            end
            cycles=0;
            while(!valid && cycles<2500) begin @(negedge clk); cycles++; end
            check(valid && consumed==512 && !overflow,"exactly 512 consumed samples and valid");
            for(i=0;i<12;i++) check(f[i]===feature_expected[case_id*12+i],
                $sformatf("feature=%0d got=%0d expected=%0d",i,f[i],$signed(feature_expected[case_id*12+i])));
            check(f[1]>=0,"population variance is nonnegative");
            completed++;
        end
        check(completed==NUM_CASES,"all cases completed");
        $display("G21 SIGNED FEATURES PASS checks=%0d cases=%0d reset_mid=1 frozen_math=1",checks,completed);
        $finish;
    end
    initial begin #3000000; $fatal(1,"SIGNED FEATURE watchdog"); end
endmodule
