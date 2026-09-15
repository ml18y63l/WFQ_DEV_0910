// Project : wfq_tag_sort_engine
// File    : wfq_trie_search.v
// Spec    : Design_Spec_V1.2.md, sections 7.2 through 7.6 and 10.2
// Function: FAST5 same-bank predecessor search; E0 exact leaf, E1 fallback,
//           combinational result during E1..E2 for the E2 TT read.
// Contract: request is an accepted pulse, at least five edges apart.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_trie_search #(
    parameter integer ISSUE_INTERVAL = 5
) (
    input  wire                                         clk,
    input  wire                                         rstn,
    input  wire                                         halt,

    // Already accepted request and the single authoritative upper-level state.
    input  wire                                         request,
    input  wire                                         request_context,
    input  wire                                         request_bank,
    input  wire [11:0]                                  request_tag,
    input  wire [31:0]                                  l1_flat,
    input  wire [511:0]                                 l2_flat,

    // Shared L3 port; caller arbitrates extraction, init and commit writes.
    output wire                                         leaf_read_en,
    output wire [8:0]                                   leaf_read_addr,
    input  wire                                         leaf_read_valid,
    input  wire [15:0]                                  leaf_read_data,

    // Sample at E2, not one edge later. Snapshot words remain held afterwards.
    output wire                                         result_valid,
    output wire                                         result_context,
    output wire                                         result_bank,
    output wire                                         result_found,
    output wire [11:0]                                  result_tag,
    output wire                                         result_exact,
    output wire [1:0]                                   result_path,
    output wire [15:0]                                  old_root,
    output wire [15:0]                                  old_parent,
    output wire [15:0]                                  old_leaf,
    output wire [3:0]                                   error_code
);

localparam integer FALLBACK_READ_EDGE = ISSUE_INTERVAL - 4;
localparam integer TT_READ_EDGE       = ISSUE_INTERVAL - 3;

reg                                                     search_valid_d1;
reg                                                     search_valid_d2;
reg                                                     context_d;
reg                                                     bank_d;
reg [11:0]                                              tag_d;
reg                                                     a_found_d;
reg [3:0]                                               a_index_d;
reg                                                     fallback_d;
reg [7:0]                                               fallback_prefix_d;
reg [1:0]                                               path_d;
reg [15:0]                                              old_root_d;
reg [15:0]                                              old_parent_d;
reg [15:0]                                              old_leaf_d;
reg [3:0]                                               early_error_d;

generate
    if ((ISSUE_INTERVAL != 5) || (FALLBACK_READ_EDGE != 1) ||
        (TT_READ_EDGE != 2)) begin : g_bad_interval
        wfq_error_stage2_requires_issue_interval_5 u_error ();
    end
endgenerate

///////////////////////////////////////////////////////////////////////////////
// FAST5: all 32 parent MAX results are combinational, computed in parallel
///////////////////////////////////////////////////////////////////////////////
wire [31:0]                                             parent_max_found;
wire [127:0]                                            parent_max_index;
wire [511:0]                                            parent_max_onehot;
wire [31:0]                                             parent_max_exact;
genvar                                                  parent_idx;

generate
    for (parent_idx = 0; parent_idx < 32; parent_idx = parent_idx + 1) begin : g_parent_max
        wfq_matcher16 u_max (
            .bitmap                                     (l2_flat[parent_idx*16 +: 16]),
            .query                                      (4'd0),
            .mode                                       (`WFQ_MATCH_MAX),
            .found                                      (parent_max_found[parent_idx]),
            .index                                      (parent_max_index[parent_idx*4 +: 4]),
            .onehot                                     (parent_max_onehot[parent_idx*16 +: 16]),
            .exact                                      (parent_max_exact[parent_idx])
        );
    end
endgenerate

///////////////////////////////////////////////////////////////////////////////
// A exact-prefix LE, B same-parent LT, C root LT plus precomputed parent MAX
///////////////////////////////////////////////////////////////////////////////
wire [15:0]                                             root_word;
wire [15:0]                                             parent_word;
wire                                                    a_found;
wire [3:0]                                              a_index;
wire [15:0]                                             a_onehot;
wire                                                    a_exact;
wire                                                    b_found;
wire [3:0]                                              b_index;
wire [15:0]                                             b_onehot;
wire                                                    b_exact;
wire                                                    c_found;
wire [3:0]                                              c_index;
wire [15:0]                                             c_onehot;
wire                                                    c_exact;
wire                                                    c_parent_found;
wire [3:0]                                              c_parent_index;
wire                                                    fallback_needed;
wire [7:0]                                              fallback_prefix;
wire                                                    exact_path_bad;
wire                                                    selected_c_bad;
wire [3:0]                                              first_error;

assign root_word = l1_flat[bank_d*16 +: 16];
assign parent_word = l2_flat[{bank_d, tag_d[11:8]}*16 +: 16];
assign c_parent_found = parent_max_found[{bank_d, c_index}];
assign c_parent_index = parent_max_index[{bank_d, c_index}*4 +: 4];

wfq_matcher16 u_a (
    .bitmap                                             (leaf_read_data),
    .query                                              (tag_d[3:0]),
    .mode                                               (`WFQ_MATCH_LE),
    .found                                              (a_found),
    .index                                              (a_index),
    .onehot                                             (a_onehot),
    .exact                                              (a_exact)
);

wfq_matcher16 u_b (
    .bitmap                                             (parent_word),
    .query                                              (tag_d[7:4]),
    .mode                                               (`WFQ_MATCH_LT),
    .found                                              (b_found),
    .index                                              (b_index),
    .onehot                                             (b_onehot),
    .exact                                              (b_exact)
);

wfq_matcher16 u_c (
    .bitmap                                             (root_word),
    .query                                              (tag_d[11:8]),
    .mode                                               (`WFQ_MATCH_LT),
    .found                                              (c_found),
    .index                                              (c_index),
    .onehot                                             (c_onehot),
    .exact                                              (c_exact)
);

assign exact_path_bad = (root_word[tag_d[11:8]] != (|parent_word)) |
    (parent_word[tag_d[7:4]] != (|leaf_read_data));
assign selected_c_bad = ~a_found & ~b_found & c_found & ~c_parent_found;
assign first_error = !leaf_read_valid ? `WFQ_FAULT_SCHEDULE :
    ((exact_path_bad | selected_c_bad) ? `WFQ_FAULT_METADATA : `WFQ_FAULT_NONE);
assign fallback_needed = ~a_found & (b_found | (c_found & c_parent_found));
assign fallback_prefix = b_found ? {tag_d[11:8], b_index} : {c_index, c_parent_index};

assign leaf_read_en = rstn & ~halt &
    (request | (search_valid_d1 & fallback_needed & (first_error == `WFQ_FAULT_NONE)));
