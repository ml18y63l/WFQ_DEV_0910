// Project : wfq_tag_sort_engine
// File    : wfq_sync_ram_1rw.v
// Spec    : Design_Spec_V1.2.md, section 6.4
// Function: One physical synchronous read-or-write port, used for L3.
// Timing  : Read address sampled at E_k; data/valid usable at E_(k+1).
//           Writes change memory at the sampling edge, without a write pipeline.
// Reset   : RAM array and raw read-data register have no reset (style section 7).

`timescale 1ns/1ps
`default_nettype none

module wfq_sync_ram_1rw #(
    parameter integer DATA_WIDTH = 16,
    parameter integer MEM_DEPTH  = 512
) (
    clk,
    rstn,
    read_en,
    write_en,
    addr,
    write_data,
    read_valid,
    read_data,
    access_conflict
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);

input  wire                                             clk;
input  wire                                             rstn;

// Shared physical address, not separate read and write addresses.
input  wire                                             read_en;
input  wire                                             write_en;
input  wire [ADDR_WIDTH-1:0]                            addr;
input  wire [DATA_WIDTH-1:0]                            write_data;
output wire                                             read_valid;
output wire [DATA_WIDTH-1:0]                            read_data;
output wire                                             access_conflict;

reg [DATA_WIDTH-1:0]                                    mem_d [0:MEM_DEPTH-1];
reg [DATA_WIDTH-1:0]                                    ram_read_data_d;
reg                                                     read_valid_d1;
wire                                                    read_accept;
wire                                                    write_accept;

generate
    if ((DATA_WIDTH < 1) || (MEM_DEPTH < 2) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0)) begin : g_bad_parameters
        wfq_error_ram_requires_positive_width_and_power_of_two_depth u_error ();
    end
endgenerate

// Reject both accesses on collision. The future commit controller must also
// suppress all transaction writes and latch WFQ_FAULT_SCHEDULE atomically.
assign access_conflict = rstn & read_en & write_en;
assign read_accept = rstn & read_en & ~write_en;
assign write_accept = rstn & write_en & ~read_en;

always @(posedge clk) begin
    if (write_accept) begin
        mem_d[addr] <= write_data;
    end
    else if (read_accept) begin
        ram_read_data_d <= mem_d[addr];
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        read_valid_d1 <= 1'b0;
    end
    else begin
        read_valid_d1 <= read_accept;
    end
end

assign read_valid = read_valid_d1;
assign read_data = ram_read_data_d;

endmodule

`default_nettype wire
