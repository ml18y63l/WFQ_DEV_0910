// Project : wfq_tag_sort_engine
// File    : wfq_init_ctrl.v
// Spec    : Design_Spec_V1.2.md, sections 2 and 12.2
// Function: Parallel metadata/FREE initialization and one guard edge.
// Timing  : First released edge is R0. Last write is R_(INIT_WRITES-1).
//           init_guard is sampled at R_INIT_WRITES; init_done rises after it.

`timescale 1ns/1ps
`default_nettype none

module wfq_init_ctrl #(
    parameter integer PTR_WIDTH = 10,
    parameter integer MEM_DEPTH = 1024
) (
    clk,
    rstn,
    init_done,
    init_guard,
    meta_write_en,
    meta_write_addr,
    l1_write_en,
    l1_write_addr,
    l2_write_en,
    l2_write_addr,
    l3_write_en,
    l3_write_addr,
    free_write_en,
    free_write_addr,
    free_write_data
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH  = wfq_clog2(MEM_DEPTH);
localparam integer META_DEPTH  = 8192;
localparam integer INIT_WRITES = (MEM_DEPTH > META_DEPTH) ? MEM_DEPTH : META_DEPTH;
localparam integer SCAN_WIDTH  = wfq_clog2(INIT_WRITES + 1);

input  wire                                             clk;
input  wire                                             rstn;
output wire                                             init_done;

// At this edge the owner initializes counts, bank/cache/context/FIFO state.
output wire                                             init_guard;

// TT and RC share these controls, each writing an all-zero word.
output wire                                             meta_write_en;
output wire [12:0]                                      meta_write_addr;
output wire                                             l1_write_en;
output wire                                             l1_write_addr;
output wire                                             l2_write_en;
output wire [4:0]                                       l2_write_addr;
output wire                                             l3_write_en;
output wire [8:0]                                       l3_write_addr;

// FREE data is the valid physical address, zero-extended to PTR_WIDTH.
output wire                                             free_write_en;
output wire [ADDR_WIDTH-1:0]                            free_write_addr;
output wire [PTR_WIDTH-1:0]                             free_write_data;

reg [SCAN_WIDTH-1:0]                                    scan_d;
reg                                                     init_done_d;
wire                                                    scan_active;

generate
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0) ||
        (PTR_WIDTH < 4) || (PTR_WIDTH > 16) ||
        (PTR_WIDTH < ADDR_WIDTH)) begin : g_bad_parameters
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
endgenerate

assign scan_active = rstn & ~init_done_d & (scan_d < INIT_WRITES);
assign init_guard = rstn & ~init_done_d & (scan_d == INIT_WRITES);
assign init_done = init_done_d;

assign meta_write_en = scan_active & (scan_d < META_DEPTH);
assign meta_write_addr = scan_d[12:0];
assign l1_write_en = scan_active & (scan_d < 2);
assign l1_write_addr = scan_d[0];
assign l2_write_en = scan_active & (scan_d < 32);
assign l2_write_addr = scan_d[4:0];
assign l3_write_en = scan_active & (scan_d < 512);
assign l3_write_addr = scan_d[8:0];
assign free_write_en = scan_active & (scan_d < MEM_DEPTH);
assign free_write_addr = scan_d[ADDR_WIDTH-1:0];
assign free_write_data = {{(PTR_WIDTH-ADDR_WIDTH){1'b0}}, free_write_addr};

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        scan_d <= {SCAN_WIDTH{1'b0}};
        init_done_d <= 1'b0;
    end
    else if (!init_done_d) begin
        if (scan_active) begin
            scan_d <= scan_d + 1'b1;
        end
        else if (init_guard) begin
            init_done_d <= 1'b1;
        end
    end
end

endmodule

`default_nettype wire
