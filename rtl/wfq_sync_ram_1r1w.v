// Project : wfq_tag_sort_engine
// File    : wfq_sync_ram_1r1w.v
// Spec    : Design_Spec_V1.2.md, sections 6.4 and 11.3
// Function: Single-copy synchronous 1R1W RAM with request-aligned forwarding.
// Timing  : Read at E_k produces data during that cycle for use at E_(k+1).
//           The RAM write occurs at E_k, with no hidden write-data stage.
// Priority: New logical commit > newest pending logical write > physical write
//           at the read address > raw RAM data. Zero/invalid data also forwards.
// Reset   : Array and macro read-data register deliberately have no reset.

`timescale 1ns/1ps
`default_nettype none

module wfq_sync_ram_1r1w #(
    parameter integer DATA_WIDTH = 11,
    parameter integer MEM_DEPTH  = 8192
) (
    clk,
    rstn,
    read_en,
    read_addr,
    write_en,
    write_addr,
    write_data,
    commit_valid,
    commit_addr,
    commit_data,
    pending_valid,
    pending_addr,
    pending_data,
    read_valid,
    read_data
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);

input  wire                                             clk;
input  wire                                             rstn;

// All addresses are physical addresses checked by the calling controller.
input  wire                                             read_en;
input  wire [ADDR_WIDTH-1:0]                            read_addr;
input  wire                                             write_en;
input  wire [ADDR_WIDTH-1:0]                            write_addr;
input  wire [DATA_WIDTH-1:0]                            write_data;

// Caller selects the newest matching pending entry before this interface.
input  wire                                             commit_valid;
input  wire [ADDR_WIDTH-1:0]                            commit_addr;
input  wire [DATA_WIDTH-1:0]                            commit_data;
input  wire                                             pending_valid;
input  wire [ADDR_WIDTH-1:0]                            pending_addr;
input  wire [DATA_WIDTH-1:0]                            pending_data;

output wire                                             read_valid;
output wire [DATA_WIDTH-1:0]                            read_data;

reg [DATA_WIDTH-1:0]                                    mem_d [0:MEM_DEPTH-1];
reg [DATA_WIDTH-1:0]                                    ram_read_data_d;
reg                                                     read_valid_d1;
reg                                                     bypass_hit_d;
reg [DATA_WIDTH-1:0]                                    bypass_data_d;
wire                                                    commit_hit;
wire                                                    pending_hit;
wire                                                    write_hit;

generate
    if ((DATA_WIDTH < 1) || (MEM_DEPTH < 2) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0)) begin : g_bad_parameters
        wfq_error_ram_requires_positive_width_and_power_of_two_depth u_error ();
    end
endgenerate

///////////////////////////////////////////////////////////////////////////////
// Physical RAM: macro read/write collision behavior is hidden by the bypass
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk) begin
    if (rstn && write_en) begin
        mem_d[write_addr] <= write_data;
    end
    if (rstn && read_en) begin
        ram_read_data_d <= mem_d[read_addr];
    end
end

///////////////////////////////////////////////////////////////////////////////
// Snapshot forwarding at the request edge, independent of later overlay valid
///////////////////////////////////////////////////////////////////////////////
assign commit_hit = commit_valid & (commit_addr == read_addr);
assign pending_hit = pending_valid & (pending_addr == read_addr);
assign write_hit = write_en & (write_addr == read_addr);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        read_valid_d1 <= 1'b0;
        bypass_hit_d <= 1'b0;
        bypass_data_d <= {DATA_WIDTH{1'b0}};
    end
    else begin
        read_valid_d1 <= read_en;
        if (read_en) begin
            bypass_hit_d <= commit_hit | pending_hit | write_hit;
            if (commit_hit) begin
                bypass_data_d <= commit_data;
            end
            else if (pending_hit) begin
                bypass_data_d <= pending_data;
            end
            else begin
                bypass_data_d <= write_data;
            end
        end
    end
end

assign read_valid = read_valid_d1;
assign read_data = bypass_hit_d ? bypass_data_d : ram_read_data_d;

endmodule

`default_nettype wire
