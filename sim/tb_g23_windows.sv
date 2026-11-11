`timescale 1ns/1ps
module tb_g23_windows;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0;
    wire tx, overflow;
    // 2500 cycles/sample: longer than the entire feature RAM read, and
    // 256*2500 cycles/window > 33*10*437 UART cycles. No circular RAM drift.
    top_ecg_rom_demo #(.CLK_HZ(50_000_000), .TARGET_HZ(20_000),
        .ROM_HEX("sim/g23_vectors/synthetic_raw.hex")) dut (.sys_clk(clk), .sys_rst_n(rst_n),
        .uart_txd(tx), .uart_rxd(1'b1), .status_led(), .demo_done(),
        .demo_overflow(overflow), .demo_class());
    GSR GSR (.GSRI(rst_n));
    `include "sim/g23_vectors/synthetic_packets.sv"
    localparam integer BIT_NS=437*20;
    integer features=0, starts=0, accepted=0, mlp_done_count=0, results=0;
    integer requests=0, packets=0, tx_bytes=0, rx_bytes=0, checks=0;
    reg [7:0] raw_rom[0:2047], signed_rom[0:2047];
    integer paced=0, forwarded=0, writes=0, consumed=0;
    initial begin
        $readmemh("sim/g23_vectors/synthetic_raw.hex",raw_rom);
        $readmemh("sim/g23_vectors/synthetic_signed.hex",signed_rom);
    end
    reg previous_start=0, previous_done=0, previous_req=0;
    bit inject;
    reg [1:0] injected_class=0;
    integer capture;
    string capture_dir;
    reg [7:0] received;
    integer b, w, j;
    reg [7:0] expected, checksum=0;

    // Testbench-only injection on the result net, never on weights/formulas.
    initial begin
        inject=$test$plusargs("INJECT_CLASS");
        if(inject) force dut.sys_class_code=injected_class;
        if (!$value$plusargs("CAPTURE_DIR=%s",capture_dir)) capture_dir="sim/g21_results/signed";
        capture=$fopen({capture_dir, inject ? "/synthetic_injected.bin" : "/synthetic.bin"},"wb");
        if(!capture) $fatal(1,"cannot create UART capture");
    end
    always @(negedge clk) if(rst_n && dut.mlp_start)
        injected_class=accepted%4;

    always @(posedge clk) if(rst_n) begin
        assert(!(previous_start && dut.mlp_start)) else $fatal(1,"ROM: repeated MLP start");
        assert(!(previous_done && dut.sys_done)) else $fatal(1,"ROM: repeated done");
        assert(!(previous_req && dut.pkt_req)) else $fatal(1,"ROM: repeated packet request");
        assert(!overflow) else $fatal(1,"ROM: unexpected error/drop");
        previous_start<=dut.mlp_start; previous_done<=dut.sys_done; previous_req<=dut.pkt_req;
        if(dut.pace_valid) begin
            assert(paced<2048 && dut.pace_data===raw_rom[paced])
                else $fatal(1,"pacer ROM alignment sample=%0d",paced);
            paced++;
        end
        if(dut.adc_sample_valid) begin
            assert(forwarded<2048 && dut.adc_sample===raw_rom[forwarded])
                else $fatal(1,"ADC ROM alignment sample=%0d",forwarded);
            forwarded++;
        end
        if(dut.window_enable && dut.adc_sample_valid) begin
            assert(writes<2048 && dut.u_window.preprocessed_sample===signed_rom[writes])
                else $fatal(1,"RAM signed write alignment sample=%0d",writes);
            writes++;
        end
        if(dut.u_feature.state==dut.u_feature.S_ACCUMULATE_READ) begin
            assert(consumed<3584 && dut.window_frame_wire===signed_rom[(consumed/512)*256+consumed%512])
                else $fatal(1,"feature sample alignment consumed=%0d",consumed);
            consumed++;
        end
        if(dut.feature_start) features++;
        if(dut.mlp_start) begin
            starts++;
            assert(dut.u_ai.state==0 && dut.sys_enable) else $fatal(1,"ROM: unaccepted MLP start");
            accepted++;
        end
        if(dut.mlp_done) mlp_done_count++;
        if(dut.sys_done) results++;
        if(dut.pkt_req) requests++;
        if(dut.pkt_done_r) packets++;
        if(dut.pkt_tx_start) tx_bytes++;
        if(dut.feat_valid) begin
            for(integer k=0;k<12;k++) begin
                checks++;
                assert(dut.features_flat[k*16+:16]===exp_feat[features-1][k])
                    else $fatal(1,"ROM feature window=%0d index=%0d got=%0d expected=%0d",
                         features,k,$signed(dut.features_flat[k*16+:16]),exp_feat[features-1][k]);
            end
        end
    end

    // Independent receiver decodes actual serial pin (8N1, LSB first).
    initial forever begin
        @(negedge tx);
        #(BIT_NS/2);
        assert(tx===0) else $fatal(1,"UART start bit");
        for(b=0;b<8;b++) begin #(BIT_NS); received[b]=tx; end
        #(BIT_NS);
        assert(tx===1) else $fatal(1,"UART stop bit");
        w=rx_bytes/33; j=rx_bytes%33;
        assert(w<EXP_NUMW) else $fatal(1,"extra UART frame");
        expected=exp_pkt[w][j];
        if(inject && j==30) expected=w%4;
        if(inject && j==32) expected=exp_pkt[w][32]+(w%4);
        checks++;
        assert(received===expected) else $fatal(1,"UART byte window=%0d byte=%0d got=%02h expected=%02h",w+1,j,received,expected);
        if(j==2) checksum=0;
        if(j>=2 && j<=31) checksum=checksum+received;
        if(j==32) begin
            assert(received===checksum) else $fatal(1,"UART checksum");
            $display("UART window=%0d class=%0d PASS",w+1,inject ? w%4 : 0);
        end
        $fwrite(capture,"%c",received);
        rx_bytes++;
    end
    initial begin
        repeat(6) @(negedge clk); rst_n=1;
        wait(packets==7);
        repeat(200000) @(negedge clk);
        assert(dut.pace_eod && dut.u_adc_if.sample_count==2048 &&
               dut.u_window.samples_collected==2048 && dut.win_index==7 && dut.fsm_idle)
            else $fatal(1,"ROM samples/windows skipped");
        assert(paced==2048 && forwarded==2048 && writes==2048 && consumed==3584)
            else $fatal(1,"signed sample path counts %0d %0d %0d %0d",paced,forwarded,writes,consumed);
        $display("SIGNED ALIGNMENT PASS paced=2048 ADC=2048 RAM=2048 consumed=3584");
        assert(features==7 && starts==7 && accepted==7 && mlp_done_count==7 &&
               results==7 && requests==7 && packets==7 && tx_bytes==231 && rx_bytes==231)
            else $fatal(1,"ROM counts f=%0d s=%0d a=%0d md=%0d r=%0d q=%0d p=%0d tx=%0d rx=%0d",
                 features,starts,accepted,mlp_done_count,results,requests,packets,tx_bytes,rx_bytes);
        assert(events_seen==4) else $fatal(1,"lost synthetic peak");
        $fclose(capture);
        $display("G23 WINDOWS PASS injected=%0d checks=%0d samples=2048 windows=7 bytes=231",inject,checks);
        $finish;
    end
    initial begin #150000000; $fatal(1,"ROM UART watchdog"); end

    integer events_seen=0;
    always @(negedge clk) if(rst_n) begin
        assert(dut.u_rr.next_sample_index==writes) else $fatal(1,"synthetic chronological samples");
        if(dut.u_rr.peak_event) begin
            case(events_seen)
            0: assert(dut.u_rr.event_timestamp==100) else $fatal(1,"first event");
            1: assert(dut.u_rr.event_timestamp==255) else $fatal(1,"boundary255 event");
            2: assert(dut.u_rr.event_timestamp==511) else $fatal(1,"boundary511 event");
            3: assert(dut.u_rr.event_timestamp==900) else $fatal(1,"last event");
            default: $fatal(1,"overlap duplicated an event");
            endcase
            events_seen++;
        end
        if(dut.feat_valid) begin
            assert(dut.rr_snapshot_current==exp_feat[features-1][8] &&
                   dut.rr_snapshot_previous==exp_feat[features-1][9] &&
                   dut.rr_snapshot_current_valid==(exp_feat[features-1][8]!=0) &&
                   dut.rr_snapshot_previous_valid==(exp_feat[features-1][9]!=0))
                else $fatal(1,"synthetic exact boundary snapshot");
        end
    end
endmodule
