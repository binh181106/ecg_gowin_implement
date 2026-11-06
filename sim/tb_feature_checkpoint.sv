`timescale 1ns / 1ps

module tb_feature_checkpoint;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg soft_reset = 1'b0;
    reg start_compute = 1'b0;
    reg [15:0] ecg_threshold = 16'd80;

    wire [8:0] sample_addr;
    wire read_en;
    reg [7:0] sample_in = 8'd0;

    reg [7:0] memory [0:511];

    wire signed [15:0] f_rms;
    wire signed [15:0] f_var;
    wire signed [15:0] f_peak;
    wire signed [15:0] f_zc;
    wire signed [15:0] f_ptp;
    wire signed [15:0] f_crest;
    wire signed [15:0] f_half_ratio;
    wire signed [15:0] f_max;
    wire signed [15:0] f_rr;
    wire signed [15:0] f_rr_prev;
    wire signed [15:0] f_rr_ratio;
    wire signed [15:0] f_rr_diff;

    wire feature_valid;
    wire overflow;

    integer checks = 0;
    integer errors = 0;
    integer cases_run = 0;
    integer case_id = 0;

    feature_extraction #(
        .DATA_IN_WIDTH(8),
        .DATA_OUT_WIDTH(16),
        .NUM_SAMPLES(512)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .soft_reset(soft_reset),
        .start_compute(start_compute),
        .ecg_threshold(ecg_threshold),
        .read_enable(1'b0),
        .sample_addr(sample_addr),
        .sample_in(sample_in),
        .read_en(read_en),
        .f_rms(f_rms),
        .f_var(f_var),
        .f_peak(f_peak),
        .f_zc(f_zc),
        .f_ptp(f_ptp),
        .f_crest(f_crest),
        .f_half_ratio(f_half_ratio),
        .f_max(f_max),
        .f_rr(f_rr),
        .f_rr_prev(f_rr_prev),
        .f_rr_ratio(f_rr_ratio),
        .f_rr_diff(f_rr_diff),
        .feature_valid(feature_valid),
        .overflow(overflow)
    );

    // Mo hinh RAM doc dong bo, cap nhat dau ra bang NBA.
    // Co tinh khong reset sample_in giua cac case:
    // du lieu cu giup phat hien DUT doc qua som.
    always @(posedge clk) begin
        if (read_en)
            sample_in <= memory[sample_addr];
    end

    task automatic fill_memory(input [7:0] value);
        integer i;
        begin
            for (i = 0; i < 512; i = i + 1)
                memory[i] = value;
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start_compute = 1'b0;
            soft_reset = 1'b0;

            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic check_value(
        input string label,
        input logic signed [63:0] actual,
        input logic signed [63:0] expected
    );
        begin
            checks = checks + 1;

            if (actual !== expected) begin
                errors = errors + 1;
                $display(
                    "FAIL case=%0d %s actual=%0d expected=%0d",
                    case_id, label, actual, expected
                );
            end
        end
    endtask

    task automatic run_window;
        integer cycles;
        begin
            @(negedge clk);
            start_compute = 1'b1;
            @(negedge clk);
            start_compute = 1'b0;

            cycles = 0;
            while ((feature_valid !== 1'b1) &&
                   (cycles < 2500)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (feature_valid !== 1'b1)
                $fatal(
                    1,
                    "TIMEOUT case=%0d state=%0d cycles=%0d",
                    case_id, dut.state, cycles
                );

            cases_run = cases_run + 1;
            $display(
                "DONE case=%0d cycles=%0d",
                case_id, cycles
            );
        end
    endtask

    task automatic check_no_rr;
        begin
            check_value("f_rr",       f_rr,       0);
            check_value("f_rr_prev",  f_rr_prev,  0);
            check_value("f_rr_ratio", f_rr_ratio, 4096);
            check_value("f_rr_diff",  f_rr_diff,  0);
        end
    endtask

    task automatic check_impulse;
        begin
            // Mot mau 100, con lai 0.
            // mean-square = floor(10000 / 512) = 19.
            // crest baseline = floor(100 * 4096 / 19).
            check_value("sum",        dut.sum,        100);
            check_value("sum_square", dut.sum_square, 10000);
            check_value("f_rms",       f_rms,          19);
            check_value("f_peak",      f_peak,         100);
            check_value("f_max",       f_max,          100);
            check_value("f_ptp",       f_ptp,          100);
            check_value("f_crest",     f_crest,        21557);
            check_value("overflow",   {63'd0, overflow}, 0);
        end
    endtask

    initial begin
        $display("FEATURE CHECKPOINT: 512 samples, sync RAM");
        $display("Baseline check only; RMS output is mean-square.");

        // Case 0: Mau toan 0, kiem tra nhanh mau so bang 0.
        case_id = 0;
        reset_dut();
        fill_memory(8'd0);
        run_window();

        check_value("sum",          dut.sum,        0);
        check_value("sum_square",   dut.sum_square, 0);
        check_value("f_rms",        f_rms,          0);
        check_value("f_var",        f_var,          0);
        check_value("f_peak",       f_peak,         0);
        check_value("f_zc",         f_zc,           0);
        check_value("f_ptp",        f_ptp,          0);
        check_value("f_crest",      f_crest,        0);
        check_value("f_half_ratio", f_half_ratio,   4096);
        check_value("f_max",        f_max,          0);
        check_value("overflow",     {63'd0, overflow}, 0);
        check_no_rr();

        // Case 1: 512 mau bang 10.
        case_id = 1;
        reset_dut();
        fill_memory(8'd10);
        run_window();

        check_value("sum",          dut.sum,        5120);
        check_value("sum_square",   dut.sum_square, 51200);
        check_value("f_rms",        f_rms,          100);
        check_value("f_var",        f_var,          0);
        check_value("f_peak",       f_peak,         10);
        check_value("f_ptp",        f_ptp,          0);
        check_value("f_crest",      f_crest,        409);
        check_value("f_half_ratio", f_half_ratio,   4096);
        check_no_rr();

        // Case 2: Cua so tiep theo bang 20, KHONG reset.
        // Bat loi du lieu cu va tich luy chua duoc xoa.
        case_id = 2;
        @(negedge clk);
        fill_memory(8'd20);
        run_window();

        check_value("sum",          dut.sum,        10240);
        check_value("sum_square",   dut.sum_square, 204800);
        check_value("f_rms",        f_rms,          400);
        check_value("f_var",        f_var,          0);
        check_value("f_peak",       f_peak,         20);
        check_value("f_ptp",        f_ptp,          0);
        check_value("f_crest",      f_crest,        204);
        check_value("f_half_ratio", f_half_ratio,   4096);
        check_no_rr();

        // Case 3: Xung tai mau dau.
        case_id = 3;
        reset_dut();
        fill_memory(8'd0);
        memory[0] = 8'd100;
        run_window();
        check_impulse();

        // Case 4: Xung tai mau cuoi.
        // Bat loi lap mau truoc / bo sot mau cuoi.
        case_id = 4;
        reset_dut();
        fill_memory(8'd0);
        memory[511] = 8'd100;
        run_window();
        check_impulse();

        // Case 5: RR co mau so khac 0.
        // Canh xuong tai index 11, 31, 61.
        // Theo bo dem RTL hien tai: RR truoc=19, RR moi=29.
        // Day la baseline hien tai, chua phai RR dung vat ly.
        case_id = 5;
        reset_dut();
        fill_memory(8'd0);
        memory[10] = 8'd100;
        memory[30] = 8'd100;
        memory[60] = 8'd100;
        run_window();

        check_value("sum",        dut.sum,        300);
        check_value("sum_square", dut.sum_square, 30000);
        check_value("f_rr",       f_rr,           29);
        check_value("f_rr_prev",  f_rr_prev,      19);
        check_value("f_rr_ratio", f_rr_ratio,     6251);
        check_value("f_rr_diff",  f_rr_diff,      10);
        check_value("overflow",   {63'd0, overflow}, 0);

        if (errors != 0)
            $fatal(
                1,
                "FEATURE CHECK FAIL cases=%0d checks=%0d errors=%0d",
                cases_run, checks, errors
            );

        $display(
            "FEATURE CHECK PASS cases=%0d checks=%0d",
            cases_run, checks
        );
        $finish;
    end

    // Guard tong de tranh treo neu testbench bi loi.
    initial begin
        #1000000;
        $fatal(1, "GLOBAL TIMEOUT");
    end

endmodule