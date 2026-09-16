// Project : wfq_tag_sort_engine
// File    : wfq_resource_ctrl.v
// Spec    : Design_Spec_V1.2.md, sections 3, 4, 6.5, 10-13
// Function: FAST5 admission, FREE, epoch and reserved-response integration.
// Scope   : One uncommitted resource context; list/commit controller retains
//           two execution/writeback contexts and supplies the fixed-edge commit.
// Contract: commit_req and external_error_code are pre-gate proposals/events.
//           cycle_allow gates EVERY subsystem on that edge, not just resources.
//           Never feed cycle_allow back into proposed events or alloc_valid.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_resource_ctrl #(
    parameter integer PTR_WIDTH      = 10,
    parameter integer MEM_DEPTH      = 1024,
    parameter integer FLOW_ID_WIDTH  = 9,
    parameter integer ISSUE_INTERVAL = 5
) (
    clk,
    rstn,
    init_done,
    init_guard,
    init_free_write_en,
    init_free_write_addr,
    init_free_write_data,
    halt,
    insert_val,
    insert_epoch,
    extract_req,
    request_context,
    context_available,
    path_ready,
    insert_ready,
    extract_ready,
    insert_fire,
    extract_fire,
    insert_epoch_blocked,
    issue_open,
    alloc_valid,
    alloc_context,
    alloc_ptr,
    commit_req,
    commit_insert,
    commit_context,
    commit_epoch,
    release_ptr,
    response_payload,
    external_error_code,
    commit_due,
    commit_fire,
    cycle_allow,
    extract_out_ready,
    extract_val,
    extract_payload,
    rsp_count,
    rsp_reserved,
    free_count,
    alloc_reserved,
    queue_level,
    empty,
    full,
    base_epoch,
    bank_valid,
    bank0_epoch,
    bank1_epoch,
    bank0_count,
    bank1_count,
    error_valid,
    error_code,
    fault,
    fault_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam integer PAYLOAD_WIDTH = 28 + FLOW_ID_WIDTH;
localparam integer INSERT_COMMIT_LATENCY = ISSUE_INTERVAL - 1;
localparam integer EXTRACT_COMMIT_LATENCY = 1;


// Clock and shared initialization
input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             init_done;
input  wire                                             init_guard;

// Connect shared wfq_init_ctrl FREE outputs
input  wire                                             init_free_write_en;
input  wire [ADDR_WIDTH-1:0]                            init_free_write_addr;
input  wire [PTR_WIDTH-1:0]                             init_free_write_data;
input  wire                                             halt;

// Top-level candidates and caller-owned context/storage availability
input  wire                                             insert_val;
input  wire [15:0]                                      insert_epoch;
input  wire                                             extract_req;
input  wire                                             request_context;
input  wire                                             context_available;
input  wire                                             path_ready;

// Gated handshakes, plus epoch and issue-window status
output wire                                             insert_ready;
output wire                                             extract_ready;
output wire                                             insert_fire;
output wire                                             extract_fire;
output wire                                             insert_epoch_blocked;
output wire                                             issue_open;

// FREE return before E1, independent of combinational cycle_allow
output wire                                             alloc_valid;
output wire                                             alloc_context;
output wire [PTR_WIDTH-1:0]                             alloc_ptr;

// Ungated fixed-edge descriptor proposal from list/commit control
input  wire                                             commit_req;
input  wire                                             commit_insert;
input  wire                                             commit_context;
input  wire [15:0]                                      commit_epoch;
input  wire [PTR_WIDTH-1:0]                             release_ptr;
input  wire [PAYLOAD_WIDTH-1:0]                         response_payload;
input  wire [3:0]                                       external_error_code;

// Pre-edge deadline and common all-domain permission
output wire                                             commit_due;
output wire                                             commit_fire;
output wire                                             cycle_allow;

// Full-payload registered response channel; drains after fault
input  wire                                             extract_out_ready;
output wire                                             extract_val;
output wire [PAYLOAD_WIDTH-1:0]                         extract_payload;
output wire [1:0]                                       rsp_count;
output wire [1:0]                                       rsp_reserved;

// Authoritative committed/reserved resource state
output wire [COUNT_WIDTH-1:0]                           free_count;
output wire [COUNT_WIDTH-1:0]                           alloc_reserved;
output wire [COUNT_WIDTH-1:0]                           queue_level;
output wire                                             empty;
output wire                                             full;

// Authoritative epoch-bank identities and counts
output wire [15:0]                                      base_epoch;
output wire [1:0]                                       bank_valid;
output wire [15:0]                                      bank0_epoch;
output wire [15:0]                                      bank1_epoch;
output wire [COUNT_WIDTH-1:0]                           bank0_count;
output wire [COUNT_WIDTH-1:0]                           bank1_count;

// Pre-edge minimum event and sticky first fault, including external errors
output wire                                             error_valid;
output wire [3:0]                                       error_code;
output wire                                             fault;
output wire [3:0]                                       fault_code;

reg                                                     fault_d;
reg [3:0]                                               fault_code_d;
reg                                                     active_d;
reg [2:0]                                               phase_d;
reg                                                     insert_d;
reg                                                     context_d;
reg [15:0]                                              epoch_d;
reg [3:0]                                               transaction_error;
wire                                                    stopped;
wire                                                    live;
wire                                                    insert_grant;
wire                                                    extract_grant;
wire                                                    epoch_legal;
wire                                                    response_credit;
wire                                                    insert_commit_req;
wire                                                    extract_commit_req;
wire [3:0]                                              admission_error;
wire [3:0]                                              free_error;
wire [3:0]                                              epoch_error;
wire [3:0]                                              response_error;
wire [3:0]                                              local_error;

function [3:0] min_fault;
    input [3:0] a;
    input [3:0] b;
    begin
        if (a == 0) begin
            min_fault = b;
        end
        else if (b == 0) begin
            min_fault = a;
        end
        else begin
            min_fault = (a < b) ? a : b;
        end
    end
endfunction

assign stopped = halt | fault_d;
assign live = rstn & init_done & ~stopped;
assign fault = fault_d;
assign fault_code = fault_code_d;
assign empty = ~init_done | (queue_level == 0);
assign full = init_done & (free_count == 0);
assign insert_epoch_blocked = init_done & insert_val & ~epoch_legal;
assign local_error = min_fault(min_fault(admission_error, free_error),
                            min_fault(epoch_error, response_error));
assign error_code = live ? min_fault(min_fault(local_error, transaction_error),
                                    external_error_code) : `WFQ_FAULT_NONE;
assign error_valid = (error_code != 0);
assign cycle_allow = live & ~error_valid;
assign insert_ready = insert_grant & cycle_allow;
assign extract_ready = extract_grant & cycle_allow;
assign insert_fire = insert_val & insert_ready;
assign extract_fire = extract_req & extract_ready;
assign insert_commit_req = live & commit_req & commit_insert;
assign extract_commit_req = live & commit_req & ~commit_insert;
assign commit_due = live & active_d &
                    (insert_d ? (phase_d == INSERT_COMMIT_LATENCY) :
                                (phase_d == EXTRACT_COMMIT_LATENCY));
assign commit_fire = commit_req & cycle_allow;

///////////////////////////////////////////////////////////////////////////////
// One uncommitted operation: check the external descriptor before any mutation
///////////////////////////////////////////////////////////////////////////////
always @(*) begin
    transaction_error = `WFQ_FAULT_NONE;
    if (live) begin
        if (commit_req && active_d &&
            ((commit_epoch != epoch_d) ||
            (!commit_insert && (response_payload[PAYLOAD_WIDTH-1 -: 16] != epoch_d)))) begin
            transaction_error = `WFQ_FAULT_EPOCH;
        end
        else if ((commit_req != commit_due) ||
                (commit_req && ((commit_insert != insert_d) ||
                                (commit_context != context_d))) ||
                (active_d && (insert_grant || extract_grant))) begin
            transaction_error = `WFQ_FAULT_SCHEDULE;
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        fault_d <= 1'b0;
        fault_code_d <= `WFQ_FAULT_NONE;
        active_d <= 1'b0;
        phase_d <= 3'd0;
        insert_d <= 1'b0;
        context_d <= 1'b0;
        epoch_d <= 16'd0;
    end
    else if (init_guard) begin
        fault_d <= 1'b0;
        fault_code_d <= `WFQ_FAULT_NONE;
        active_d <= 1'b0;
        phase_d <= 3'd0;
        insert_d <= 1'b0;
        context_d <= 1'b0;
        epoch_d <= 16'd0;
    end
    else begin
        if (error_valid && !fault_d) begin
            fault_d <= 1'b1;
            fault_code_d <= error_code;
        end
        if (cycle_allow) begin
            if (active_d) begin
                phase_d <= phase_d + 1'b1;
            end
            if (commit_fire) begin
                active_d <= 1'b0;
            end
            if (insert_fire || extract_fire) begin
                active_d <= 1'b1;
                phase_d <= 3'd1;
                insert_d <= insert_fire;
                context_d <= request_context;
                epoch_d <= insert_fire ? insert_epoch : base_epoch;
            end
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// Shared issuer and committed epoch identity
///////////////////////////////////////////////////////////////////////////////
wfq_admission_ctrl #(
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_admission (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .halt                                               (stopped),
    .update_allow                                       (cycle_allow),
    .insert_val                                         (insert_val),
    .extract_req                                        (extract_req),
    .free_available                                     (free_count != 0),
    .queue_nonempty                                     (queue_level != 0),
    .epoch_legal                                        (epoch_legal),
    .response_credit                                    (response_credit),
    .context_available                                  (context_available),
    .path_ready                                         (path_ready),
    .insert_grant                                       (insert_grant),
    .extract_grant                                      (extract_grant),
    .issue_open                                         (issue_open),
    .error_code                                         (admission_error)
);

wfq_epoch_ctrl #(
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_epoch (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .halt                                               (stopped),
    .update_allow                                       (cycle_allow),
    .query_epoch                                        (insert_epoch),
    .epoch_legal                                        (epoch_legal),
    .queue_level                                        (queue_level),
    .insert_commit_req                                  (insert_commit_req),
    .extract_commit_req                                 (extract_commit_req),
    .commit_epoch                                       (commit_epoch),
    .base_epoch                                         (base_epoch),
    .bank_valid                                         (bank_valid),
    .bank0_epoch                                        (bank0_epoch),
    .bank1_epoch                                        (bank1_epoch),
    .bank0_count                                        (bank0_count),
    .bank1_count                                        (bank1_count),
    .error_code                                         (epoch_error)
);

///////////////////////////////////////////////////////////////////////////////
// Capacity is reserved at acceptance; FREE read returns without another stage
///////////////////////////////////////////////////////////////////////////////
wfq_free_slot_stack #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_free (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .init_write_en                                      (init_free_write_en),
    .init_write_addr                                    (init_free_write_addr),
    .init_write_data                                    (init_free_write_data),
    .halt                                               (stopped),
    .update_allow                                       (cycle_allow),
    .reserve_req                                        (insert_grant),
    .reserve_context                                    (request_context),
    .insert_commit_req                                  (insert_commit_req),
    .extract_commit_req                                 (extract_commit_req),
    .release_ptr                                        (release_ptr),
    .alloc_valid                                        (alloc_valid),
    .alloc_context                                      (alloc_context),
    .alloc_ptr                                          (alloc_ptr),
    .free_count                                         (free_count),
    .alloc_reserved                                     (alloc_reserved),
    .queue_level                                        (queue_level),
    .error_code                                         (free_error)
);

///////////////////////////////////////////////////////////////////////////////
// Fault/halt blocks new reservations and production, never existing consumption
///////////////////////////////////////////////////////////////////////////////
wfq_response_fifo #(
    .FLOW_ID_WIDTH                                      (FLOW_ID_WIDTH)
) u_response (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .update_allow                                       (cycle_allow),
    .reserve_req                                        (extract_grant),
    .enqueue_req                                        (extract_commit_req),
    .enqueue_payload                                    (response_payload),
    .out_ready                                          (extract_out_ready),
    .out_valid                                          (extract_val),
    .out_payload                                        (extract_payload),
    .credit_available                                   (response_credit),
    .rsp_count                                          (rsp_count),
    .rsp_reserved                                       (rsp_reserved),
    .error_code                                         (response_error)
);

endmodule

`default_nettype wire
