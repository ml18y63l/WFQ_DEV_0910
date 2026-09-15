// Project : wfq_tag_sort_engine
// File    : wfq_translation_table.v
// Spec    : Design_Spec_V1.2.md, sections 6.4 and 8
// Function: Banked TT tail links; one 8192-row 1R1W copy.

`timescale 1ns/1ps
`default_nettype none

module wfq_translation_table #(
    parameter integer PTR_WIDTH = 10
) (
    clk,
    rstn,
    read_en,
    read_key,
    write_en,
    write_key,
    write_link,
    read_valid,
    read_link
);

input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             read_en;
input  wire [12:0]                                      read_key;
input  wire                                             write_en;
input  wire [12:0]                                      write_key;
input  wire [PTR_WIDTH:0]                               write_link;
output wire                                             read_valid;
output wire [PTR_WIDTH:0]                               read_link;

generate
    if ((PTR_WIDTH < 4) || (PTR_WIDTH > 16)) begin : g_bad_parameters
        wfq_error_invalid_metadata_table_parameter u_error ();
    end
endgenerate

// All metadata writes complete at commit; no deferred TT/RC overlay is needed.
// Same-edge physical write forwarding remains provided by the shared wrapper.
wfq_sync_ram_1r1w #(
    .DATA_WIDTH                                         (PTR_WIDTH+1),
    .MEM_DEPTH                                          (8192)
) u_ram (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (read_en),
    .read_addr                                          (read_key),
    .write_en                                           (write_en),
    .write_addr                                         (write_key),
    .write_data                                         (write_link),
    .commit_valid                                       (1'b0),
    .commit_addr                                        (13'd0),
    .commit_data                                        ({(PTR_WIDTH+1){1'b0}}),
    .pending_valid                                      (1'b0),
    .pending_addr                                       (13'd0),
    .pending_data                                       ({(PTR_WIDTH+1){1'b0}}),
    .read_valid                                         (read_valid),
    .read_data                                          (read_link)
);

endmodule

`default_nettype wire
