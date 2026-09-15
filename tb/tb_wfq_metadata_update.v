`timescale 1ns/1ps
module tb_wfq_metadata_update;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
`include "wfq_clog2.vh"
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
reg valid, is_insert, trie_exact;
reg [11:0] tag;
reg [PTR_WIDTH-1:0] new_ptr;
reg [COUNT_WIDTH-1:0] old_count;
reg [15:0] old_root, old_parent, old_leaf;
wire [COUNT_WIDTH-1:0] new_count;
wire tt_write, l1_write, l2_write, l3_write;
wire [PTR_WIDTH:0] tt_link;
wire [15:0] l1_data, l2_data, l3_data;
wire [3:0] error_code;
integer i, seed, choice, checks;

wfq_metadata_update #(.PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH)) u_dut (
    .valid(valid), .is_insert(is_insert), .tag(tag), .new_ptr(new_ptr),
    .old_count(old_count), .old_root(old_root), .old_parent(old_parent),
    .old_leaf(old_leaf), .trie_exact(trie_exact), .new_count(new_count),
    .tt_write(tt_write), .tt_link(tt_link), .l1_write(l1_write), .l1_data(l1_data),
    .l2_write(l2_write), .l2_data(l2_data), .l3_write(l3_write), .l3_data(l3_data),
    .error_code(error_code)
);

task check;
    integer err, a, b, c, count_result;
    reg [15:0] leaf_result, parent_result, root_result;
    reg expected_tt, expected_l1, expected_l2, expected_l3;
    reg [PTR_WIDTH:0] expected_link;
    begin
        a = tag / 256; b = (tag / 16) % 16; c = tag % 16;
        err = 0;
        if (valid) begin
            if ((is_insert && old_count >= MEM_DEPTH) ||
                (!is_insert && (old_count == 0 || old_count > MEM_DEPTH)))
                err = 1;
            else if ((old_root[a] != (old_parent != 0)) ||
                     (old_parent[b] != (old_leaf != 0)) ||
                     (old_leaf[c] != (old_count != 0)) ||
                     (is_insert && trie_exact != (old_count != 0)))
                err = 2;
            else if (is_insert && new_ptr >= MEM_DEPTH)
                err = 7;
        end
        leaf_result = old_leaf; parent_result = old_parent; root_result = old_root;
        count_result = 0; expected_tt = 0; expected_link = 0;
        expected_l1 = 0; expected_l2 = 0; expected_l3 = 0;
        if (valid && err == 0) begin
            count_result = is_insert ? old_count+1 : old_count-1;
            leaf_result[c] = count_result != 0;
            parent_result[b] = leaf_result != 0;
            root_result[a] = parent_result != 0;
            expected_l3 = leaf_result != old_leaf;
            expected_l2 = parent_result != old_parent;
            expected_l1 = root_result != old_root;
            expected_tt = is_insert || (count_result == 0);
            expected_link = is_insert ? {1'b1, new_ptr} : 0;
        end
        #1;
        if ((error_code !== err) || (new_count !== count_result) ||
            (tt_write !== expected_tt) || (tt_link !== expected_link) ||
            (l1_write !== expected_l1) || (l2_write !== expected_l2) ||
            (l3_write !== expected_l3) ||
            (l1_write && l1_data !== root_result) ||
            (l2_write && l2_data !== parent_result) ||
            (l3_write && l3_data !== leaf_result)) begin
            $display("FAIL update checks=%0d tag=%h count=%0d ins=%b expect_err=%0d got_err=%0d",
                     checks, tag, old_count, is_insert, err, error_code);
            $finish;
        end
        checks = checks + 1;
    end
endtask

initial begin
    valid = 1; is_insert = 1; tag = 12'h5a7; new_ptr = MEM_DEPTH-1;
    old_count = 0; old_root = 0; old_parent = 0; old_leaf = 0; trie_exact = 0;
    checks = 0; seed = 32'h61a92026;
    // Every exact leaf bitmap: first/duplicate insertion and last-key removal.
    for (i = 0; i < 65536; i = i + 1) begin
        old_leaf = i;
        old_parent = (i == 0) ? 0 : 16'h0400;
        old_root = (old_parent == 0) ? 0 : 16'h0020;
        old_count = old_leaf[7] ? 1 : 0; trie_exact = old_count != 0;
        is_insert = 1; check;
        is_insert = 0; check;
    end
    for (i = 0; i < 8192; i = i + 1) begin
        tag = $random(seed); old_leaf = $random(seed);
        old_parent = $random(seed); old_root = $random(seed);
        old_parent[tag[7:4]] = old_leaf != 0;
        old_root[tag[11:8]] = old_parent != 0;
        choice = $random(seed) & 32'h7fffffff;
        old_count = old_leaf[tag[3:0]] ? 1+(choice%MEM_DEPTH) : 0;
        is_insert = $random(seed); trie_exact = old_count != 0;
        new_ptr = ($random(seed) & 32'h7fffffff) % MEM_DEPTH;
        valid = (i%7) != 0;
        case (i%8)
            1: old_root[tag[11:8]] = ~old_root[tag[11:8]];
            2: old_parent[tag[7:4]] = ~old_parent[tag[7:4]];
            3: old_leaf[tag[3:0]] = ~old_leaf[tag[3:0]];
            4: trie_exact = ~trie_exact;
            5: old_count = MEM_DEPTH;
            6: old_count = 2;
            7: if (PTR_WIDTH > wfq_clog2(MEM_DEPTH))
                   new_ptr = MEM_DEPTH;
        endcase
        check;
    end
    // Explicit maximum count decrement must preserve markers and TT tail.
    valid = 1; is_insert = 0; old_count = MEM_DEPTH; tag = 0;
    old_leaf = 1; old_parent = 1; old_root = 1; trie_exact = 1; new_ptr = 0;
    check;
    $display("PASS tb_wfq_metadata_update ptr=%0d depth=%0d checks=%0d", PTR_WIDTH, MEM_DEPTH, checks);
    $finish;
end
endmodule
