`timescale 1ns/1ps
// G3 MLP arithmetic testbench.
//
// Forces a DETERMINISTIC, SYNTHETIC weight set into the real ai_classifier
// datapath and compares every intermediate value (fc1 accumulators, ReLU
// outputs, fc2 logits, class code, overflow) against the independent Python
// model src/g3_mlp_reference.py (sim/g3_vectors/mlp_expect.hex).
//
// These weights are NOT a trained model. A trained-model integration stays
// BLOCKED until weight provenance is established
// (see reports/G3_4_WEIGHT_PROVENANCE.md).
module tb_g3_mlp;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, start=0, enable=1;
    reg signed [15:0] feat_raw [0:11];
    integer checks=0, failures=0;
    reg signed [31:0] exp_hidden [0:7];
    reg signed [31:0] exp_logit  [0:3];
    reg [1:0] exp_class;
    reg exp_overflow;
    reg [31:0] expect_data [0:1023];
    `include "sim/g3_vectors/mlp_meta.svh"

    wire [1:0] class_code;
    wire done, overflow;

    ai_classifier #(.FEATURE_WIDTH(16), .HIDDEN_NEURONS(8), .OUTPUT_NEURONS(4))
    dut (.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .start(start),
         .enable(enable),
         .features_flat({feat_raw[11],feat_raw[10],feat_raw[9],feat_raw[8],
                         feat_raw[7],feat_raw[6],feat_raw[5],feat_raw[4],
                         feat_raw[3],feat_raw[2],feat_raw[1],feat_raw[0]}),
         .class_code(class_code), .done(done), .overflow(overflow),
         .fc1_out_flat(), .fc2_out_flat());

    task automatic check(input bit ok, input string msg);
        checks++;
        if(!ok) begin
            failures++;
            $display("G3 MLP FAIL %s", msg);
        end
    endtask

    // Force the deterministic weights before the first inference. Flat index
    // layout: 0..95 fc1 weights, 96..103 fc1 biases, 104..135 fc2 weights,
    // 136..139 fc2 biases, 140..151 mean, 152..163 inv_scale.
    // Generated static forces (ModelSim SE 10.7c has no $fgetsls).
    `include "sim/g3_vectors/mlp_force.svh"

    task automatic run_case(input integer c);
        integer j;
        begin
            for(j=0;j<12;j++) feat_raw[j]=expect_data[c*26+j][15:0];
            for(j=0;j<8;j++)  exp_hidden[j]=expect_data[c*26+12+j];
            for(j=0;j<4;j++)  exp_logit[j]=expect_data[c*26+20+j];
            // Word 24 = class code, word 25 = overflow flag (one per word).
            exp_class=expect_data[c*26+24][1:0];
            exp_overflow=expect_data[c*26+25][0];
            // Ensure the unit is idle before launching this inference so the
            // completion pulse we wait on belongs to THIS case, not a
            // leftover from the previous one.
            wait(done===1'b0);
            start=1; @(posedge clk); start=0;
            wait(done===1'b1);
            repeat(2) @(negedge clk);   // let S_DONE output registers settle
            for(j=0;j<8;j++)
                check(dut.fc1_out[j]===exp_hidden[j],
                      $sformatf("case%0d fc1[%0d] got=%0d expected=%0d",c,j,
                          dut.fc1_out[j],exp_hidden[j]));
            for(j=0;j<4;j++)
                check(dut.fc2_out[j]===exp_logit[j],
                      $sformatf("case%0d fc2[%0d] got=%0d expected=%0d",c,j,
                          dut.fc2_out[j],exp_logit[j]));
            check(class_code===exp_class,
                  $sformatf("case%0d class got=%0d expected=%0d",c,class_code,exp_class));
            check(overflow===exp_overflow,
                  $sformatf("case%0d overflow got=%0d expected=%0d",c,overflow,exp_overflow));
        end
    endtask

    integer i, first_class, nonzero_expect;
    initial begin
        for(i=0;i<26*(G3_NUM_CASES+1);i++) expect_data[i]=0;
        $readmemh("sim/g3_vectors/mlp_expect.hex",expect_data);
        // Guard against a vacuous test: $readmemh assigns one address per
        // line, so a malformed vector file silently yields all-zero
        // expectations that match an all-zero-weight DUT. Refuse to run.
        nonzero_expect=0;
        for(i=0;i<26*G3_NUM_CASES;i++)
            if(expect_data[i]!==0) nonzero_expect++;
        if(nonzero_expect==0)
            $fatal(1,"G3 MLP vector file is empty/all-zero - malformed expectations");
        g3_forces;
        repeat(4) @(negedge clk);
        rst_n=1;
        repeat(2) @(negedge clk);

        for(i=0;i<G3_NUM_CASES;i++) run_case(i);

        // Repeated inference on the same vector must reproduce the result.
        run_case(0);
        first_class = class_code;
        run_case(0);
        check(class_code===first_class, "repeated inference is stable");

        // Soft reset returns the unit to idle and clears the error state.
        soft_reset=1; @(posedge clk); soft_reset=0; @(negedge clk);
        check(dut.state===4'd0 && done===1'b0 && overflow===1'b0,
              "soft reset returns to idle");

        if(failures) $fatal(1,"G3 MLP %0d failures of %0d checks",failures,checks);
        $display("G3 MLP PASS checks=%0d cases=%0d repeated=1",checks,G3_NUM_CASES);
        $finish;
    end
    initial begin #20000000; $fatal(1,"G3 MLP watchdog"); end
endmodule
