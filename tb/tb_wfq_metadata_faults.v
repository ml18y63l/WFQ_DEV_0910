// Integrated FAST5 metadata verification with an independent live-slot model.
`timescale 1ns/1ps
module tb_wfq_metadata_faults;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
parameter integer ISSUE_INTERVAL = 5;
`include "wfq_clog2.vh"
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);

reg clk, rstn, init_done, init_write_en, halt;
reg [12:0] init_write_addr;
reg request_valid, request_insert, request_context, request_bank;
reg [11:0] request_tag;
wire request_ready;
reg alloc_valid, alloc_context;
reg [PTR_WIDTH-1:0] alloc_ptr;
reg commit_allow;
wire pred_valid, pred_context, pred_bank, pred_found, pred_exact;
wire [11:0] pred_tag;
wire [1:0] pred_path;
wire [PTR_WIDTH-1:0] pred_ptr;
wire prepare_valid;
wire [COUNT_WIDTH-1:0] prepare_old_count, prepare_new_count;
wire commit_due, commit_ok, commit_fire, commit_done, commit_context;
wire error_valid, fault;
wire [3:0] error_code, fault_code;


reg [COUNT_WIDTH-1:0] saved_rc [0:8191];
reg [PTR_WIDTH:0] saved_tt [0:8191];
reg [15:0] saved_leaf [0:511];
reg [15:0] saved_parent [0:31];
reg [31:0] saved_root;
integer cycle, test_id, checks, fault_tests, cancel_tests, i, stage;
integer expected_error, expected_edge;
reg do_insert;
reg [11:0] query_tag;

wfq_key_metadata #(
    .PTR_WIDTH(PTR_WIDTH),
    .MEM_DEPTH(MEM_DEPTH),
    .ISSUE_INTERVAL(ISSUE_INTERVAL)
) u_dut (
    .clk(clk),
    .rstn(rstn),
    .init_done(init_done),
    .init_write_en(init_write_en),
    .init_write_addr(init_write_addr),
    .halt(halt),
    .request_valid(request_valid),
    .request_ready(request_ready),
    .request_insert(request_insert),
    .request_context(request_context),
    .request_bank(request_bank),
    .request_tag(request_tag),
    .alloc_valid(alloc_valid),
    .alloc_context(alloc_context),
    .alloc_ptr(alloc_ptr),
    .commit_allow(commit_allow),
    .pred_valid(pred_valid),
    .pred_context(pred_context),
    .pred_bank(pred_bank),
    .pred_found(pred_found),
    .pred_tag(pred_tag),
    .pred_exact(pred_exact),
    .pred_path(pred_path),
    .pred_ptr(pred_ptr),
    .prepare_valid(prepare_valid),
    .prepare_old_count(prepare_old_count),
    .prepare_new_count(prepare_new_count),
    .commit_due(commit_due),
    .commit_ok(commit_ok),
    .commit_fire(commit_fire),
    .commit_done(commit_done),
    .commit_context(commit_context),
    .error_valid(error_valid),
    .error_code(error_code),
    .fault(fault),
    .fault_code(fault_code)
);

task fail;
    input [511:0] reason;
    begin
        $display("FAIL faults id=%0d phase=%0d cycle=%0d expected=%0d got=%0d reason=%0s",
                 test_id, stage, cycle, expected_error, fault_code, reason);
        $finish;
    end
endtask

task tick;
    begin
        #4; clk = 1; #1;
        cycle = cycle + 1;
        #4; clk = 0;
    end
endtask

