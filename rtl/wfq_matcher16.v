// Project : wfq_tag_sort_engine
// File    : wfq_matcher16.v
// Spec    : Design_Spec_V1.2.md, section 7.2
// Function: Combinational LE/LT/MAX selection with four parallel 4-bit groups.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_matcher16 (
    input  wire [15:0]                                  bitmap,
    input  wire [3:0]                                   query,
    input  wire [1:0]                                   mode,

    // All outputs are zero on a miss, including unsupported mode 2'b11.
    output wire                                         found,
    output wire [3:0]                                   index,
    output wire [15:0]                                  onehot,
    output wire                                         exact
);

///////////////////////////////////////////////////////////////////////////////
// Candidate mask and parallel group look-ahead
///////////////////////////////////////////////////////////////////////////////
wire [15:0]                                             candidate;
wire [3:0]                                              group_valid;
wire [3:0]                                              group_select;
wire [15:0]                                             local_select;
genvar                                                  bit_idx;
genvar                                                  group_idx;

generate
    for (bit_idx = 0; bit_idx < 16; bit_idx = bit_idx + 1) begin : g_candidate
        localparam [3:0] LITERAL = bit_idx;
        assign candidate[bit_idx] = bitmap[bit_idx] &
            (((mode == `WFQ_MATCH_LE) & (LITERAL <= query)) |
                ((mode == `WFQ_MATCH_LT) & (LITERAL < query)) |
                (mode == `WFQ_MATCH_MAX));
    end

    for (group_idx = 0; group_idx < 4; group_idx = group_idx + 1) begin : g_group
        assign group_valid[group_idx] = |candidate[group_idx*4 +: 4];
        assign local_select[group_idx*4+3] = candidate[group_idx*4+3];
        assign local_select[group_idx*4+2] = candidate[group_idx*4+2] &
            ~candidate[group_idx*4+3];
        assign local_select[group_idx*4+1] = candidate[group_idx*4+1] &
            ~(|candidate[group_idx*4+2 +: 2]);
        assign local_select[group_idx*4] = candidate[group_idx*4] &
            ~(|candidate[group_idx*4+1 +: 3]);
        assign onehot[group_idx*4 +: 4] = local_select[group_idx*4 +: 4] &
            {4{group_select[group_idx]}};
    end
endgenerate

assign group_select[3] = group_valid[3];
assign group_select[2] = group_valid[2] & ~group_valid[3];
assign group_select[1] = group_valid[1] & ~(|group_valid[3:2]);
assign group_select[0] = group_valid[0] & ~(|group_valid[3:1]);

///////////////////////////////////////////////////////////////////////////////
// One-hot encoding; no 16-entry serial priority chain
///////////////////////////////////////////////////////////////////////////////
assign found = |group_valid;
assign index[3] = |(onehot & 16'hff00);
assign index[2] = |(onehot & 16'hf0f0);
assign index[1] = |(onehot & 16'hcccc);
assign index[0] = |(onehot & 16'haaaa);
assign exact = (mode == `WFQ_MATCH_LE) & found & (index == query);

endmodule

`default_nettype wire
