// Integrated FAST5 metadata verification with an independent live-slot model.
`timescale 1ns/1ps
module tb_wfq_key_metadata;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
parameter integer ISSUE_INTERVAL = 5;
parameter integer FULL_SWEEP = 1;
parameter integer RANDOM_OPS = 1000;
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

integer ref_count [0:8191];
reg [PTR_WIDTH-1:0] ref_tail [0:8191];
reg [15:0] ref_leaf [0:511];
reg [15:0] ref_parent [0:31];
reg [15:0] ref_root [0:1];
integer slot_key [0:MEM_DEPTH-1];
integer slot_sequence [0:MEM_DEPTH-1];
reg slot_live [0:MEM_DEPTH-1];
integer total, sequence_id, cycle, last_accept;
integer operations, commits, probes, checks, route_count [0:3];
integer i, j, k, seed, choice, selected, random_tag, random_bank;

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

task tick;
    begin
        #4; clk = 1; #1;
        cycle = cycle + 1;
        #4; clk = 0;
    end
endtask

task fail;
    input [511:0] reason;
    begin
        $display("FAIL metadata cycle=%0d op=%0d key=%h/%h phase=%0d reason=%0s fault=%h event=%h",
                 cycle, operations, request_bank, request_tag, u_dut.phase_d, reason, fault_code, error_code);
        $finish;
    end
endtask

function integer unused_slot;
    input integer unused;
    integer idx;
    begin
        unused_slot = -1;
        for (idx = 0; idx < MEM_DEPTH; idx = idx + 1) begin
            if (!slot_live[idx])
                unused_slot = idx;
        end
    end
endfunction

function integer oldest_slot;
    input integer key;
    integer idx, best_sequence;
    begin
        oldest_slot = -1;
        best_sequence = 2147483647;
        for (idx = 0; idx < MEM_DEPTH; idx = idx + 1) begin
            if (slot_live[idx] && (slot_key[idx] == key) &&
                (slot_sequence[idx] < best_sequence)) begin
                oldest_slot = idx;
                best_sequence = slot_sequence[idx];
            end
        end
    end
endfunction

task check_trie;
    integer idx;
    begin
        for (idx = 0; idx < 512; idx = idx + 1) begin
            if (u_dut.u_leaf.mem_d[idx] !== ref_leaf[idx])
                fail("leaf image differs from reference");
            checks = checks + 1;
        end
        for (idx = 0; idx < 32; idx = idx + 1) begin
            if (u_dut.l2_flat[idx*16 +: 16] !== ref_parent[idx])
                fail("parent image differs from reference");
            checks = checks + 1;
        end
        for (idx = 0; idx < 2; idx = idx + 1) begin
            if (u_dut.l1_flat[idx*16 +: 16] !== ref_root[idx])
                fail("root image differs from reference");
            checks = checks + 1;
        end
    end
endtask

task check_key;
    input integer key;
    reg [PTR_WIDTH:0] expected_link;
    begin
        expected_link = (ref_count[key] == 0) ? 0 : {1'b1, ref_tail[key]};
        if ((u_dut.u_rc.u_ram.mem_d[key] !== ref_count[key]) ||
            (u_dut.u_tt.u_ram.mem_d[key] !== expected_link))
            fail("RC/TT differs from reference");
        checks = checks + 1;
    end
endtask

task update_reference;
    input do_insert;
    input integer key;
    input integer ptr;
    integer idx, leaf_idx, parent_idx, bank_idx, removed;
    begin
        if (do_insert) begin
            if ((ptr < 0) || (ptr >= MEM_DEPTH) || slot_live[ptr])
                fail("reference allocation invalid");
            slot_live[ptr] = 1;
            slot_key[ptr] = key;
            slot_sequence[ptr] = sequence_id;
            sequence_id = sequence_id + 1;
            ref_count[key] = ref_count[key] + 1;
            ref_tail[key] = ptr;
            total = total + 1;
        end
        else begin
            removed = oldest_slot(key);
            if (removed < 0)
                fail("reference extract has no live item");
            slot_live[removed] = 0;
            ref_count[key] = ref_count[key] - 1;
            if (ref_count[key] == 0)
                ref_tail[key] = 0;
            total = total - 1;
        end
        // Derive presence from counts and aggregate words, not RTL clear tests.
        leaf_idx = key / 16;
        parent_idx = key / 256;
        bank_idx = key / 4096;
        for (idx = 0; idx < 16; idx = idx + 1)
            ref_leaf[leaf_idx][idx] = ref_count[leaf_idx*16+idx] != 0;
        for (idx = 0; idx < 16; idx = idx + 1)
            ref_parent[parent_idx][idx] = ref_leaf[parent_idx*16+idx] != 0;
        for (idx = 0; idx < 16; idx = idx + 1)
            ref_root[bank_idx][idx] = ref_parent[bank_idx*16+idx] != 0;
    end
endtask

task operate;
    input do_insert;
    input bank;
    input [11:0] tag;
    input allow_commit;
    integer key, expected_pred, expected_path, ptr, old_rc;
    integer stage, idx, start_edge, expected_new_rc;
    reg [PTR_WIDTH-1:0] expected_ptr;
    reg [PTR_WIDTH:0] expected_tt_link;
    reg expected_fallback, due, firing, marker_write, parent_write, root_write;
    reg expected_tt_write;
    reg [15:0] next_leaf, next_parent, next_root;
    begin
        key = bank*4096 + tag;
        ptr = unused_slot(0);
        old_rc = ref_count[key];
        expected_pred = -1;
        if (do_insert) begin
            if (ptr < 0)
                fail("test attempted insert without capacity");
            for (idx = 0; idx <= tag; idx = idx + 1) begin
                if (ref_count[bank*4096+idx] != 0)
                    expected_pred = idx;
            end
        end
        else if (old_rc == 0)
            fail("test attempted extraction of missing key");
        expected_ptr = (expected_pred < 0) ? 0 : ref_tail[bank*4096+expected_pred];
        expected_path = 0;
        if (expected_pred >= 0) begin
            if ((expected_pred / 16) == (tag / 16))
                expected_path = 1;
            else if ((expected_pred / 256) == (tag / 256))
                expected_path = 2;
            else
                expected_path = 3;
        end
        expected_fallback = (expected_path == 2) || (expected_path == 3);
        expected_new_rc = do_insert ? old_rc+1 : old_rc-1;
        expected_tt_write = do_insert || old_rc == 1;
        expected_tt_link = do_insert ? {1'b1, ptr[PTR_WIDTH-1:0]} : 0;
        next_leaf = ref_leaf[key/16];
        next_parent = ref_parent[key/256];
        next_root = ref_root[bank];
        next_leaf[tag%16] = expected_new_rc != 0;
        next_parent[(tag/16)%16] = next_leaf != 0;
        next_root[tag/256] = next_parent != 0;
        marker_write = next_leaf != ref_leaf[key/16];
        parent_write = next_parent != ref_parent[key/256];
        root_write = next_root != ref_root[bank];

        request_valid = 1; request_insert = do_insert;
        request_bank = bank; request_tag = tag; request_context = ~request_context;
        alloc_valid = 0; alloc_context = request_context;
        alloc_ptr = ptr; commit_allow = allow_commit;
        #1;
        if (!request_ready)
            fail("request window not open at the next E5");
        start_edge = cycle;
        if ((last_accept >= 0) && (start_edge-last_accept != 5))
            fail("accepted requests not exactly five edges apart");
        last_accept = start_edge;
        operations = operations + 1;

        for (stage = 0; stage < 5; stage = stage + 1) begin
            if (stage == 1)
                alloc_valid = do_insert;
            #1;
            due = do_insert ? (stage == 4) : (stage == 1);
            firing = due && allow_commit;
            if (fault || error_valid)
                fail("unexpected fault on legal operation");
            if ((stage != 0) && request_ready)
                fail("issue interval shorter than five");
            if ((u_dut.leaf_read_en !== ((stage == 0) || (do_insert && stage == 1 && expected_fallback))) ||
                (u_dut.rc_read_en !== (stage == 0)) ||
                (u_dut.tt_read_en !== (do_insert && stage == 2 && expected_pred >= 0)))
                fail("RAM read enables violate FAST5 edge schedule");
            if (stage == 0 && u_dut.leaf_addr !== key/16)
                fail("E0 exact leaf address");
            if (do_insert && stage == 1 && expected_fallback &&
                u_dut.leaf_addr !== (bank*256+expected_pred/16))
                fail("E1 fallback leaf address");
            if (do_insert && stage == 2 && expected_pred >= 0 &&
                u_dut.u_tt.read_key !== (bank*4096+expected_pred))
                fail("E2 TT address");
            if ((pred_valid !== (do_insert && stage == 3)) ||
                (prepare_valid !== (do_insert ? stage == 3 : stage == 1)))
                fail("predecessor/prepare is early or late");
            if (do_insert && stage == 3) begin
                if ((pred_found !== (expected_pred >= 0)) ||
                    (pred_context !== request_context) || (pred_bank !== bank) ||
                    (pred_tag !== ((expected_pred < 0) ? 0 : expected_pred)) ||
                    (pred_ptr !== expected_ptr) || (pred_exact !== (expected_pred == tag)) ||
                    (pred_path !== expected_path))
                    fail("predecessor differs from independent set max");
                route_count[expected_path] = route_count[expected_path] + 1;
            end
            if (prepare_valid && ((prepare_old_count !== old_rc) ||
                (prepare_new_count !== expected_new_rc)))
                fail("prepared RC arithmetic");
            if ((commit_due !== due) || (commit_ok !== due) ||
                (commit_fire !== firing) || (due && commit_context !== request_context))
                fail("commit boundary or external gate");
            if ((u_dut.rc_write_en !== firing) ||
                (u_dut.tt_write_en !== (firing && expected_tt_write)) ||
                (u_dut.leaf_write_en !== (firing && marker_write)) ||
                (u_dut.l2_write_en !== (firing && parent_write)) ||
                (u_dut.l1_write_en !== (firing && root_write)))
                fail("unexpected or missing physical write");
            if (firing) begin
                if ((u_dut.rc_write_key !== key) ||
                    (u_dut.rc_write_count !== expected_new_rc) ||
                    (expected_tt_write && ((u_dut.tt_write_key !== key) ||
                    (u_dut.tt_write_link !== expected_tt_link))) ||
                    (marker_write && ((u_dut.leaf_addr !== key/16) ||
                    (u_dut.leaf_write_data !== next_leaf))) ||
                    (parent_write && u_dut.l2_write_data !== next_parent) ||
                    (root_write && u_dut.l1_write_data !== next_root))
                    fail("commit write data/key differs from reference");
            end
            if (u_dut.leaf_read_en && u_dut.leaf_write_en)
                fail("L3 single-port collision");
            tick;
            if (commit_done !== firing)
                fail("commit_done not aligned to the write edge");
            if (firing) begin
                update_reference(do_insert, key, ptr);
                commits = commits + 1;
            end
            check_key(key);
            request_valid = 0;
            if (stage == 1)
                alloc_valid = 0;
        end
        if (!allow_commit)
            probes = probes + 1;
        check_trie;
    end
endtask

task insert_key;
    input bank;
    input [11:0] tag;
    begin
        operate(1'b1, bank, tag, 1'b1);
    end
endtask

task drain;
    integer key;
    begin
        for (key = 0; key < 8192; key = key + 1) begin
            while (ref_count[key] > 0)
                operate(1'b0, key >= 4096, key%4096, 1'b1);
        end
    end
endtask

initial begin
    clk = 0; rstn = 1; init_done = 0; init_write_en = 0; init_write_addr = 0; halt = 0;
    request_valid = 0; request_insert = 0; request_context = 0; request_bank = 0; request_tag = 0;
    alloc_valid = 0; alloc_context = 0; alloc_ptr = 0; commit_allow = 1;
    total = 0; sequence_id = 0; cycle = 0; last_accept = -1;
    operations = 0; commits = 0; probes = 0; checks = 0; seed = 32'h51a92026;
    for (i = 0; i < 8192; i = i + 1) begin
        ref_count[i] = 0; ref_tail[i] = 0;
    end
    for (i = 0; i < 512; i = i + 1)
        ref_leaf[i] = 0;
    for (i = 0; i < 32; i = i + 1)
        ref_parent[i] = 0;
    ref_root[0] = 0; ref_root[1] = 0;
    for (i = 0; i < 4; i = i + 1)
        route_count[i] = 0;
    for (i = 0; i < MEM_DEPTH; i = i + 1) begin
        slot_live[i] = 0; slot_key[i] = 0; slot_sequence[i] = 0;
    end
    #1; rstn = 0; #1; rstn = 1;
    for (i = 0; i < 8192; i = i + 1) begin
        init_write_en = 1; init_write_addr = i;
        tick;
    end
    init_write_en = 0; tick; init_done = 1;
    #1;
    check_trie;

    // A, B, C, NONE, exact duplicates, same tag in the other bank, end literals.
    insert_key(0, 12'h120);
    insert_key(0, 12'h12f);
    insert_key(0, 12'h130);
    insert_key(0, 12'h200);
    insert_key(1, 12'h130);
    insert_key(0, 12'h120);
    operate(0, 0, 12'h120, 1);
    operate(0, 0, 12'h120, 1);
    insert_key(0, 12'h000);
    insert_key(0, 12'hfff);
    insert_key(1, 12'h000);
    insert_key(1, 12'hfff);
    drain;

    // Two sparse banks; all input tags probe real search/TT with commit inhibited.
    insert_key(0, 12'h013); insert_key(0, 12'h017);
    insert_key(0, 12'h140); insert_key(0, 12'heff);
    insert_key(1, 12'h001); insert_key(1, 12'h111);
    insert_key(1, 12'hab0); insert_key(1, 12'hffe);
    if (FULL_SWEEP) begin
        for (i = 0; i < 8192; i = i + 1)
            operate(1, i >= 4096, i%4096, 0);
    end
    else begin
        operate(1, 0, 12'h010, 0);
        operate(1, 0, 12'h018, 0);
        operate(1, 0, 12'h100, 0);
        operate(1, 1, 12'hfff, 0);
    end
    drain;

    // RC must reach full capacity; pointer 0 is the final valid allocated tail.
    for (i = 0; i < MEM_DEPTH; i = i + 1)
        insert_key(0, 12'haaa);
    if ((u_dut.u_rc.u_ram.mem_d[12'haaa] !== MEM_DEPTH) ||
        (u_dut.u_tt.u_ram.mem_d[12'haaa] !== {1'b1, {PTR_WIDTH{1'b0}}}))
        fail("full count or valid zero-pointer tail");
    for (i = 0; i < MEM_DEPTH; i = i + 1)
        operate(0, 0, 12'haaa, 1);

    // Random accepted stream: unique allocated slots and FCFS removal per key.
    for (i = 0; i < RANDOM_OPS; i = i + 1) begin
        choice = $random(seed) & 32'h7fffffff;
        if ((total == 0) || ((total < MEM_DEPTH) && ((choice % 3) != 0))) begin
            random_bank = ($random(seed) & 32'h7fffffff) % 2;
            random_tag = ($random(seed) & 32'h7fffffff) % 4096;
            if ((i % 4) == 0)
                random_tag = 12'h120;
            insert_key(random_bank, random_tag);
        end
        else begin
            selected = -1;
            for (j = 0; j < MEM_DEPTH; j = j + 1) begin
                if (slot_live[j] && ((selected < 0) || (slot_key[j] < selected)))
                    selected = slot_key[j];
            end
            operate(0, selected >= 4096, selected%4096, 1);
        end
    end
    drain;
    for (i = 0; i < 8192; i = i + 1)
        check_key(i);
    if (total != 0 || route_count[0] == 0 || route_count[1] == 0 ||
        route_count[2] == 0 || route_count[3] == 0)
        fail("missing route coverage or final drain");
    $display("PASS tb_wfq_key_metadata ptr=%0d depth=%0d requests=%0d commits=%0d probes=%0d checks=%0d gap=5 paths=%0d/%0d/%0d/%0d",
             PTR_WIDTH, MEM_DEPTH, operations, commits, probes, checks,
             route_count[0], route_count[1], route_count[2], route_count[3]);
    $finish;
end
endmodule
