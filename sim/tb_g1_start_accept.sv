`timescale 1ns/1ps
// Count actual classifier acceptances through IDLE, including a quiet tail.
// This independently detects the old second inference after the first DONE.
module tb_g1_start_accept;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, start=0, ready=0, feat_valid=0;
    wire feature_start, mlp_start, mlp_done, done;
    integer accepted=0, completed=0, results=0;
    control_fsm dut (.clk(clk), .rst_n(rst_n), .soft_reset(1'b0),
        .start(start), .apb_enable(1'b1), .window_ready(ready),
        .feat_valid(feat_valid), .mlp_done(mlp_done), .feature_start(feature_start),
        .mlp_start(mlp_start), .done(done), .fsm_idle(), .window_en(),
        .feature_read_en(), .mlp_valid(), .uart_send(), .read_addr(),
        .current_state(), .next_state_debug()
`ifndef G1_BASELINE
        , .pipeline_error()
`endif
    );
    ai_classifier ai (.clk(clk), .rst_n(rst_n), .soft_reset(1'b0),
        .start(mlp_start), .enable(1'b1), .features_flat(192'd0),
        .class_code(), .done(mlp_done), .overflow(), .fc1_out_flat(), .fc2_out_flat());
    always @(posedge clk) if(rst_n) begin
        if(mlp_start && ai.state==0) accepted++;
        if(mlp_done) completed++;
        if(done) results++;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        @(negedge clk); start=1; @(negedge clk); start=0;
        repeat(3) @(negedge clk); ready=1; @(negedge clk); ready=0;
        wait(feature_start); repeat(5) @(negedge clk);
        feat_valid=1; @(negedge clk); feat_valid=0;
        wait(results==1); repeat(500) @(negedge clk);
        assert(accepted==1 && completed==1 && results==1)
            else $fatal(1,"MLP accepted=%0d completed=%0d results=%0d for ONE feature transaction",
                        accepted,completed,results);
        $display("G1 START ACCEPT PASS accepted=1 completed=1 results=1 quiet_tail=500");
        $finish;
    end
    initial begin #100000; $fatal(1,"START ACCEPT watchdog"); end
endmodule
