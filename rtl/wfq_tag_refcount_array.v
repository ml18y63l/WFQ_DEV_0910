// Project : wfq_tag_sort_engine
// File    : wfq_tag_refcount_array.v
// Spec    : Design_Spec_V1.2.md, sections 6.4 and 8
// Function: Banked RC words; width derives from capacity, not pointer width.

`timescale 1ns/1ps
`default_nettype none

module wfq_tag_refcount_array #(
    parameter integer MEM_DEPTH = 1024
) (
    clk,
    rstn,
    read_en,
    read_key,
    write_en,
    write_key,
    write_count,
    read_valid,
    read_count
);

`include "wfq_clog2.vh"
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);

input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             read_en;
input  wire [12:0]                                      read_key;
input  wire                                             write_en;
input  wire [12:0]                                      write_key;
input  wire [COUNT_WIDTH-1:0]                           write_count;
output wire                                             read_valid;
output wire [COUNT_WIDTH-1:0]                           read_count;

generate
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) || ((MEM_DEPTH & (MEM_DEPTH-1)) != 0)) begin : g_bad_parameters
        wfq_error_invalid_metadata_table_parameter u_error ();
    end
endgenerate

// All metadata writes complete at commit; no deferred TT/RC overlay is needed.
// Same-edge physical write forwarding remains provided by the shared wrapper.
wfq_sync_ram_1r1w #(
    .DATA_WIDTH                                         (COUNT_WIDTH),
    .MEM_DEPTH                                          (8192)
) u_ram (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (read_en),
    .read_addr                                          (read_key),
    .write_en                                           (write_en),
    .write_addr                                         (write_key),
    .write_data                                         (write_count),
    .commit_valid                                       (1'b0),
    .commit_addr                                        (13'd0),
    .commit_data                                        ({(COUNT_WIDTH){1'b0}}),
    .pending_valid                                      (1'b0),
    .pending_addr                                       (13'd0),
    .pending_data                                       ({(COUNT_WIDTH){1'b0}}),
    .read_valid                                         (read_valid),
    .read_data                                          (read_count)
);

endmodule

`default_nettype wire
