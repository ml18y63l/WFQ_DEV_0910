// Project : wfq_tag_sort_engine
// File    : wfq_trie_upper_regs.v
// Spec    : Design_Spec_V1.2.md, sections 6.1, 6.3, 7.1 and 12.2
// Function: Single authoritative 32-bit L1 and 512-bit L2 register storage.
// Writes : Whole-word next values, sampled at the commit/init write edge.
// Reads  : Pure combinational views. Flat wiring does not replicate storage.

`timescale 1ns/1ps
`default_nettype none

module wfq_trie_upper_regs (
    input  wire                                         clk,
    input  wire                                         rstn,

    // One independent write per level; caller arbitrates init versus commit.
    input  wire                                         l1_write_en,
    input  wire                                         l1_write_addr,
    input  wire [15:0]                                  l1_write_data,
    input  wire                                         l2_write_en,
    input  wire [4:0]                                   l2_write_addr,
    input  wire [15:0]                                  l2_write_data,

    // L2 address = {bank, a}; word i occupies bits [16*i +: 16].
    input  wire                                         read_bank,
    input  wire [3:0]                                   read_a,
    output wire [15:0]                                  l1_read_data,
    output wire [15:0]                                  l2_read_data,
    output wire [31:0]                                  l1_flat,
    output wire [511:0]                                 l2_flat
);

reg [15:0]                                              l1_d [0:1];
reg [15:0]                                              l2_d [0:31];
integer                                                 reset_idx;
genvar                                                  word_idx;

///////////////////////////////////////////////////////////////////////////////
// Register state: 544 bits total, including both epoch banks
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (reset_idx = 0; reset_idx < 2; reset_idx = reset_idx + 1) begin
            l1_d[reset_idx] <= 16'h0000;
        end
        for (reset_idx = 0; reset_idx < 32; reset_idx = reset_idx + 1) begin
            l2_d[reset_idx] <= 16'h0000;
        end
    end
    else begin
        if (l1_write_en) begin
            l1_d[l1_write_addr] <= l1_write_data;
        end
        if (l2_write_en) begin
            l2_d[l2_write_addr] <= l2_write_data;
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// Combinational read ports and FAST5 look-ahead inputs
///////////////////////////////////////////////////////////////////////////////
assign l1_read_data = l1_d[read_bank];
assign l2_read_data = l2_d[{read_bank, read_a}];

generate
    for (word_idx = 0; word_idx < 2; word_idx = word_idx + 1) begin : g_l1_flat
        assign l1_flat[word_idx*16 +: 16] = l1_d[word_idx];
    end
    for (word_idx = 0; word_idx < 32; word_idx = word_idx + 1) begin : g_l2_flat
        assign l2_flat[word_idx*16 +: 16] = l2_d[word_idx];
    end
endgenerate

endmodule

`default_nettype wire
