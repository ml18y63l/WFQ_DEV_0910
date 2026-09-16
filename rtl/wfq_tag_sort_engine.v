// Project : wfq_tag_sort_engine
// File    : wfq_tag_sort_engine.v
// Spec    : Design_Spec_V1.2.md, sections 2, 4, 5 and 9-13
// Function: Complete FAST5 stable epoch/tag sorter with a shared 1024-slot pool.
// Reset   : One shared asynchronous-assert/synchronous-release reset tree.
// Scope   : Current implementation supports ISSUE_INTERVAL=5 only.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_tag_sort_engine #(
    parameter integer TAG_WIDTH      = 12,
    parameter integer LITERAL_WIDTH  = 4,
    parameter integer EPOCH_WIDTH    = 16,
    parameter integer PTR_WIDTH      = 10,
    parameter integer MEM_DEPTH      = 1024,
    parameter integer FLOW_ID_WIDTH  = 9,
    parameter integer ISSUE_INTERVAL = 5
) (

    clk,
    rstn,
    insert_val,
    insert_ready,
    insert_epoch,
    insert_tag,
    insert_flow_id,
    insert_commit,
    insert_epoch_blocked,
    extract_req,
    extract_ready,
    extract_commit,
    extract_val,
    extract_out_ready,
    min_epoch_out,
    min_tag_out,
    min_tag_flow_id,
    init_done,
    empty,
    full,
    queue_level,
    busy,
    idle,
    fault,
    fault_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam integer PAYLOAD_WIDTH = 28 + FLOW_ID_WIDTH;

// External reset is synchronized once for all internal owners
input  wire                                             clk;
input  wire                                             rstn;

// Insert stream, stable while valid and backpressured
input  wire                                             insert_val;
output wire                                             insert_ready;
input  wire [EPOCH_WIDTH-1:0]                           insert_epoch;
input  wire [TAG_WIDTH-1:0]                             insert_tag;
input  wire [FLOW_ID_WIDTH-1:0]                         insert_flow_id;
output wire                                             insert_commit;
output wire                                             insert_epoch_blocked;

// Extract requests and independently backpressured response stream
input  wire                                             extract_req;
output wire                                             extract_ready;
output wire                                             extract_commit;
output wire                                             extract_val;
input  wire                                             extract_out_ready;
output wire [EPOCH_WIDTH-1:0]                           min_epoch_out;
output wire [TAG_WIDTH-1:0]                             min_tag_out;
output wire [FLOW_ID_WIDTH-1:0]                         min_tag_flow_id;

// Committed capacity, writeback lifecycle and sticky fail-stop status
output wire                                             init_done;
output wire                                             empty;
output wire                                             full;
output wire [COUNT_WIDTH-1:0]                           queue_level;
output wire                                             busy;
output wire                                             idle;
output wire                                             fault;
output wire [3:0]                                       fault_code;

generate
    if ((TAG_WIDTH != 12) || (LITERAL_WIDTH != 4) || (EPOCH_WIDTH != 16)) begin : g_bad_fixed
        wfq_error_fixed_tag_literal_epoch_widths u_error ();
    end
    if (ISSUE_INTERVAL != 5) begin : g_bad_interval
        wfq_error_stage4_requires_issue_interval_5 u_error ();
    end
endgenerate

wire                                                    core_rstn;
wire                                                    init_guard;
wire                                                    meta_write_en;
wire [12:0]                                             meta_write_addr;
wire                                                    free_write_en;
wire [ADDR_WIDTH-1:0]                                   free_write_addr;
wire [PTR_WIDTH-1:0]                                    free_write_data;
wire                                                    insert_fire;
wire                                                    extract_fire;
wire                                                    request_context;
wire                                                    context_available;
wire                                                    cycle_allow;
wire                                                    commit_req;
wire                                                    commit_is_insert;
wire                                                    commit_context;
wire                                                    commit_fire;
wire                                                    patch_req;
wire                                                    patch_context;
wire [1:0]                                              wb_due;
wire [1:0]                                              context_valid;
wire [3:0]                                              context_error;
wire [3:0]                                              list_error;
wire [3:0]                                              metadata_error;
wire [3:0]                                              external_error;
wire [PAYLOAD_WIDTH-1:0]                                head_payload;
wire [PAYLOAD_WIDTH-1:0]                                old_payload;
wire [PTR_WIDTH-1:0]                                    release_ptr;
wire [15:0]                                             operation_epoch;
wire [15:0]                                             base_epoch;
wire [15:0]                                             bank0_epoch;
wire [15:0]                                             bank1_epoch;
wire [COUNT_WIDTH-1:0]                                  bank0_count;
wire [COUNT_WIDTH-1:0]                                  bank1_count;
wire                                                    metadata_ready;
wire                                                    metadata_due;
wire                                                    metadata_context;
wire                                                    alloc_valid;
wire                                                    alloc_context;
wire [PTR_WIDTH-1:0]                                    alloc_ptr;
wire                                                    pred_valid;
wire                                                    pred_context;
wire                                                    pred_bank;
wire                                                    pred_found;
wire [11:0]                                             pred_tag;
wire [PTR_WIDTH-1:0]                                    pred_ptr;
wire [1:0]                                              rsp_count;
wire [1:0]                                              rsp_reserved;
wire [PAYLOAD_WIDTH-1:0]                                extract_payload;
reg                                                     insert_commit_d1;
reg                                                     extract_commit_d1;

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

assign external_error = min_fault(metadata_error,min_fault(list_error,context_error));
assign insert_commit = insert_commit_d1;
assign extract_commit = extract_commit_d1;
assign min_epoch_out = extract_payload[PAYLOAD_WIDTH-1 -: 16];
assign min_tag_out = extract_payload[FLOW_ID_WIDTH +: 12];
assign min_tag_flow_id = extract_payload[FLOW_ID_WIDTH-1:0];
assign idle = init_done & ~fault & ~busy & (rsp_count == 0) & (rsp_reserved == 0);

always @(posedge clk or negedge core_rstn) begin
    if (!core_rstn) begin
        insert_commit_d1 <= 1'b0;
        extract_commit_d1 <= 1'b0;
    end
    else begin
        insert_commit_d1 <= commit_fire & commit_is_insert;
        extract_commit_d1 <= commit_fire & ~commit_is_insert;
    end
end

///////////////////////////////////////////////////////////////////////////////
// Shared initialization: DATA/NEXT are never bulk-cleared or asynchronously reset
///////////////////////////////////////////////////////////////////////////////
wfq_reset_sync u_reset (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .core_rstn                                          (core_rstn)
);

wfq_init_ctrl #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_init (
    .clk                                                (clk),
    .rstn                                               (core_rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .meta_write_en                                      (meta_write_en),
    .meta_write_addr                                    (meta_write_addr),
    .l1_write_en                                        (),
    .l1_write_addr                                      (),
    .l2_write_en                                        (),
    .l2_write_addr                                      (),
    .l3_write_en                                        (),
    .l3_write_addr                                      (),
    .free_write_en                                      (free_write_en),
    .free_write_addr                                    (free_write_addr),
    .free_write_data                                    (free_write_data)
);

///////////////////////////////////////////////////////////////////////////////
// Shared issuer and global minimum-code inhibit. Proposals never depend on gate.
///////////////////////////////////////////////////////////////////////////////
wfq_resource_ctrl #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH),
    .FLOW_ID_WIDTH                                      (FLOW_ID_WIDTH),
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_resource (
    .clk                                                (clk),
    .rstn                                               (core_rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .init_free_write_en                                 (free_write_en),
    .init_free_write_addr                               (free_write_addr),
    .init_free_write_data                               (free_write_data),
    .halt                                               (1'b0),
    .insert_val                                         (insert_val),
    .insert_epoch                                       (insert_epoch),
    .extract_req                                        (extract_req),
    .request_context                                    (request_context),
    .context_available                                  (context_available),
    .path_ready                                         (metadata_ready),
    .insert_ready                                       (insert_ready),
    .extract_ready                                      (extract_ready),
    .insert_fire                                        (insert_fire),
    .extract_fire                                       (extract_fire),
    .insert_epoch_blocked                               (insert_epoch_blocked),
    .issue_open                                         (),
    .alloc_valid                                        (alloc_valid),
    .alloc_context                                      (alloc_context),
    .alloc_ptr                                          (alloc_ptr),
    .commit_req                                         (commit_req),
    .commit_insert                                      (commit_is_insert),
    .commit_context                                     (commit_context),
    .commit_epoch                                       (operation_epoch),
    .release_ptr                                        (release_ptr),
    .response_payload                                   (old_payload),
    .external_error_code                                (external_error),
    .commit_due                                         (),
    .commit_fire                                        (commit_fire),
    .cycle_allow                                        (cycle_allow),
    .extract_out_ready                                  (extract_out_ready),
    .extract_val                                        (extract_val),
    .extract_payload                                    (extract_payload),
    .rsp_count                                          (rsp_count),
    .rsp_reserved                                       (rsp_reserved),
    .free_count                                         (),
    .alloc_reserved                                     (),
    .queue_level                                        (queue_level),
    .empty                                              (empty),
    .full                                               (full),
    .base_epoch                                         (base_epoch),
    .bank_valid                                         (),
    .bank0_epoch                                        (bank0_epoch),
    .bank1_epoch                                        (bank1_epoch),
    .bank0_count                                        (bank0_count),
    .bank1_count                                        (bank1_count),
    .error_valid                                        (),
    .error_code                                         (),
    .fault                                              (fault),
    .fault_code                                         (fault_code)
);

wfq_commit_ctrl #(
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_commit (
    .clk                                                (clk),
    .rstn                                               (core_rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .halt                                               (fault),
    .update_allow                                       (cycle_allow),
    .insert_fire                                        (insert_fire),
    .extract_fire                                       (extract_fire),
    .request_context                                    (request_context),
    .context_available                                  (context_available),
    .commit_req                                         (commit_req),
    .commit_insert                                      (commit_is_insert),
    .commit_context                                     (commit_context),
    .patch_req                                          (patch_req),
    .patch_context                                      (patch_context),
    .wb_due                                             (wb_due),
    .context_valid                                      (context_valid),
    .busy                                               (busy),
    .error_code                                         (context_error)
);

///////////////////////////////////////////////////////////////////////////////
// Single-copy Trie/TT/RC: all physical metadata writes share cycle_allow
///////////////////////////////////////////////////////////////////////////////
wfq_key_metadata #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH),
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_metadata (
    .clk                                                (clk),
    .rstn                                               (core_rstn),
    .init_done                                          (init_done),
    .init_write_en                                      (meta_write_en),
    .init_write_addr                                    (meta_write_addr),
    .halt                                               (fault),
    .request_valid                                      (insert_fire | extract_fire),
    .request_ready                                      (metadata_ready),
    .request_insert                                     (insert_fire),
    .request_context                                    (request_context),
    .request_bank                                       (insert_fire ? insert_epoch[0] : head_payload[PAYLOAD_WIDTH-16]),
    .request_tag                                        (insert_fire ? insert_tag : head_payload[FLOW_ID_WIDTH +: 12]),
    .alloc_valid                                        (alloc_valid),
    .alloc_context                                      (alloc_context),
    .alloc_ptr                                          (alloc_ptr),
    .commit_allow                                       (cycle_allow),
    .pred_valid                                         (pred_valid),
    .pred_context                                       (pred_context),
    .pred_bank                                          (pred_bank),
    .pred_found                                         (pred_found),
    .pred_tag                                           (pred_tag),
    .pred_exact                                         (),
    .pred_path                                          (),
    .pred_ptr                                           (pred_ptr),
    .prepare_valid                                      (),
    .prepare_old_count                                  (),
    .prepare_new_count                                  (),
    .commit_due                                         (metadata_due),
    .commit_ok                                          (),
    .commit_fire                                        (),
    .commit_done                                        (),
    .commit_context                                     (metadata_context),
    .error_valid                                        (),
    .error_code                                         (metadata_error),
    .fault                                              (),
    .fault_code                                         ()
);

///////////////////////////////////////////////////////////////////////////////
// List manager retains completed descriptors independently of metadata workspace
///////////////////////////////////////////////////////////////////////////////
wfq_list_manager #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH),
    .FLOW_ID_WIDTH                                      (FLOW_ID_WIDTH),
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_list (
    .clk                                                (clk),
    .rstn                                               (core_rstn),
    .init_done                                          (init_done),
    .init_guard                                         (init_guard),
    .halt                                               (fault),
    .update_allow                                       (cycle_allow),
    .insert_fire                                        (insert_fire),
    .extract_fire                                       (extract_fire),
    .request_context                                    (request_context),
    .insert_payload                                     ({insert_epoch,insert_tag,insert_flow_id}),
    .queue_level                                        (queue_level),
    .base_epoch                                         (base_epoch),
    .bank0_epoch                                        (bank0_epoch),
    .bank1_epoch                                        (bank1_epoch),
    .bank0_count                                        (bank0_count),
    .bank1_count                                        (bank1_count),
    .alloc_valid                                        (alloc_valid),
    .alloc_context                                      (alloc_context),
    .alloc_ptr                                          (alloc_ptr),
    .pred_valid                                         (pred_valid),
    .pred_context                                       (pred_context),
    .pred_bank                                          (pred_bank),
    .pred_found                                         (pred_found),
    .pred_tag                                           (pred_tag),
    .pred_ptr                                           (pred_ptr),
    .metadata_error_code                                (metadata_error),
    .metadata_commit_due                                (metadata_due),
    .metadata_commit_context                            (metadata_context),
    .commit_req                                         (commit_req),
    .commit_insert                                      (commit_is_insert),
    .commit_context                                     (commit_context),
    .patch_req                                          (patch_req),
    .patch_context                                      (patch_context),
    .wb_due                                             (wb_due),
    .head_payload                                       (head_payload),
    .operation_epoch                                    (operation_epoch),
    .release_ptr                                        (release_ptr),
    .response_payload                                   (old_payload),
    .error_code                                         (list_error)
);

endmodule

`default_nettype wire