assign leaf_read_addr = request ? {request_bank, request_tag[11:4]} :
    {bank_d, fallback_prefix};

///////////////////////////////////////////////////////////////////////////////
// The exact snapshot is captured only at E1; the fallback cannot overwrite it
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        search_valid_d1 <= 1'b0;
        search_valid_d2 <= 1'b0;
        context_d <= 1'b0;
        bank_d <= 1'b0;
        tag_d <= 12'd0;
        a_found_d <= 1'b0;
        a_index_d <= 4'd0;
        fallback_d <= 1'b0;
        fallback_prefix_d <= 8'd0;
        path_d <= 2'd0;
        old_root_d <= 16'd0;
        old_parent_d <= 16'd0;
        old_leaf_d <= 16'd0;
        early_error_d <= `WFQ_FAULT_NONE;
    end
    else begin
        search_valid_d1 <= request & ~halt;
        search_valid_d2 <= search_valid_d1 & ~halt;
        if (request && !halt) begin
            context_d <= request_context;
            bank_d <= request_bank;
            tag_d <= request_tag;
        end
        if (search_valid_d1 && !halt) begin
            a_found_d <= a_found;
            a_index_d <= a_index;
            fallback_d <= fallback_needed;
            fallback_prefix_d <= fallback_prefix;
            path_d <= a_found ? 2'd1 : (b_found ? 2'd2 : (c_found ? 2'd3 : 2'd0));
            old_root_d <= root_word;
            old_parent_d <= parent_word;
            old_leaf_d <= leaf_read_data;
            early_error_d <= first_error;
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// E1..E2 result drives the TT address directly, without another output stage
///////////////////////////////////////////////////////////////////////////////
wire                                                    fallback_found;
wire [3:0]                                              fallback_index;
wire [15:0]                                             fallback_onehot;
wire                                                    fallback_exact;
wire [3:0]                                              second_error;

wfq_matcher16 u_fallback (
    .bitmap                                             (leaf_read_data),
    .query                                              (4'd0),
    .mode                                               (`WFQ_MATCH_MAX),
    .found                                              (fallback_found),
    .index                                              (fallback_index),
    .onehot                                             (fallback_onehot),
    .exact                                              (fallback_exact)
);

assign second_error = (early_error_d != `WFQ_FAULT_NONE) ? early_error_d :
    ((fallback_d && !leaf_read_valid) ? `WFQ_FAULT_SCHEDULE :
    ((fallback_d && !fallback_found) ? `WFQ_FAULT_METADATA : `WFQ_FAULT_NONE));
assign error_code = (!rstn || halt) ? `WFQ_FAULT_NONE :
    (search_valid_d1 ? first_error : (search_valid_d2 ? second_error : `WFQ_FAULT_NONE));
assign result_valid = search_valid_d2 & ~halt;
assign result_context = context_d;
assign result_bank = bank_d;
assign result_found = result_valid & (second_error == `WFQ_FAULT_NONE) &
    (a_found_d | (fallback_d & fallback_found));
assign result_tag = !result_found ? 12'd0 :
    (a_found_d ? {tag_d[11:4], a_index_d} : {fallback_prefix_d, fallback_index});
assign result_exact = result_found & (result_tag == tag_d);
assign result_path = result_found ? path_d : 2'd0;
assign old_root = old_root_d;
assign old_parent = old_parent_d;
assign old_leaf = old_leaf_d;

endmodule

`default_nettype wire
