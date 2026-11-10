`timescale 1ns/1ps
module tb_g1_control;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, start=0, window_ready=0, feat_valid=0;
    reg inject_done=0, use_real=1;
    wire mlp_start, ai_done, done, uart_send, feature_start, idle;
    wire [3:0] state;
    wire completion = use_real ? ai_done : inject_done;
    integer starts=0, accepts=0, completions=0, results=0, features=0, checks=0;
    reg prev_start=0, prev_done=0, prev_feature=0;
    control_fsm #(.LOAD_TIMEOUT(400), .MLP_TIMEOUT(220)) dut (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .start(start),
        .apb_enable(1'b1), .window_ready(window_ready), .feat_valid(feat_valid),
        .mlp_done(completion), .mlp_start(mlp_start), .done(done),
        .uart_send(uart_send), .feature_start(feature_start),
        .fsm_idle(idle), .current_state(state), .window_en(),
        .feature_read_en(), .mlp_valid(), .read_addr(), .next_state_debug()
`ifndef G1_BASELINE
        , .pipeline_error() // New status port is absent on the committed baseline.
`endif
    );
    ai_classifier ai (.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .start(mlp_start && use_real), .enable(1'b1), .features_flat(192'd0),
        .done(ai_done), .class_code(), .overflow(), .fc1_out_flat(), .fc2_out_flat());

    task automatic check(input bit ok, input string msg);
        checks++;
        assert (ok) else $fatal(1,"CONTROL: %s state=%0d",msg,state);
    endtask
    always @(posedge clk) if (rst_n && !soft_reset) begin
        assert (!(mlp_start && prev_start)) else $fatal(1,"MLP start wider than one cycle");
        assert (!(done && prev_done)) else $fatal(1,"duplicate result pulse");
        assert (!(feature_start && prev_feature)) else $fatal(1,"feature start wider than one cycle");
        assert (uart_send === done) else $fatal(1,"UART trigger without success");
        prev_start <= mlp_start; prev_done <= done; prev_feature <= feature_start;
        if (mlp_start) starts++;
        if (mlp_start && use_real && ai.state==0) accepts++;
        if (ai_done) completions++;
        if (feature_start) features++;
        if (done) results++;
    end else begin
        prev_start<=0; prev_done<=0; prev_feature<=0;
    end
    task automatic tick(input integer n);
        repeat(n) @(negedge clk);
    endtask
    task automatic reset_soft;
        soft_reset=1; tick(1);
        check(state==0 && !done && !mlp_start && !feature_start,"soft reset clears outputs");
        soft_reset=0; start=0; feat_valid=0; window_ready=0; inject_done=0;
        tick(2);
    endtask
    task automatic begin_window(input bit simultaneous);
        integer f;
        f=features;
        start=1;
        if (simultaneous) window_ready=1;
        tick(1); start=0; window_ready=0;
        if (!simultaneous) begin tick(2); window_ready=1; tick(1); window_ready=0; end
        tick(3);
        check(features==f+1,"exactly one feature start / one-cycle window event");
    endtask
    task automatic finish_feature;
        feat_valid=1; tick(1); feat_valid=0;
        wait(mlp_start===1); @(negedge clk);
    endtask
    task automatic wait_result(input integer expected);
        integer n;
        n=0;
        while(results<expected && n<300) begin tick(1); n++; end
        check(results==expected,"completion delivered exactly once");
        tick(8); check(idle,"return to idle after done");
    endtask
    integer a, r, s, f, k;
    initial begin
        tick(4); rst_n=1; tick(2);
        // Unsolicited feature/done pulses cannot create a transaction.
        feat_valid=1; inject_done=1; use_real=0; tick(1);
        feat_valid=0; inject_done=0; tick(3);
        check(starts==0 && results==0,"ignore stray pulses in IDLE"); use_real=1;
        for(k=0;k<4;k++) begin
            a=accepts; r=results;
            begin_window(k==0);
            tick(4); finish_feature(); wait_result(r+1); tick(230);
            check(accepts==a+1 && completions==accepts,"one accepted real MLP and completion");
        end
        // Reset after feature start, then prove feat_started does not wedge.
        begin_window(0); r=results; s=starts; reset_soft(); tick(10);
        check(results==r && starts==s,"aborted feature emits no inference/result");
        begin_window(0); finish_feature(); wait_result(r+1);
        // Reset an actual active classifier, not only a mocked done input.
        begin_window(0); finish_feature(); tick(25); r=results;
        reset_soft(); tick(240);
        check(results==r && ai.state==0,"MLP abort has no late success");
        begin_window(0); finish_feature(); wait_result(r+1);
        // Hold START through completion: it is a command edge, not a retrigger.
        begin_window(0); start=1; r=results; finish_feature(); wait_result(r+1);
        tick(240); check(results==r+1 && idle,"held START cannot repeat transaction");
        start=0; tick(2);
        // A ready pulse at DONE must survive the subsequent APB re-arm gap.
        begin_window(0); r=results; finish_feature(); wait(state==9);
        @(negedge clk); window_ready=1; tick(1); window_ready=0;
        wait_result(r+1); f=features; start=1; tick(1); start=0; tick(4);
        check(features==f+1,"window at DONE retained until next START");
        finish_feature(); wait_result(r+2);
        // No MLP done: MLP_TIMEOUT, not LOAD_TIMEOUT, must terminate the wait.
        use_real=0; begin_window(0); r=results; finish_feature(); tick(222);
        check(state==10 && results==r && !done,"MLP timeout is explicit failure");
        inject_done=1; tick(1); inject_done=0; start=1; tick(1); start=0; tick(20);
        check(state==10 && results==r,"late done/start cannot escape error");
        reset_soft();
        // Completion sampled when the deadline counter reaches zero wins.
        begin_window(1); finish_feature(); wait(dut.timeout_cnt==0);
        @(negedge clk); inject_done=1; tick(1); inject_done=0;
        wait_result(r+1);
        // Earliest one-cycle completion on the MLP acceptance edge is observed.
        begin_window(0); finish_feature(); inject_done=1; tick(1); inject_done=0;
        wait_result(r+2);
        // LOAD timeout before a window and during feature work both fail closed.
        start=1; tick(1); start=0; tick(402);
        check(state==10,"missing window timeout"); reset_soft();
        begin_window(0); tick(402); check(state==10,"missing feature timeout");
        reset_soft(); use_real=1; begin_window(0); finish_feature(); wait_result(r+3);
        $display("G1 CONTROL PASS checks=%0d starts=%0d accepted=%0d results=%0d",checks,starts,accepts,results);
        $finish;
    end
    initial begin #2000000; $fatal(1,"CONTROL watchdog"); end
endmodule
