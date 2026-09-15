// Project : wfq_tag_sort_engine
// File    : wfq_key_metadata.v
// Spec    : Design_Spec_V1.2.md, sections 6-8, 10.2, 10.3, 11.1 and 13.2
// Function: FAST5 Trie/TT/RC subsystem with exact updates and atomic write gate.
// Scope   : Caller owns epoch eligibility, allocation, list, global commit
//           checks, response credits and execution/writeback contexts.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_key_metadata #(
    parameter integer PTR_WIDTH      = 10,
    parameter integer MEM_DEPTH      = 1024,
    parameter integer ISSUE_INTERVAL = 5
) (
    clk,
    rstn,
    init_done,
    init_write_en,
    init_write_addr,
    halt,
    request_valid,
    request_ready,
    request_insert,
    request_context,
    request_bank,
    request_tag,
    alloc_valid,
    alloc_context,
    alloc_ptr,
    commit_allow,
    pred_valid,
    pred_context,
    pred_bank,
    pred_found,
    pred_tag,
    pred_exact,
    pred_path,
    pred_ptr,
    prepare_valid,
    prepare_old_count,
    prepare_new_count,
    commit_due,
    commit_ok,
    commit_fire,
    commit_done,
    commit_context,
    error_valid,
    error_code,
    fault,
    fault_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH            = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH           = wfq_clog2(MEM_DEPTH + 1);
localparam integer FALLBACK_READ_EDGE    = ISSUE_INTERVAL - 4;
localparam integer TT_READ_EDGE          = ISSUE_INTERVAL - 3;
localparam integer NEXT_READ_EDGE        = ISSUE_INTERVAL - 2;
localparam integer INSERT_COMMIT_LATENCY = ISSUE_INTERVAL - 1;
localparam integer EXTRACT_COMMIT_LATENCY = 1;
localparam [2:0] ISSUE_RELOAD             = ISSUE_INTERVAL - 1;

input  wire                                             clk;
input  wire                                             rstn;

// Connect the shared init controller's meta_write_en/meta_write_addr here.
input  wire                                             init_done;
input  wire                                             init_write_en;
input  wire [12:0]                                      init_write_addr;
input  wire                                             halt;

// ready is a storage issue window only; global admission must qualify it.
input  wire                                             request_valid;
output wire                                             request_ready;
input  wire                                             request_insert;
input  wire                                             request_context;
input  wire                                             request_bank;
input  wire [11:0]                                      request_tag;

// FREE read result is required at E1 for an insert; no allocation on extract.
input  wire                                             alloc_valid;
input  wire                                             alloc_context;
input  wire [PTR_WIDTH-1:0]                             alloc_ptr;

// Global all-or-none gate. Low on a due edge cancels, never stalls/retries.
input  wire                                             commit_allow;

// Same-bank predecessor only, valid before E3 for direct NEXT read initiation.
output wire                                             pred_valid;
output wire                                             pred_context;
output wire                                             pred_bank;
output wire                                             pred_found;
output wire [11:0]                                      pred_tag;
output wire                                             pred_exact;
output wire [1:0]                                       pred_path;
output wire [PTR_WIDTH-1:0]                             pred_ptr;

// Insert plan before E3; extract plan before E1. No extra descriptor edge.
output wire                                             prepare_valid;
output wire [COUNT_WIDTH-1:0]                           prepare_old_count;
output wire [COUNT_WIDTH-1:0]                           prepare_new_count;
output wire                                             commit_due;
output wire                                             commit_ok;
output wire                                             commit_fire;
output wire                                             commit_done;
output wire                                             commit_context;

// Combinational pre-edge event plus local sticky status, for global aggregation.
output wire                                             error_valid;
output wire [3:0]                                       error_code;
output wire                                             fault;
output wire [3:0]                                       fault_code;

reg                                                     active_d;
reg [2:0]                                               phase_d;
reg [2:0]                                               gap_d;
reg                                                     insert_d;
reg                                                     context_d;
reg                                                     bank_d;
reg [11:0]                                              tag_d;
reg [PTR_WIDTH-1:0]                                     alloc_ptr_d;
reg [COUNT_WIDTH-1:0]                                   old_count_d;
reg                                                     rc_context_d;
reg                                                     tt_context_d;
reg                                                     found_d;
reg                                                     exact_d;
reg [11:0]                                              pred_tag_d;
reg [1:0]                                               path_d;
reg                                                     body_valid_d;
reg [COUNT_WIDTH-1:0]                                   body_count_d;
reg                                                     body_tt_write_d;
reg [PTR_WIDTH:0]                                       body_tt_link_d;
reg                                                     body_l1_write_d;
reg                                                     body_l2_write_d;
reg                                                     body_l3_write_d;
reg [15:0]                                              body_l1_data_d;
reg [15:0]                                              body_l2_data_d;
reg [15:0]                                              body_l3_data_d;
reg                                                     commit_done_d1;
reg                                                     fault_d;
reg [3:0]                                               fault_code_d;

wire                                                    live;
wire                                                    init_mode;
wire                                                    request_fire;
wire                                                    at_first;
wire                                                    at_tt;
wire                                                    at_pred;
wire [12:0]                                             current_key;
wire [31:0]                                             l1_flat;
wire [511:0]                                            l2_flat;
wire [15:0]                                             current_root;
wire [15:0]                                             current_parent;

generate
    if ((ISSUE_INTERVAL != 5) || (FALLBACK_READ_EDGE != 1)) begin : g_bad_interval
        wfq_error_stage2_requires_issue_interval_5 u_error ();
    end
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0) ||
        (PTR_WIDTH < 4) || (PTR_WIDTH > 16) || (PTR_WIDTH < ADDR_WIDTH)) begin : g_bad_capacity
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
endgenerate

