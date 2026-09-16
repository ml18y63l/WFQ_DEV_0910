// Project : wfq_tag_sort_engine
// File    : wfq_commit_ctrl.v
// Spec    : Design_Spec_V1.2.md, sections 10, 11 and 13
// Function: Two fixed-lifetime execution/writeback contexts for FAST5.
// Contract: Deadlines are pre-gate proposals. Common update_allow controls
//           context mutation; logical commit is not context release.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_commit_ctrl #(
    parameter integer ISSUE_INTERVAL = 5
) (
    // Shared clock, initialization and global stop/permission
    input  wire                                         clk,
    input  wire                                         rstn,
    input  wire                                         init_done,
    input  wire                                         init_guard,
    input  wire                                         halt,
    input  wire                                         update_allow,

    // Already accepted requests use the combinationally selected free context
    input  wire                                         insert_fire,
    input  wire                                         extract_fire,
    output wire                                         request_context,
    output wire                                         context_available,

    // Raw deadlines: commit, final physical patch, then writeback complete
    output wire                                         commit_req,
    output wire                                         commit_insert,
    output wire                                         commit_context,
    output wire                                         patch_req,
    output wire                                         patch_context,
    output wire [1:0]                                   wb_due,
    output wire [1:0]                                   context_valid,
    output wire                                         busy,
    output wire [3:0]                                   error_code
);

localparam integer INSERT_COMMIT_LATENCY = ISSUE_INTERVAL - 1;
localparam integer INSERT_PATCH_EDGE = ISSUE_INTERVAL;
localparam integer INSERT_WB_DONE_LATENCY = ISSUE_INTERVAL + 1;
localparam integer EXTRACT_COMMIT_LATENCY = 1;
localparam integer EXTRACT_WB_DONE_LATENCY = 2;

reg [1:0]                                               valid_d;
reg [1:0]                                               insert_d;
reg [1:0]                                               committed_d;
reg [2:0]                                               age0_d;
reg [2:0]                                               age1_d;
wire                                                    live;
wire [1:0]                                              at_commit;
wire [1:0]                                              at_patch;
wire [1:0]                                              at_wb;
wire [1:0]                                              accept_mask;
wire [1:0]                                              commit_mask;
wire                                                    phase_bad;

generate
    if (ISSUE_INTERVAL != 5) begin : g_bad_interval
        wfq_error_stage4_requires_issue_interval_5 u_error ();
    end
endgenerate

assign live = rstn & init_done & ~halt;
assign context_available = ~(&valid_d);
assign request_context = valid_d[0];
assign context_valid = valid_d;
assign busy = init_done & (|valid_d);
assign at_commit[0] = valid_d[0] & (insert_d[0] ?
    (age0_d == INSERT_COMMIT_LATENCY) : (age0_d == EXTRACT_COMMIT_LATENCY));
assign at_commit[1] = valid_d[1] & (insert_d[1] ?
    (age1_d == INSERT_COMMIT_LATENCY) : (age1_d == EXTRACT_COMMIT_LATENCY));
assign at_patch[0] = valid_d[0] & insert_d[0] & (age0_d == INSERT_PATCH_EDGE);
assign at_patch[1] = valid_d[1] & insert_d[1] & (age1_d == INSERT_PATCH_EDGE);
assign at_wb[0] = valid_d[0] & (insert_d[0] ?
    (age0_d == INSERT_WB_DONE_LATENCY) : (age0_d == EXTRACT_WB_DONE_LATENCY));
assign at_wb[1] = valid_d[1] & (insert_d[1] ?
    (age1_d == INSERT_WB_DONE_LATENCY) : (age1_d == EXTRACT_WB_DONE_LATENCY));
assign commit_req = live & (|at_commit);
assign commit_context = at_commit[1];
assign commit_insert = commit_context ? insert_d[1] : insert_d[0];
assign patch_req = live & (|at_patch);
assign patch_context = at_patch[1];
assign wb_due = {2{live}} & at_wb;
assign accept_mask = (insert_fire | extract_fire) ?
    (request_context ? 2'b10 : 2'b01) : 2'b00;
assign commit_mask = {2{commit_req}} & at_commit;

// Committed must change at C, never at WB; age remains bounded for each type.
assign phase_bad =
    (valid_d[0] & ((age0_d == 0) |
    (insert_d[0] ? ((age0_d > INSERT_WB_DONE_LATENCY) |
        (committed_d[0] != (age0_d > INSERT_COMMIT_LATENCY))) :
        ((age0_d > EXTRACT_WB_DONE_LATENCY) |
        (committed_d[0] != (age0_d > EXTRACT_COMMIT_LATENCY)))))) |
    (valid_d[1] & ((age1_d == 0) |
    (insert_d[1] ? ((age1_d > INSERT_WB_DONE_LATENCY) |
        (committed_d[1] != (age1_d > INSERT_COMMIT_LATENCY))) :
        ((age1_d > EXTRACT_WB_DONE_LATENCY) |
        (committed_d[1] != (age1_d > EXTRACT_COMMIT_LATENCY))))));
assign error_code = (live & (phase_bad | (&at_commit) | (&at_patch))) ?
    `WFQ_FAULT_SCHEDULE : `WFQ_FAULT_NONE;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        valid_d <= 2'b00;
        insert_d <= 2'b00;
        committed_d <= 2'b00;
        age0_d <= 3'd0;
        age1_d <= 3'd0;
    end
    else if (init_guard) begin
        valid_d <= 2'b00;
        insert_d <= 2'b00;
        committed_d <= 2'b00;
        age0_d <= 3'd0;
        age1_d <= 3'd0;
    end
    else if (live && update_allow) begin
        valid_d <= (valid_d & ~at_wb) | accept_mask;
        committed_d <= ((committed_d & ~at_wb) | commit_mask) & ~accept_mask;
        if (valid_d[0]) begin
            age0_d <= age0_d + 1'b1;
        end
        if (valid_d[1]) begin
            age1_d <= age1_d + 1'b1;
        end
        if (accept_mask[0]) begin
            age0_d <= 3'd1;
            insert_d[0] <= insert_fire;
        end
        if (accept_mask[1]) begin
            age1_d <= 3'd1;
            insert_d[1] <= insert_fire;
        end
    end
end

endmodule

`default_nettype wire