task initialize;
    integer idx;
    begin
        rstn = 0; init_done = 0; init_write_en = 0; halt = 0;
        request_valid = 0; alloc_valid = 0; commit_allow = 1;
        #1;
        if (fault || commit_done || request_ready)
            fail("reset did not clear status");
        rstn = 1;
        for (idx = 0; idx < 8192; idx = idx + 1) begin
            init_write_en = 1; init_write_addr = idx;
            tick;
        end
        init_write_en = 0; tick; init_done = 1; #1;
        // Consistent one-key seed: key 0x121, slot 1 in bank 0.
        u_dut.u_rc.u_ram.mem_d[13'h0121] = 1;
        u_dut.u_tt.u_ram.mem_d[13'h0121] = {1'b1, {{(PTR_WIDTH-1){1'b0}}, 1'b1}};
        u_dut.u_leaf.mem_d[9'h012] = 16'h0002;
        u_dut.u_upper.l2_d[1] = 16'h0004;
        u_dut.u_upper.l1_d[0] = 16'h0002;
        #1;
    end
endtask

task save_image;
    integer idx;
    begin
        // Let flat combinational views settle after hierarchical fault injection.
        #1;
        for (idx = 0; idx < 8192; idx = idx + 1) begin
            saved_rc[idx] = u_dut.u_rc.u_ram.mem_d[idx];
            saved_tt[idx] = u_dut.u_tt.u_ram.mem_d[idx];
        end
        for (idx = 0; idx < 512; idx = idx + 1)
            saved_leaf[idx] = u_dut.u_leaf.mem_d[idx];
        for (idx = 0; idx < 32; idx = idx + 1)
            saved_parent[idx] = u_dut.u_upper.l2_d[idx];
        saved_root = u_dut.l1_flat;
    end
endtask

task check_image;
    integer idx;
    begin
        for (idx = 0; idx < 8192; idx = idx + 1) begin
            if ((saved_rc[idx] !== u_dut.u_rc.u_ram.mem_d[idx]) ||
                (saved_tt[idx] !== u_dut.u_tt.u_ram.mem_d[idx]))
                fail("partial TT/RC write on fault/cancel");
        end
        for (idx = 0; idx < 512; idx = idx + 1) begin
            if (saved_leaf[idx] !== u_dut.u_leaf.mem_d[idx])
                fail("partial L3 write on fault/cancel");
        end
        for (idx = 0; idx < 32; idx = idx + 1) begin
            if (saved_parent[idx] !== u_dut.u_upper.l2_d[idx])
                fail("partial L2 write on fault/cancel");
        end
        if (saved_root !== u_dut.l1_flat)
            fail("partial L1 write on fault/cancel");
        checks = checks + 1;
    end
endtask

initial begin
    clk = 0; rstn = 1; init_done = 0; init_write_en = 0; init_write_addr = 0; halt = 0;
    request_valid = 0; request_insert = 1; request_context = 0; request_bank = 0; request_tag = 0;
    alloc_valid = 0; alloc_context = 0; alloc_ptr = 2; commit_allow = 1;
    cycle = 0; checks = 0; fault_tests = 0; cancel_tests = 0;
    expected_error = 0; stage = 0;
    for (test_id = 0; test_id < 23; test_id = test_id + 1) begin
        if ((test_id != 12 && test_id != 13) || (PTR_WIDTH > wfq_clog2(MEM_DEPTH))) begin
            initialize;
            query_tag = 12'h121; do_insert = 1;
            expected_error = 2; expected_edge = 1;
            alloc_ptr = 2; alloc_context = 0;
            case (test_id)
                0: begin
                    u_dut.u_rc.u_ram.mem_d[13'h0121] = MEM_DEPTH;
                    expected_error = 1;
                end
                1: begin
                    do_insert = 0; query_tag = 12'h122;
                    expected_error = 1;
                end
                2: u_dut.u_upper.l2_d[1] = 0;
                3: begin
                    u_dut.u_rc.u_ram.mem_d[13'h0121] = 0;
                    expected_edge = 2;
                end
                4: begin
                    query_tag = 12'h130;
                    u_dut.u_leaf.mem_d[9'h012] = 0;
                    expected_edge = 2;
                end
                5: begin
                    query_tag = 12'h200;
                    u_dut.u_upper.l2_d[1] = 0;
                end
                6: begin
                    u_dut.u_tt.u_ram.mem_d[13'h0121] = 0;
                    expected_edge = 3;
                end
                7: expected_error = 6;
                8: begin
                    alloc_context = 1; expected_error = 6;
                end
                9: expected_error = 6;
                10: begin
                    expected_error = 6; expected_edge = 2;
                end
                11: begin
                    expected_error = 6; expected_edge = 3;
                end
                12: begin
                    u_dut.u_tt.u_ram.mem_d[13'h0121] = {1'b1, {PTR_WIDTH{1'b1}}};
                    expected_error = 7; expected_edge = 3;
                end
                13: begin
                    alloc_ptr = MEM_DEPTH; expected_error = 7;
                end
                14: begin
                    u_dut.u_rc.u_ram.mem_d[13'h0121] = MEM_DEPTH;
                    u_dut.u_upper.l1_d[0] = 0;
                    expected_error = 1;
                end
                15: begin
                    do_insert = 0;
                    u_dut.u_leaf.mem_d[9'h012] = 0;
                end
                16: begin
                    do_insert = 0;
                    u_dut.u_rc.u_ram.mem_d[13'h0121] = MEM_DEPTH+1;
                    expected_error = 1;
                end
                // halt at each pre-commit edge E1..E4.
                17, 18, 19, 20: expected_error = 0;
                21, 22: begin
                    do_insert = 0; expected_error = 6;
                end
            endcase
            save_image;
            request_valid = 1; request_insert = do_insert;
            request_tag = query_tag; request_context = 0; request_bank = 0;
            #1;
            if (!request_ready)
                fail("initial request rejected");
            tick;
            request_valid = 0;
            for (stage = 1; stage <= 6; stage = stage + 1) begin
                alloc_valid = do_insert && stage == 1 && test_id != 7 && test_id != 14;
                if (test_id == 9 && stage == 1)
                    force u_dut.rc_read_valid = 1'b0;
                if (test_id == 10 && stage == 2)
                    force u_dut.search_context = 1'b1;
                if (test_id == 11 && stage == 3)
                    force u_dut.tt_read_valid = 1'b0;
                if (test_id == 21 && stage == 1) begin
                    force u_dut.rc_read_valid = 1'b0;
                    force u_dut.rc_read_count = {COUNT_WIDTH{1'b0}};
                end
                if (test_id == 22 && stage == 1) begin
                    force u_dut.leaf_read_valid = 1'b0;
                    force u_dut.leaf_read_data = 16'd0;
                end
                if (test_id >= 17 && test_id <= 20 && stage == test_id-16)
                    halt = 1;
                #1;
                if ((expected_error != 0) && (stage == expected_edge)) begin
                    if (!error_valid || error_code !== expected_error)
                        fail("missing pre-edge fault event or wrong priority");
                    if (commit_ok || commit_fire || prepare_valid || pred_valid ||
                        u_dut.leaf_read_en || u_dut.tt_read_en)
                        fail("fault did not inhibit accesses/results before edge");
                end
                if (commit_fire || u_dut.rc_write_en || u_dut.tt_write_en ||
                    u_dut.l1_write_en || u_dut.l2_write_en || u_dut.leaf_write_en)
                    fail("fault/cancel wrote a resource");
                tick;
                if (commit_done)
                    fail("fault/cancel produced commit pulse");
                if (expected_error != 0 && stage >= expected_edge) begin
                    if (!fault || fault_code !== expected_error || request_ready)
                        fail("sticky fault state or admission inhibit");
                end
                else if (fault)
                    fail("early or spurious fault");
                if (test_id == 9)
                    release u_dut.rc_read_valid;
                if (test_id == 10)
                    release u_dut.search_context;
                if (test_id == 11)
                    release u_dut.tt_read_valid;
                if (test_id == 21) begin
                    release u_dut.rc_read_valid;
                    release u_dut.rc_read_count;
                end
                if (test_id == 22) begin
                    release u_dut.leaf_read_valid;
                    release u_dut.leaf_read_data;
                end
            end
            check_image;
            if (expected_error != 0) begin
                fault_tests = fault_tests + 1;
                request_valid = 1; request_tag = 0; request_insert = 0;
                tick;
                if (request_ready || fault_code !== expected_error)
                    fail("new request changed first sticky fault");
            end
            else
                cancel_tests = cancel_tests + 1;
        end
    end
    // External all-or-none gate at E4, including a nonempty exact key.
    test_id = 23; initialize; save_image;
    request_valid = 1; request_insert = 1; request_tag = 12'h121;
    alloc_context = 0; alloc_ptr = 2;
    tick; request_valid = 0; alloc_valid = 1;
    tick; alloc_valid = 0;
    tick; tick;
    commit_allow = 0; #1;
    if (!commit_due || !commit_ok || commit_fire)
        fail("external commit gate added a pipeline stage");
    tick;
    if (commit_done || fault)
        fail("external cancel produced completion/fault");
    check_image; cancel_tests = cancel_tests + 1;
    // Reset a transaction after E1 and verify no delayed metadata write survives.
    test_id = 24; initialize;
    request_valid = 1; request_insert = 1; request_tag = 12'h121;
    alloc_context = 0; alloc_ptr = 2;
    tick; request_valid = 0; alloc_valid = 1;
    tick; alloc_valid = 0; rstn = 0; init_done = 0; #1;
    if (fault || commit_done || request_ready || u_dut.leaf_read_en || u_dut.tt_read_en)
        fail("in-flight reset failed to cancel");
    rstn = 1;
    repeat (5) begin
        tick;
        if (u_dut.rc_write_en || u_dut.tt_write_en || u_dut.leaf_write_en || commit_done)
            fail("late write survived reset");
    end
    cancel_tests = cancel_tests + 1;
    $display("PASS tb_wfq_metadata_faults ptr=%0d depth=%0d fault_cases=%0d cancel_reset_cases=%0d images=%0d",
             PTR_WIDTH, MEM_DEPTH, fault_tests, cancel_tests, checks);
    $finish;
end
endmodule