assign live = rstn & init_done & ~halt & ~fault_d;
assign init_mode = rstn & ~init_done & ~halt & ~fault_d;
assign request_ready = live & ~active_d & (gap_d == 0) & ~init_write_en;
assign request_fire = request_valid & request_ready;
assign at_first = active_d & (phase_d == 1);
assign at_tt = active_d & insert_d & (phase_d == TT_READ_EDGE);
assign at_pred = active_d & insert_d & (phase_d == NEXT_READ_EDGE);
assign current_key = {bank_d, tag_d};

///////////////////////////////////////////////////////////////////////////////
// Same-bank search and its E1 exact snapshots
///////////////////////////////////////////////////////////////////////////////
wire                                                    search_read_en;
wire [8:0]                                              search_read_addr;
wire                                                    search_valid;
wire                                                    search_context;
wire                                                    search_bank;
wire                                                    search_found;
wire [11:0]                                             search_tag;
wire                                                    search_exact;
wire [1:0]                                              search_path;
wire [15:0]                                             snapshot_root;
wire [15:0]                                             snapshot_parent;
wire [15:0]                                             snapshot_leaf;
wire [3:0]                                              search_error;
wire                                                    leaf_read_valid;
wire [15:0]                                             leaf_read_data;

wfq_trie_search #(
    .ISSUE_INTERVAL                                     (ISSUE_INTERVAL)
) u_search (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .halt                                               (halt | fault_d | ~init_done),
    .request                                            (request_fire & request_insert),
    .request_context                                    (request_context),
    .request_bank                                       (request_bank),
    .request_tag                                        (request_tag),
    .l1_flat                                            (l1_flat),
    .l2_flat                                            (l2_flat),
    .leaf_read_en                                       (search_read_en),
    .leaf_read_addr                                     (search_read_addr),
    .leaf_read_valid                                    (leaf_read_valid),
    .leaf_read_data                                     (leaf_read_data),
    .result_valid                                       (search_valid),
    .result_context                                     (search_context),
    .result_bank                                        (search_bank),
    .result_found                                       (search_found),
    .result_tag                                         (search_tag),
    .result_exact                                       (search_exact),
    .result_path                                        (search_path),
    .old_root                                           (snapshot_root),
    .old_parent                                         (snapshot_parent),
    .old_leaf                                           (snapshot_leaf),
    .error_code                                         (search_error)
);

