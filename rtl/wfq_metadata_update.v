// Project : wfq_tag_sort_engine
// File    : wfq_metadata_update.v
// Spec    : Design_Spec_V1.2.md, sections 7.7, 8 and 13.2
// Function: Combinational metadata write plan, with all-or-none local checks.
// Timing  : Insert plan is ready before E3; extract plan drives E1 directly.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_metadata_update #(
    parameter integer PTR_WIDTH = 10,
    parameter integer MEM_DEPTH = 1024
) (
    valid,
    is_insert,
    tag,
    new_ptr,
    old_count,
    old_root,
    old_parent,
    old_leaf,
    trie_exact,
    new_count,
    tt_write,
    tt_link,
    l1_write,
    l1_data,
    l2_write,
    l2_data,
    l3_write,
    l3_data,
    error_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH  = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);

input  wire                                             valid;
input  wire                                             is_insert;
input  wire [11:0]                                      tag;
input  wire [PTR_WIDTH-1:0]                             new_ptr;
input  wire [COUNT_WIDTH-1:0]                           old_count;
input  wire [15:0]                                      old_root;
input  wire [15:0]                                      old_parent;
input  wire [15:0]                                      old_leaf;
input  wire                                             trie_exact;

output wire [COUNT_WIDTH-1:0]                           new_count;
output wire                                             tt_write;
output wire [PTR_WIDTH:0]                               tt_link;
output wire                                             l1_write;
output wire [15:0]                                      l1_data;
output wire                                             l2_write;
output wire [15:0]                                      l2_data;
output wire                                             l3_write;
output wire [15:0]                                      l3_data;
output wire [3:0]                                       error_code;

wire [15:0]                                             root_mask;
wire [15:0]                                             parent_mask;
wire [15:0]                                             leaf_mask;
wire                                                    count_bad;
wire                                                    marker_bad;
wire                                                    pointer_bad;
wire                                                    plan_ok;
wire                                                    first_key;
wire                                                    last_key;
wire                                                    leaf_empty_after;
wire                                                    parent_empty_after;

generate
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0) ||
        (PTR_WIDTH < 4) || (PTR_WIDTH > 16) || (PTR_WIDTH < ADDR_WIDTH)) begin : g_bad_parameters
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
endgenerate

assign root_mask = 16'h0001 << tag[11:8];
assign parent_mask = 16'h0001 << tag[7:4];
assign leaf_mask = 16'h0001 << tag[3:0];
assign count_bad = is_insert ? (old_count >= MEM_DEPTH) :
    ((old_count == 0) | (old_count > MEM_DEPTH));
assign marker_bad = (old_root[tag[11:8]] != (|old_parent)) |
    (old_parent[tag[7:4]] != (|old_leaf)) |
    (old_leaf[tag[3:0]] != (old_count != 0)) |
    (is_insert & (trie_exact != (old_count != 0)));
assign pointer_bad = is_insert & (new_ptr >= MEM_DEPTH);
assign error_code = !valid ? `WFQ_FAULT_NONE :
    (count_bad ? `WFQ_FAULT_RC : (marker_bad ? `WFQ_FAULT_METADATA :
    (pointer_bad ? `WFQ_FAULT_POINTER : `WFQ_FAULT_NONE)));
assign plan_ok = valid & (error_code == `WFQ_FAULT_NONE);
assign first_key = is_insert & (old_count == 0);
assign last_key = ~is_insert & (old_count == 1);

// Parallel equality tests avoid serial leaf-clear -> parent-clear zero tests.
assign leaf_empty_after = (old_leaf == leaf_mask);
assign parent_empty_after = leaf_empty_after & (old_parent == parent_mask);
assign new_count = !plan_ok ? {COUNT_WIDTH{1'b0}} :
    (is_insert ? (old_count + 1'b1) : (old_count - 1'b1));
assign tt_write = plan_ok & (is_insert | last_key);
assign tt_link = (plan_ok && is_insert) ? {1'b1, new_ptr} : {(PTR_WIDTH+1){1'b0}};
assign l3_write = plan_ok & (first_key | last_key);
assign l2_write = plan_ok &
    ((first_key & ~old_parent[tag[7:4]]) | (last_key & leaf_empty_after));
assign l1_write = plan_ok &
    ((first_key & ~old_root[tag[11:8]]) | (last_key & parent_empty_after));
assign l3_data = is_insert ? (old_leaf | leaf_mask) : (old_leaf & ~leaf_mask);
assign l2_data = is_insert ? (old_parent | parent_mask) : (old_parent & ~parent_mask);
assign l1_data = is_insert ? (old_root | root_mask) : (old_root & ~root_mask);

endmodule

`default_nettype wire
