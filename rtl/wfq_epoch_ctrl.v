// Project : wfq_tag_sort_engine
// File    : wfq_epoch_ctrl.v
// Spec    : Design_Spec_V1.2.md, sections 3, 5.3, 9 and 13
// Function: Two adjacent epoch banks, committed counts and modulo-16-bit base.
// Scope   : List manager owns bank head/tail/min/max; this module owns only
//           epoch identity, valid, count and base. Responses do not hold banks.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_epoch_ctrl #(
    parameter integer MEM_DEPTH = 1024
) (
    clk,
    rstn,
    init_done,
    init_guard,
    halt,
    update_allow,
    query_epoch,
    epoch_legal,
    queue_level,
    insert_commit_req,
    extract_commit_req,
    commit_epoch,
    base_epoch,
    bank_valid,
    bank0_epoch,
    bank1_epoch,
    bank0_count,
    bank1_count,
    error_code
);

`include "wfq_clog2.vh"
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam [COUNT_WIDTH-1:0] CAPACITY = MEM_DEPTH;


// Clock, initialization and common mutation permission
input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             init_done;
input  wire                                             init_guard;
input  wire                                             halt;
input  wire                                             update_allow;

// Query eligibility is combinational and never itself causes a fault
input  wire [15:0]                                      query_epoch;
output wire                                             epoch_legal;
input  wire [COUNT_WIDTH-1:0]                           queue_level;

// Ungated commit proposal; extractor must name the oldest epoch
input  wire                                             insert_commit_req;
input  wire                                             extract_commit_req;
input  wire [15:0]                                      commit_epoch;

// Committed identities/counts; list boundary pointers are owned elsewhere
output wire [15:0]                                      base_epoch;
output wire [1:0]                                       bank_valid;
output wire [15:0]                                      bank0_epoch;
output wire [15:0]                                      bank1_epoch;
output wire [COUNT_WIDTH-1:0]                           bank0_count;
output wire [COUNT_WIDTH-1:0]                           bank1_count;
output reg [3:0]                                        error_code;

reg [15:0]                                              base_epoch_d;
reg [1:0]                                               valid_d;
reg [15:0]                                              epoch0_d;
reg [15:0]                                              epoch1_d;
reg [COUNT_WIDTH-1:0]                                   count0_d;
reg [COUNT_WIDTH-1:0]                                   count1_d;
wire                                                    live;
wire [15:0]                                             next_epoch;
wire [COUNT_WIDTH:0]                                    bank_sum;
wire                                                    selected_valid;
wire [15:0]                                             selected_epoch;
wire [COUNT_WIDTH-1:0]                                  selected_count;
wire [COUNT_WIDTH-1:0]                                  other_count;
wire [15:0]                                             other_epoch;
wire                                                    base_present;
wire                                                    insert_commit;
wire                                                    extract_commit;

generate
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0)) begin : g_bad_capacity
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
endgenerate

assign live = rstn & init_done & ~halt;
assign next_epoch = base_epoch_d + 16'd1;
assign epoch_legal = (queue_level == 0) | (query_epoch == base_epoch_d) |
                    (query_epoch == next_epoch);
assign base_epoch = base_epoch_d;
assign bank_valid = valid_d;
assign bank0_epoch = epoch0_d;
assign bank1_epoch = epoch1_d;
assign bank0_count = count0_d;
assign bank1_count = count1_d;
assign bank_sum = {1'b0, count0_d} + {1'b0, count1_d};
assign selected_valid = commit_epoch[0] ? valid_d[1] : valid_d[0];
assign selected_epoch = commit_epoch[0] ? epoch1_d : epoch0_d;
assign selected_count = commit_epoch[0] ? count1_d : count0_d;
assign other_count = commit_epoch[0] ? count0_d : count1_d;
assign other_epoch = commit_epoch[0] ? epoch0_d : epoch1_d;
assign base_present = base_epoch_d[0] ? (valid_d[1] && (epoch1_d == base_epoch_d)) :
                                    (valid_d[0] && (epoch0_d == base_epoch_d));

always @(*) begin
    error_code = `WFQ_FAULT_NONE;
    if (live) begin
        if ((valid_d[0] != (count0_d != 0)) ||
            (valid_d[1] != (count1_d != 0)) ||
            (bank_sum != {1'b0, queue_level}) ||
            ((queue_level != 0) && !base_present) ||
            (valid_d[0] && (epoch0_d[0] ||
            ((epoch0_d != base_epoch_d) && (epoch0_d != next_epoch)))) ||
            (valid_d[1] && (!epoch1_d[0] ||
            ((epoch1_d != base_epoch_d) && (epoch1_d != next_epoch)))) ||
            (insert_commit_req && (queue_level != 0) &&
            (commit_epoch != base_epoch_d) && (commit_epoch != next_epoch)) ||
            (insert_commit_req && selected_valid && (selected_epoch != commit_epoch)) ||
            (extract_commit_req && (!selected_valid || (selected_epoch != commit_epoch) ||
            (commit_epoch != base_epoch_d)))) begin
            error_code = `WFQ_FAULT_EPOCH;
        end
        else if ((count0_d > CAPACITY) || (count1_d > CAPACITY) ||
                (insert_commit_req && (selected_count >= CAPACITY)) ||
                (extract_commit_req && (selected_count == 0))) begin
            error_code = `WFQ_FAULT_CAPACITY;
        end
        else if (insert_commit_req && extract_commit_req) begin
            error_code = `WFQ_FAULT_SCHEDULE;
        end
    end
end

assign insert_commit = live & update_allow & (error_code == 0) & insert_commit_req;
assign extract_commit = live & update_allow & (error_code == 0) & extract_commit_req;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        base_epoch_d <= 16'd0;
        valid_d <= 2'b00;
        epoch0_d <= 16'd0;
        epoch1_d <= 16'd0;
        count0_d <= {COUNT_WIDTH{1'b0}};
        count1_d <= {COUNT_WIDTH{1'b0}};
    end
    else if (init_guard) begin
        base_epoch_d <= 16'd0;
        valid_d <= 2'b00;
        epoch0_d <= 16'd0;
        epoch1_d <= 16'd0;
        count0_d <= {COUNT_WIDTH{1'b0}};
        count1_d <= {COUNT_WIDTH{1'b0}};
    end
    else if (insert_commit) begin
        if (queue_level == 0) begin
            base_epoch_d <= commit_epoch;
        end
        if (commit_epoch[0]) begin
            valid_d[1] <= 1'b1;
            epoch1_d <= commit_epoch;
            count1_d <= count1_d + 1'b1;
        end
        else begin
            valid_d[0] <= 1'b1;
            epoch0_d <= commit_epoch;
            count0_d <= count0_d + 1'b1;
        end
    end
    else if (extract_commit) begin
        if ((selected_count == 1) && (other_count != 0)) begin
            base_epoch_d <= other_epoch;
        end
        if (commit_epoch[0]) begin
            count1_d <= count1_d - 1'b1;
            if (count1_d == 1) begin
                valid_d[1] <= 1'b0;
            end
        end
        else begin
            count0_d <= count0_d - 1'b1;
            if (count0_d == 1) begin
                valid_d[0] <= 1'b0;
            end
        end
    end
end

endmodule

`default_nettype wire
