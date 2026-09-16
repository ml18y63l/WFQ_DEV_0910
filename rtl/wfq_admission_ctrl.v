// Project : wfq_tag_sort_engine
// File    : wfq_admission_ctrl.v
// Spec    : Design_Spec_V1.2.md, sections 4.2, 10.6 and 13
// Function: FAST5 shared issuer, conservative eligibility and round-robin.
// Contract: Grants are proposals independent of update_allow. Only a permitted
//           grant changes RR/cooldown; no eligible request means no slot lost.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_admission_ctrl #(
    parameter integer ISSUE_INTERVAL = 5
) (

    // Clock, initialization and common mutation permission
    input  wire                                         clk,
    input  wire                                         rstn,
    input  wire                                         init_done,
    input  wire                                         init_guard,
    input  wire                                         halt,
    input  wire                                         update_allow,

    // Current request candidates and resource eligibility
    input  wire                                         insert_val,
    input  wire                                         extract_req,
    input  wire                                         free_available,
    input  wire                                         queue_nonempty,
    input  wire                                         epoch_legal,
    input  wire                                         response_credit,

    // Required execution/storage availability; absence is a schedule fault
    input  wire                                         context_available,
    input  wire                                         path_ready,

    // Ungated proposals for the shared pre-edge checker
    output wire                                         insert_grant,
    output wire                                         extract_grant,
    output wire                                         issue_open,
    output wire [3:0]                                   error_code
);

`include "wfq_clog2.vh"
localparam integer GAP_WIDTH = wfq_clog2(ISSUE_INTERVAL);
localparam [GAP_WIDTH-1:0] ISSUE_RELOAD = ISSUE_INTERVAL - 1;

reg [GAP_WIDTH-1:0]                                     gap_d;
reg                                                     prefer_insert_d;
wire                                                    insert_candidate;
wire                                                    extract_candidate;
wire                                                    accept_insert;
wire                                                    accept_extract;

generate
    if (ISSUE_INTERVAL != 5) begin : g_bad_interval
        wfq_error_stage3_requires_issue_interval_5 u_error ();
    end
endgenerate

assign issue_open = rstn & init_done & ~halt & (gap_d == 0);
assign insert_candidate = issue_open & insert_val & free_available & epoch_legal;
assign extract_candidate = issue_open & extract_req & queue_nonempty & response_credit;
assign insert_grant = insert_candidate & (~extract_candidate | prefer_insert_d);
assign extract_grant = extract_candidate & (~insert_candidate | ~prefer_insert_d);
assign accept_insert = insert_grant & update_allow;
assign accept_extract = extract_grant & update_allow;
assign error_code = ((insert_grant | extract_grant) &
                    (~context_available | ~path_ready)) ? `WFQ_FAULT_SCHEDULE :
                                                        `WFQ_FAULT_NONE;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        gap_d <= {GAP_WIDTH{1'b0}};
        prefer_insert_d <= 1'b0;
    end
    else if (init_guard) begin
        gap_d <= {GAP_WIDTH{1'b0}};
        prefer_insert_d <= 1'b0;
    end
    else if (init_done && !halt && update_allow) begin
        if (accept_insert || accept_extract) begin
            gap_d <= ISSUE_RELOAD;
            prefer_insert_d <= accept_extract;
        end
        else if (gap_d != 0) begin
            gap_d <= gap_d - 1'b1;
        end
    end
end

endmodule

`default_nettype wire
