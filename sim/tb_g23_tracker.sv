`timescale 1ns/1ps
module tb_g23_tracker;
    `include "sim/g23_vectors/trace_counts.svh"
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0, soft_reset=0, sample_accept=0;
    reg signed [7:0] sample_in=0;
    reg signed [15:0] threshold=80;
    wire [63:0] next_index,event_time;
    wire event_pulse,cv,pv,ts_fault;
    wire [15:0] current_rr,previous_rr;
    reg [63:0] trace_data[0:NUM_TRACE*10-1];
    integer checks=0,events=0,resets=0;
    rr_tracker dut(.clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),
        .sample_accept(sample_accept),.sample_in(sample_in),.threshold(threshold),
        .next_sample_index(next_index),.peak_event(event_pulse),.event_timestamp(event_time),
        .rr_current(current_rr),.rr_previous(previous_rr),.current_valid(cv),
        .previous_valid(pv),.timestamp_overflow(ts_fault));
    task automatic check(input bit ok,input string msg);
        checks++; assert(ok) else $fatal(1,"G23 TRACKER %s",msg);
    endtask
    initial begin
        $readmemh("sim/g23_vectors/trace.hex",trace_data);
        repeat(4) @(negedge clk); rst_n=1;
        for(integer i=0;i<NUM_TRACE;i++) begin
            if(trace_data[i*10]) begin
                sample_accept=0; soft_reset=1;
                @(negedge clk); soft_reset=0; resets++;
                check(next_index==0 && !cv && !pv && !event_pulse && !ts_fault,"soft reset starts new epoch");
            end
            sample_accept=1; threshold=trace_data[i*10+1][15:0]; sample_in=trace_data[i*10+2][7:0];
            @(negedge clk);
            check(next_index===trace_data[i*10+3],$sformatf("monotonic index row%0d",i));
            check(event_pulse===trace_data[i*10+4][0],$sformatf("event once row%0d",i));
            check(event_time===trace_data[i*10+5],$sformatf("timestamp row%0d",i));
            check(current_rr===trace_data[i*10+6][15:0] && previous_rr===trace_data[i*10+7][15:0],
                  $sformatf("exact RR history row%0d got%0d/%0d expected%0d/%0d",i,current_rr,previous_rr,trace_data[i*10+6],trace_data[i*10+7]));
            check(cv===trace_data[i*10+8][0] && pv===trace_data[i*10+9][0] && !ts_fault,"validity");
            if(event_pulse) events++;
            // Pauses must not advance sample time, history, or repeat events.
            sample_accept=0;
            repeat((i%3)+1) begin
                @(negedge clk);
                check(next_index===trace_data[i*10+3] && !event_pulse,"paused stream stable, event single cycle");
            end
        end
        // Full reset while a real valid history is present (last boundary case).
        check(cv && pv,"history present before hard reset");
        rst_n=0; #1;
        check(next_index==0 && !cv && !pv && !event_pulse,"asynchronous hard reset");
        @(negedge clk); rst_n=1;
        // Defensive accelerated lifetime boundary, not a physical ECG test.
        dut.next_sample_index=64'hfffffffffffffffe;
        sample_accept=1; sample_in=0;
        @(negedge clk); check(next_index==64'hffffffffffffffff && !ts_fault,"last increment does not wrap");
        @(negedge clk); check(next_index==64'hffffffffffffffff && ts_fault && !cv && !pv && !event_pulse,"timestamp saturation invalidates history");
        @(negedge clk); check(next_index==64'hffffffffffffffff && ts_fault,"timestamp halt sticky");
        soft_reset=1; @(negedge clk); soft_reset=0; sample_accept=0;
        check(!ts_fault && next_index==0,"soft reset clears timestamp fault");
        $display("G23 TRACKER PASS samples=%0d checks=%0d events=%0d soft_epochs=%0d",NUM_TRACE,checks,events,resets);
        $finish;
    end
    initial begin #20000000; $fatal(1,"G23 TRACKER watchdog"); end
endmodule
