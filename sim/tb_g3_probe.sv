`timescale 1ns/1ps
// G3 MLP weight-layout probe.
//
// Purpose
// -------
// The MLP bench uses a DIAGONAL weight network, and for a diagonal network
// a neuron-major and an input-major flattening are indistinguishable: both
// put neuron j's input-j weight at the same flat index. This probe settles
// the layout with a NON-DIAGONAL weight, which the two layouts place
// differently.
//
// Method
// ------
// All weights are zeroed, then exactly ONE flat index is set to 4096.
// With mean=0, inv_scale=4096 and feat[i]=i+1, a weight of 4096 at
// flat index F contributes (input+1)*4096 to the neuron that F addresses.
// The responding neuron index and the response magnitude therefore identify
// the (neuron, input) pair, and hence the layout.
//
// Expected result (matches src/ai_classifier.v, where the MAC address is
// fc1_weights[cnt-1] with neuron=(cnt-1)/12 and input=(cnt-1)%12):
//   flat 13 -> neuron 1, input 1  -> fc1[1] = 2*4096 = 8192
//   flat 12 -> neuron 1, input 0  -> fc1[1] = 1*4096 = 4096
// Under an input-major layout, flat 13 would instead be neuron 5.
//
// This is a diagnostic, not part of the regression suite.
module tb_g3_probe;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, start=0, enable=1;
    reg signed [15:0] feat [0:11];
    integer z, n;
    wire [1:0] class_code; wire done, overflow;
    ai_classifier #(.FEATURE_WIDTH(16), .HIDDEN_NEURONS(8), .OUTPUT_NEURONS(4))
    dut (.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .start(start),
         .enable(enable),
         .features_flat({feat[11],feat[10],feat[9],feat[8],feat[7],feat[6],
                         feat[5],feat[4],feat[3],feat[2],feat[1],feat[0]}),
         .class_code(class_code), .done(done), .overflow(overflow),
         .fc1_out_flat(), .fc2_out_flat());

    // One inference, waiting for a COMPLETE done pulse and then for done to
    // clear, so the results read back belong to this run and not the
    // previous one.
    task automatic run_one;
        begin
            wait(done===1'b0);
            start=1; @(posedge clk); start=0;
            wait(done===1'b1);
            wait(done===1'b0);
        end
    endtask

    initial begin
        for(n=0;n<12;n++) feat[n]=n+1;              // feat[i] = i+1
        for(z=0;z<96;z++) force dut.fc1_weights[z]=0;
        for(z=0;z<8;z++)  force dut.fc1_biases[z]=0;
        for(z=0;z<32;z++) force dut.fc2_weights[z]=0;
        for(z=0;z<4;z++)  force dut.fc2_biases[z]=0;
        for(z=0;z<12;z++) force dut.mean_vals[z]=0;
        for(z=0;z<12;z++) force dut.inv_scale[z]=4096;
        repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
        $display("PROBE feat[i]=i+1, mean=0, inv_scale=4096, single weight=4096");

        // flat 13 -> expect neuron 1, input 1 -> fc1[1] = 8192
        force dut.fc1_weights[13]=4096;
        run_one;
        $write("PROBE flat 13 -> ");
        for(n=0;n<8;n++) if(dut.fc1_out[n]) $write("fc1[%0d]=%0d ",n,dut.fc1_out[n]);
        $display("(expect fc1[1]=8192)");

        // flat 12 -> expect neuron 1, input 0 -> fc1[1] = 4096
        force dut.fc1_weights[13]=0;
        force dut.fc1_weights[12]=4096;
        run_one;
        $write("PROBE flat 12 -> ");
        for(n=0;n<8;n++) if(dut.fc1_out[n]) $write("fc1[%0d]=%0d ",n,dut.fc1_out[n]);
        $display("(expect fc1[1]=4096)");

        // flat 5 -> expect neuron 0, input 5 -> fc1[0] = 24576
        force dut.fc1_weights[12]=0;
        force dut.fc1_weights[5]=4096;
        run_one;
        $write("PROBE flat 5  -> ");
        for(n=0;n<8;n++) if(dut.fc1_out[n]) $write("fc1[%0d]=%0d ",n,dut.fc1_out[n]);
        $display("(expect fc1[0]=24576)");
        $finish;
    end
    initial begin #4000000; $fatal(1,"probe watchdog"); end
endmodule