///////////////////////////////////////////////////////////////////////////////
// RC reads at E0 and writes at the single commit edge (or during init)
///////////////////////////////////////////////////////////////////////////////
wire                                                    rc_read_en;
wire                                                    rc_read_valid;
wire [COUNT_WIDTH-1:0]                                  rc_read_count;
wire                                                    rc_write_en;
wire [12:0]                                             rc_write_key;
wire [COUNT_WIDTH-1:0]                                  rc_write_count;
wire [COUNT_WIDTH-1:0]                                  planned_count;

assign rc_read_en = request_fire & ~error_valid;
assign rc_write_en = (init_mode & init_write_en) | commit_fire;
assign rc_write_key = init_mode ? init_write_addr : current_key;
assign rc_write_count = init_mode ? {COUNT_WIDTH{1'b0}} : planned_count;

wfq_tag_refcount_array #(
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_rc (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (rc_read_en),
    .read_key                                           ({request_bank, request_tag}),
    .write_en                                           (rc_write_en),
    .write_key                                          (rc_write_key),
    .write_count                                        (rc_write_count),
    .read_valid                                         (rc_read_valid),
    .read_count                                         (rc_read_count)
);

///////////////////////////////////////////////////////////////////////////////
// TT read address is the combinational search result before E2
///////////////////////////////////////////////////////////////////////////////
wire                                                    tt_read_en;
wire                                                    tt_read_valid;
wire [PTR_WIDTH:0]                                      tt_read_link;
wire                                                    tt_write_en;
wire [12:0]                                             tt_write_key;
wire [PTR_WIDTH:0]                                      tt_write_link;
wire                                                    planned_tt_write;
wire [PTR_WIDTH:0]                                      planned_tt_link;

assign tt_read_en = live & at_tt & search_valid & search_found & ~error_valid;
assign tt_write_en = (init_mode & init_write_en) | (commit_fire & planned_tt_write);
assign tt_write_key = init_mode ? init_write_addr : current_key;
assign tt_write_link = init_mode ? {(PTR_WIDTH+1){1'b0}} : planned_tt_link;

wfq_translation_table #(
    .PTR_WIDTH                                          (PTR_WIDTH)
) u_tt (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (tt_read_en),
    .read_key                                           ({bank_d, search_tag}),
    .write_en                                           (tt_write_en),
    .write_key                                          (tt_write_key),
    .write_link                                         (tt_write_link),
    .read_valid                                         (tt_read_valid),
    .read_link                                          (tt_read_link)
);

///////////////////////////////////////////////////////////////////////////////
// Exact marker plan: extract consumes RAM q directly; insert locks body at E3
///////////////////////////////////////////////////////////////////////////////
wire                                                    update_valid;
wire [COUNT_WIDTH-1:0]                                  update_old_count;
wire [COUNT_WIDTH-1:0]                                  update_count;
wire                                                    update_tt_write;
wire [PTR_WIDTH:0]                                      update_tt_link;
wire                                                    update_l1_write;
wire                                                    update_l2_write;
wire                                                    update_l3_write;
wire [15:0]                                             update_l1_data;
wire [15:0]                                             update_l2_data;
wire [15:0]                                             update_l3_data;
wire [3:0]                                              update_error;
wire                                                    planned_l1_write;
wire                                                    planned_l2_write;
wire                                                    planned_l3_write;
wire [15:0]                                             planned_l1_data;
wire [15:0]                                             planned_l2_data;
wire [15:0]                                             planned_l3_data;

// Invalid RAM returns are a stage fault, not evidence of bad count/markers.
assign update_valid = live & (at_pred |
    (at_first & ~insert_d & rc_read_valid & leaf_read_valid & (rc_context_d == context_d)));
assign update_old_count = insert_d ? old_count_d : rc_read_count;
assign planned_count = insert_d ? body_count_d : update_count;
assign planned_tt_write = insert_d ? body_tt_write_d : update_tt_write;
assign planned_tt_link = insert_d ? body_tt_link_d : update_tt_link;
assign planned_l1_write = insert_d ? body_l1_write_d : update_l1_write;
assign planned_l2_write = insert_d ? body_l2_write_d : update_l2_write;
assign planned_l3_write = insert_d ? body_l3_write_d : update_l3_write;
assign planned_l1_data = insert_d ? body_l1_data_d : update_l1_data;
assign planned_l2_data = insert_d ? body_l2_data_d : update_l2_data;
assign planned_l3_data = insert_d ? body_l3_data_d : update_l3_data;

wfq_metadata_update #(
    .PTR_WIDTH                                          (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_update (
    .valid                                              (update_valid),
    .is_insert                                          (insert_d),
    .tag                                                (tag_d),
    .new_ptr                                            (alloc_ptr_d),
    .old_count                                          (update_old_count),
    .old_root                                           (insert_d ? snapshot_root : current_root),
    .old_parent                                         (insert_d ? snapshot_parent : current_parent),
    .old_leaf                                           (insert_d ? snapshot_leaf : leaf_read_data),
    .trie_exact                                         (exact_d),
    .new_count                                          (update_count),
    .tt_write                                           (update_tt_write),
    .tt_link                                            (update_tt_link),
    .l1_write                                           (update_l1_write),
    .l1_data                                            (update_l1_data),
    .l2_write                                           (update_l2_write),
    .l2_data                                            (update_l2_data),
    .l3_write                                           (update_l3_write),
    .l3_data                                            (update_l3_data),
    .error_code                                         (update_error)
);

assign prepare_valid = update_valid & ~error_valid;
assign prepare_old_count = update_old_count;
assign prepare_new_count = update_count;

///////////////////////////////////////////////////////////////////////////////
// Single authoritative upper storage and single physical L3 read-or-write port
///////////////////////////////////////////////////////////////////////////////
wire                                                    l1_write_en;
wire                                                    l1_write_addr;
wire [15:0]                                             l1_write_data;
wire                                                    l2_write_en;
wire [4:0]                                              l2_write_addr;
wire [15:0]                                             l2_write_data;
wire                                                    leaf_read_intent;
wire                                                    leaf_write_intent;
wire                                                    leaf_read_en;
wire                                                    leaf_write_en;
wire [8:0]                                              leaf_addr;
wire [15:0]                                             leaf_write_data;
wire                                                    leaf_access_conflict;

assign l1_write_en = (init_mode & init_write_en & (init_write_addr < 2)) |
    (commit_fire & planned_l1_write);
assign l1_write_addr = init_mode ? init_write_addr[0] : bank_d;
assign l1_write_data = init_mode ? 16'd0 : planned_l1_data;
assign l2_write_en = (init_mode & init_write_en & (init_write_addr < 32)) |
    (commit_fire & planned_l2_write);
assign l2_write_addr = init_mode ? init_write_addr[4:0] : {bank_d, tag_d[11:8]};
assign l2_write_data = init_mode ? 16'd0 : planned_l2_data;
assign leaf_read_intent = search_read_en | (request_fire & ~request_insert);
assign leaf_write_intent = (init_mode & init_write_en & (init_write_addr < 512)) |
    (commit_due & planned_l3_write);
assign leaf_read_en = leaf_read_intent & ~error_valid;
assign leaf_write_en = (init_mode & init_write_en & (init_write_addr < 512)) |
    (commit_fire & planned_l3_write);
assign leaf_addr = init_mode ? init_write_addr[8:0] :
    ((commit_fire & planned_l3_write) ? {bank_d, tag_d[11:4]} :
    ((request_fire & ~request_insert) ? {request_bank, request_tag[11:4]} : search_read_addr));
assign leaf_write_data = init_mode ? 16'd0 : planned_l3_data;

wfq_trie_upper_regs u_upper (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .l1_write_en                                        (l1_write_en),
    .l1_write_addr                                      (l1_write_addr),
    .l1_write_data                                      (l1_write_data),
    .l2_write_en                                        (l2_write_en),
    .l2_write_addr                                      (l2_write_addr),
    .l2_write_data                                      (l2_write_data),
    .read_bank                                          (bank_d),
    .read_a                                             (tag_d[11:8]),
    .l1_read_data                                       (current_root),
    .l2_read_data                                       (current_parent),
    .l1_flat                                            (l1_flat),
    .l2_flat                                            (l2_flat)
);

wfq_sync_ram_1rw #(
    .DATA_WIDTH                                         (16),
    .MEM_DEPTH                                          (512)
) u_leaf (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (leaf_read_en),
    .write_en                                           (leaf_write_en),
    .addr                                               (leaf_addr),
    .write_data                                         (leaf_write_data),
    .read_valid                                         (leaf_read_valid),
    .read_data                                          (leaf_read_data),
    .access_conflict                                    (leaf_access_conflict)
);

///////////////////////////////////////////////////////////////////////////////
// Pre-edge fault selection. No gated physical write signal feeds this check.
///////////////////////////////////////////////////////////////////////////////
wire                                                    count_bad;
wire                                                    metadata_bad;
wire                                                    schedule_bad;
wire                                                    pointer_bad;

assign count_bad = (update_error == `WFQ_FAULT_RC) |
    (at_first & rc_read_valid &
    (insert_d ? (rc_read_count >= MEM_DEPTH) :
    ((rc_read_count == 0) | (rc_read_count > MEM_DEPTH))));
assign metadata_bad = (search_error == `WFQ_FAULT_METADATA) |
    (update_error == `WFQ_FAULT_METADATA) |
    (at_tt & search_valid & (search_exact != (old_count_d != 0))) |
    (at_pred & found_d & tt_read_valid & ~tt_read_link[PTR_WIDTH]);
assign schedule_bad = (search_error == `WFQ_FAULT_SCHEDULE) |
    (init_done & init_write_en) |
    (leaf_read_intent & leaf_write_intent) |
    (at_first & (~rc_read_valid | (rc_context_d != context_d))) |
    (at_first & ~insert_d & ~leaf_read_valid) |
    (at_first & insert_d & (~alloc_valid | (alloc_context != context_d))) |
    (at_tt & (~search_valid | (search_context != context_d) | (search_bank != bank_d))) |
    (at_pred & ((tt_read_valid != found_d) | (found_d & (tt_context_d != context_d)))) |
    (commit_due & insert_d & ~body_valid_d);
assign pointer_bad = (update_error == `WFQ_FAULT_POINTER) |
    (at_first & insert_d & alloc_valid & (alloc_ptr >= MEM_DEPTH)) |
    (at_pred & found_d & tt_read_valid & tt_read_link[PTR_WIDTH] &
    (tt_read_link[PTR_WIDTH-1:0] >= MEM_DEPTH));
assign error_code = !live ? `WFQ_FAULT_NONE :
    (count_bad ? `WFQ_FAULT_RC : (metadata_bad ? `WFQ_FAULT_METADATA :
    (schedule_bad ? `WFQ_FAULT_SCHEDULE : (pointer_bad ? `WFQ_FAULT_POINTER : `WFQ_FAULT_NONE))));
assign error_valid = live & (error_code != `WFQ_FAULT_NONE);

assign commit_due = live & active_d &
    (insert_d ? (phase_d == INSERT_COMMIT_LATENCY) : (phase_d == EXTRACT_COMMIT_LATENCY));
assign commit_ok = commit_due & ~error_valid;
assign commit_fire = commit_ok & commit_allow;
assign commit_done = commit_done_d1;
assign commit_context = context_d;
assign fault = fault_d;
assign fault_code = fault_code_d;

assign pred_valid = live & at_pred & ~error_valid;
assign pred_context = context_d;
assign pred_bank = bank_d;
assign pred_found = pred_valid & found_d;
assign pred_tag = pred_found ? pred_tag_d : 12'd0;
assign pred_exact = pred_found & exact_d;
assign pred_path = pred_found ? path_d : 2'd0;
assign pred_ptr = pred_found ? tt_read_link[PTR_WIDTH-1:0] : {PTR_WIDTH{1'b0}};

///////////////////////////////////////////////////////////////////////////////
// Metadata phase/issue control; extraction still keeps the five-edge issue gap
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        active_d <= 1'b0;
        phase_d <= 3'd0;
        gap_d <= 3'd0;
        insert_d <= 1'b0;
        context_d <= 1'b0;
        bank_d <= 1'b0;
        tag_d <= 12'd0;
        commit_done_d1 <= 1'b0;
        fault_d <= 1'b0;
        fault_code_d <= `WFQ_FAULT_NONE;
    end
    else begin
        commit_done_d1 <= commit_fire;
        if (error_valid && !fault_d) begin
            fault_d <= 1'b1;
            fault_code_d <= error_code;
        end
        if (!init_done || halt || fault_d || error_valid) begin
            active_d <= 1'b0;
            phase_d <= 3'd0;
            gap_d <= 3'd0;
        end
        else begin
            if (gap_d != 0) begin
                gap_d <= gap_d - 1'b1;
            end
            if (request_fire) begin
                active_d <= 1'b1;
                phase_d <= 3'd1;
                gap_d <= ISSUE_RELOAD;
                insert_d <= request_insert;
                context_d <= request_context;
                bank_d <= request_bank;
                tag_d <= request_tag;
            end
            else if (active_d) begin
                if (commit_due) begin
                    active_d <= 1'b0;
                    phase_d <= 3'd0;
                end
                else begin
                    phase_d <= phase_d + 1'b1;
                end
            end
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// Return ownership and metadata body. E3 captures; E4 writes these values.
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        alloc_ptr_d <= {PTR_WIDTH{1'b0}};
        old_count_d <= {COUNT_WIDTH{1'b0}};
        rc_context_d <= 1'b0;
        tt_context_d <= 1'b0;
        found_d <= 1'b0;
        exact_d <= 1'b0;
        pred_tag_d <= 12'd0;
        path_d <= 2'd0;
        body_valid_d <= 1'b0;
        body_count_d <= {COUNT_WIDTH{1'b0}};
        body_tt_write_d <= 1'b0;
        body_tt_link_d <= {(PTR_WIDTH+1){1'b0}};
        body_l1_write_d <= 1'b0;
        body_l2_write_d <= 1'b0;
        body_l3_write_d <= 1'b0;
        body_l1_data_d <= 16'd0;
        body_l2_data_d <= 16'd0;
        body_l3_data_d <= 16'd0;
    end
    else if (live && !error_valid) begin
        if (request_fire) begin
            rc_context_d <= request_context;
            body_valid_d <= 1'b0;
        end
        if (at_first && insert_d) begin
            old_count_d <= rc_read_count;
            alloc_ptr_d <= alloc_ptr;
        end
        if (at_tt) begin
            found_d <= search_found;
            exact_d <= search_exact;
            pred_tag_d <= search_tag;
            path_d <= search_path;
            tt_context_d <= context_d;
        end
        if (at_pred) begin
            body_valid_d <= 1'b1;
            body_count_d <= update_count;
            body_tt_write_d <= update_tt_write;
            body_tt_link_d <= update_tt_link;
            body_l1_write_d <= update_l1_write;
            body_l2_write_d <= update_l2_write;
            body_l3_write_d <= update_l3_write;
            body_l1_data_d <= update_l1_data;
            body_l2_data_d <= update_l2_data;
            body_l3_data_d <= update_l3_data;
        end
    end
end

endmodule

`default_nettype wire
