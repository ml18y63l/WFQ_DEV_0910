// Project : wfq_tag_sort_engine
// File    : wfq_list_manager.v
// Spec    : Design_Spec_V1.2.md, sections 7.4, 9-11 and 13
// Function: Single-copy DATA/NEXT, stable global list, bank boundaries and cache.
// Timing  : Body captured E3, successor consumed directly at E4, patch E5,
//           overlay/context handoff E6. Extract prefetch E0, commit E1, done E2.
// Contract: Every physical write and committed state update uses update_allow.
//           Error checks use raw proposals, never their gated write enables.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_list_manager #(
    parameter integer PTR_WIDTH      = 10,
    parameter integer MEM_DEPTH      = 1024,
    parameter integer FLOW_ID_WIDTH  = 9,
    parameter integer ISSUE_INTERVAL = 5
) (

    clk,
    rstn,
    init_done,
    init_guard,
    halt,
    update_allow,
    insert_fire,
    extract_fire,
    request_context,
    insert_payload,
    queue_level,
    base_epoch,
    bank0_epoch,
    bank1_epoch,
    bank0_count,
    bank1_count,
    alloc_valid,
    alloc_context,
    alloc_ptr,
    pred_valid,
    pred_context,
    pred_bank,
    pred_found,
    pred_tag,
    pred_ptr,
    metadata_error_code,
    metadata_commit_due,
    metadata_commit_context,
    commit_req,
    commit_insert,
    commit_context,
    patch_req,
    patch_context,
    wb_due,
    head_payload,
    operation_epoch,
    release_ptr,
    response_payload,
    error_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam integer LINK_WIDTH = PTR_WIDTH + 1;
localparam integer PAYLOAD_WIDTH = 28 + FLOW_ID_WIDTH;
localparam integer DESC_WIDTH = PAYLOAD_WIDTH + PTR_WIDTH + 2*LINK_WIDTH;
localparam integer P_LSB = LINK_WIDTH;
localparam integer N_LSB = 2*LINK_WIDTH;
localparam integer DATA_LSB = 2*LINK_WIDTH + PTR_WIDTH;
localparam integer NEXT_READ_EDGE = ISSUE_INTERVAL - 2;
localparam integer INSERT_COMMIT_LATENCY = ISSUE_INTERVAL - 1;
localparam integer RANGE_WIDTH = ((PTR_WIDTH > COUNT_WIDTH) ? PTR_WIDTH : COUNT_WIDTH) + 1;
localparam [RANGE_WIDTH-1:0] PTR_LIMIT = MEM_DEPTH;
localparam [LINK_WIDTH-1:0] NULL_LINK = {LINK_WIDTH{1'b0}};

// Shared clock, initialization and global fail-stop/permission
input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             init_done;
input  wire                                             init_guard;
input  wire                                             halt;
input  wire                                             update_allow;

// Accepted operation; the issuer has already checked resources and RR
input  wire                                             insert_fire;
input  wire                                             extract_fire;
input  wire                                             request_context;
input  wire [PAYLOAD_WIDTH-1:0]                         insert_payload;

// Authoritative committed counts and identities from resource control
input  wire [COUNT_WIDTH-1:0]                           queue_level;
input  wire [15:0]                                      base_epoch;
input  wire [15:0]                                      bank0_epoch;
input  wire [15:0]                                      bank1_epoch;
input  wire [COUNT_WIDTH-1:0]                           bank0_count;
input  wire [COUNT_WIDTH-1:0]                           bank1_count;

// E1 allocation and E3 same-bank predecessor returns
input  wire                                             alloc_valid;
input  wire                                             alloc_context;
input  wire [PTR_WIDTH-1:0]                             alloc_ptr;
input  wire                                             pred_valid;
input  wire                                             pred_context;
input  wire                                             pred_bank;
input  wire                                             pred_found;
input  wire [11:0]                                      pred_tag;
input  wire [PTR_WIDTH-1:0]                             pred_ptr;
input  wire [3:0]                                       metadata_error_code;
input  wire                                             metadata_commit_due;
input  wire                                             metadata_commit_context;

// Raw context deadlines, independent of update_allow
input  wire                                             commit_req;
input  wire                                             commit_insert;
input  wire                                             commit_context;
input  wire                                             patch_req;
input  wire                                             patch_context;
input  wire [1:0]                                       wb_due;

// Head for E0 metadata lookup; saved old head for E1 response/release
output wire [PAYLOAD_WIDTH-1:0]                         head_payload;
output wire [15:0]                                      operation_epoch;
output wire [PTR_WIDTH-1:0]                             release_ptr;
output wire [PAYLOAD_WIDTH-1:0]                         response_payload;
output wire [3:0]                                       error_code;

generate
    if (ISSUE_INTERVAL != 5) begin : g_bad_interval
        wfq_error_stage4_requires_issue_interval_5 u_error ();
    end
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH-1)) != 0) || (PTR_WIDTH < 4) ||
        (PTR_WIDTH > 16) || (PTR_WIDTH < ADDR_WIDTH)) begin : g_bad_capacity
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
    if ((FLOW_ID_WIDTH < 8) || (FLOW_ID_WIDTH > 12)) begin : g_bad_flow
        wfq_error_flow_id_width_must_be_8_to_12 u_error ();
    end
endgenerate

function ptr_good;
    input [PTR_WIDTH-1:0] p;
    reg [RANGE_WIDTH-1:0]                               wide_p;
    begin
        wide_p = {{(RANGE_WIDTH-PTR_WIDTH){1'b0}},p};
        ptr_good = (wide_p < PTR_LIMIT);
    end
endfunction

// NULL carries no meaningful address; never compare its ignored pointer bits.
function link_equal;
    input [LINK_WIDTH-1:0] a;
    input [LINK_WIDTH-1:0] b;
    begin
        link_equal = (a[PTR_WIDTH] == b[PTR_WIDTH]) &&
            (!a[PTR_WIDTH] || (a[PTR_WIDTH-1:0] == b[PTR_WIDTH-1:0]));
    end
endfunction

///////////////////////////////////////////////////////////////////////////////
// Authoritative committed list/cache state and one uncommitted work snapshot
///////////////////////////////////////////////////////////////////////////////
reg [LINK_WIDTH-1:0]                                    head_d;
reg [LINK_WIDTH-1:0]                                    tail_d;
reg                                                     cache_valid_d;
reg [PAYLOAD_WIDTH-1:0]                                 head_payload_d;
reg [LINK_WIDTH-1:0]                                    head_next_d;
reg [LINK_WIDTH-1:0]                                    bank0_head_d;
reg [LINK_WIDTH-1:0]                                    bank0_tail_d;
reg [LINK_WIDTH-1:0]                                    bank1_head_d;
reg [LINK_WIDTH-1:0]                                    bank1_tail_d;
reg [11:0]                                              bank0_min_d;
reg [11:0]                                              bank0_max_d;
reg [11:0]                                              bank1_min_d;
reg [11:0]                                              bank1_max_d;

reg                                                     active_d;
reg                                                     insert_d;
reg                                                     context_d;
reg [2:0]                                               phase_d;
reg [PAYLOAD_WIDTH-1:0]                                 payload_d;
reg [LINK_WIDTH-1:0]                                    old_head_d;
reg [LINK_WIDTH-1:0]                                    old_next_d;
reg [COUNT_WIDTH-1:0]                                   old_level_d;
reg [COUNT_WIDTH-1:0]                                   old_bank_count_d;
reg [PTR_WIDTH-1:0]                                     alloc_ptr_d;

wire                                                    live;
wire                                                    at_first;
wire                                                    at_prepare;
wire                                                    work_due;
wire                                                    op_bank;
wire [11:0]                                             op_tag;
wire [COUNT_WIDTH-1:0]                                  op_bank_count;
wire [LINK_WIDTH-1:0]                                   op_bank_tail;
wire [11:0]                                             op_bank_min;
wire [11:0]                                             op_bank_max;
wire [COUNT_WIDTH-1:0]                                  other_count;
wire [15:0]                                             other_epoch;
wire [LINK_WIDTH-1:0]                                   other_head;
wire [11:0]                                             other_min;
wire [LINK_WIDTH-1:0]                                   base_head;
wire [LINK_WIDTH-1:0]                                   base_tail;
wire [11:0]                                             base_min;
wire [LINK_WIDTH-1:0]                                   expected_tail;
wire                                                    insert_commit_intent;
wire                                                    extract_commit_intent;
wire                                                    insert_commit;
wire                                                    extract_commit;

assign live = rstn & init_done & ~halt;
assign at_first = active_d & (phase_d == 1);
assign at_prepare = active_d & insert_d & (phase_d == NEXT_READ_EDGE);
assign work_due = live & active_d & (insert_d ? (phase_d == INSERT_COMMIT_LATENCY) :
                                                            (phase_d == 1));
assign head_payload = head_payload_d;
assign operation_epoch = payload_d[PAYLOAD_WIDTH-1 -: 16];
assign release_ptr = old_head_d[PTR_WIDTH-1:0];
assign response_payload = payload_d;
assign op_bank = operation_epoch[0];
assign op_tag = payload_d[FLOW_ID_WIDTH +: 12];
assign op_bank_count = op_bank ? bank1_count : bank0_count;
assign op_bank_tail = op_bank ? bank1_tail_d : bank0_tail_d;
assign op_bank_min = op_bank ? bank1_min_d : bank0_min_d;
assign op_bank_max = op_bank ? bank1_max_d : bank0_max_d;
assign other_count = op_bank ? bank0_count : bank1_count;
assign other_epoch = op_bank ? bank0_epoch : bank1_epoch;
assign other_head = op_bank ? bank0_head_d : bank1_head_d;
assign other_min = op_bank ? bank0_min_d : bank1_min_d;
assign base_head = base_epoch[0] ? bank1_head_d : bank0_head_d;
assign base_tail = base_epoch[0] ? bank1_tail_d : bank0_tail_d;
assign base_min = base_epoch[0] ? bank1_min_d : bank0_min_d;
assign expected_tail = base_epoch[0] ?
    ((bank0_count != 0) ? bank0_tail_d : bank1_tail_d) :
    ((bank1_count != 0) ? bank1_tail_d : bank0_tail_d);
assign insert_commit_intent = commit_req & commit_insert;
assign extract_commit_intent = commit_req & ~commit_insert;
assign insert_commit = live & update_allow & insert_commit_intent;
assign extract_commit = live & update_allow & extract_commit_intent;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        active_d <= 1'b0;
        insert_d <= 1'b0;
        context_d <= 1'b0;
        phase_d <= 3'd0;
        payload_d <= {PAYLOAD_WIDTH{1'b0}};
        old_head_d <= NULL_LINK;
        old_next_d <= NULL_LINK;
        old_level_d <= {COUNT_WIDTH{1'b0}};
        old_bank_count_d <= {COUNT_WIDTH{1'b0}};
        alloc_ptr_d <= {PTR_WIDTH{1'b0}};
    end
    else if (init_guard) begin
        active_d <= 1'b0;
        phase_d <= 3'd0;
    end
    else if (live && update_allow) begin
        if (active_d) begin
            phase_d <= phase_d + 1'b1;
        end
        if (commit_req) begin
            active_d <= 1'b0;
        end
        if (insert_fire || extract_fire) begin
            active_d <= 1'b1;
            insert_d <= insert_fire;
            context_d <= request_context;
            phase_d <= 3'd1;
            payload_d <= insert_fire ? insert_payload : head_payload_d;
            old_head_d <= head_d;
            old_next_d <= head_next_d;
            old_level_d <= queue_level;
            old_bank_count_d <= insert_fire ?
                (insert_payload[PAYLOAD_WIDTH-16] ? bank1_count : bank0_count) :
                (head_payload_d[PAYLOAD_WIDTH-16] ? bank1_count : bank0_count);
        end
        if (at_first && insert_d) begin
            alloc_ptr_d <= alloc_ptr;
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// E3 body: {payload, n, p, old_head}. At E4 old_head becomes final successor.
// Register flags precompute bank changes; only successor-dependent work is late.
///////////////////////////////////////////////////////////////////////////////
reg                                                     body_valid_d;
reg                                                     body_context_d;
reg [DESC_WIDTH-1:0]                                    body_d;
reg                                                     body_empty_d;
reg                                                     body_min_d;
reg                                                     body_max_d;
wire [LINK_WIDTH-1:0]                                   selected_pred;
wire                                                    prepare_available;
wire [PAYLOAD_WIDTH-1:0]                                body_payload;
wire [PTR_WIDTH-1:0]                                    body_n;
wire [LINK_WIDTH-1:0]                                   body_p;
wire [LINK_WIDTH-1:0]                                   body_head;
wire [LINK_WIDTH-1:0]                                   successor;
wire                                                    successor_available;
wire                                                    body_bank;
wire [11:0]                                             body_tag;

assign prepare_available = live & at_prepare & pred_valid & (metadata_error_code == 0);
assign selected_pred = pred_found ? {1'b1,pred_ptr} :
    (((queue_level != 0) && (operation_epoch != base_epoch)) ? base_tail : NULL_LINK);
assign body_payload = body_d[DATA_LSB +: PAYLOAD_WIDTH];
assign body_n = body_d[N_LSB +: PTR_WIDTH];
assign body_p = body_d[P_LSB +: LINK_WIDTH];
assign body_head = body_d[0 +: LINK_WIDTH];
assign body_bank = body_payload[PAYLOAD_WIDTH-16];
assign body_tag = body_payload[FLOW_ID_WIDTH +: 12];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        body_valid_d <= 1'b0;
        body_context_d <= 1'b0;
        body_d <= {DESC_WIDTH{1'b0}};
        body_empty_d <= 1'b0;
        body_min_d <= 1'b0;
        body_max_d <= 1'b0;
    end
    else if (init_guard) begin
        body_valid_d <= 1'b0;
    end
    else if (live && update_allow) begin
        if (insert_fire || extract_fire) begin
            body_valid_d <= 1'b0;
        end
        if (prepare_available) begin
            body_valid_d <= 1'b1;
            body_context_d <= context_d;
            body_d <= {payload_d,alloc_ptr_d,selected_pred,old_head_d};
            body_empty_d <= (op_bank_count == 0);
            body_min_d <= (op_tag < op_bank_min);
            body_max_d <= (op_tag >= op_bank_max);
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// Two final descriptors: {payload, n, p, successor}; valid lasts through WB.
// patch_pending records physical work, independently of logical overlay valid.
///////////////////////////////////////////////////////////////////////////////
reg [DESC_WIDTH-1:0]                                    pending0_d;
reg [DESC_WIDTH-1:0]                                    pending1_d;
reg [1:0]                                               pending_valid_d;
reg [1:0]                                               pending_insert_d;
reg [1:0]                                               patch_pending_d;
wire [DESC_WIDTH-1:0]                                   patch_descriptor;
wire [PTR_WIDTH-1:0]                                    patch_n;
wire [LINK_WIDTH-1:0]                                   patch_p;
wire                                                    patch_write_intent;
wire [1:0]                                              commit_mask;
wire [1:0]                                              patch_mask;
wire [DESC_WIDTH-1:0]                                   final_descriptor;
wire [LINK_WIDTH-1:0]                                   pending0_p;
wire [LINK_WIDTH-1:0]                                   pending1_p;
wire [PTR_WIDTH-1:0]                                    pending0_n;
wire [PTR_WIDTH-1:0]                                    pending1_n;

assign patch_descriptor = patch_context ? pending1_d : pending0_d;
assign patch_n = patch_descriptor[N_LSB +: PTR_WIDTH];
assign patch_p = patch_descriptor[P_LSB +: LINK_WIDTH];
assign patch_write_intent = patch_req & pending_valid_d[patch_context] &
    pending_insert_d[patch_context] & patch_pending_d[patch_context] & patch_p[PTR_WIDTH];
assign commit_mask = commit_req ? (commit_context ? 2'b10 : 2'b01) : 2'b00;
assign patch_mask = patch_req ? (patch_context ? 2'b10 : 2'b01) : 2'b00;
assign final_descriptor = commit_insert ? {body_payload,body_n,body_p,successor} :
    {payload_d,old_head_d[PTR_WIDTH-1:0],NULL_LINK,old_next_d};
assign pending0_p = pending0_d[P_LSB +: LINK_WIDTH];
assign pending1_p = pending1_d[P_LSB +: LINK_WIDTH];
assign pending0_n = pending0_d[N_LSB +: PTR_WIDTH];
assign pending1_n = pending1_d[N_LSB +: PTR_WIDTH];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pending0_d <= {DESC_WIDTH{1'b0}};
        pending1_d <= {DESC_WIDTH{1'b0}};
        pending_valid_d <= 2'b00;
        pending_insert_d <= 2'b00;
        patch_pending_d <= 2'b00;
    end
    else if (init_guard) begin
        pending_valid_d <= 2'b00;
        pending_insert_d <= 2'b00;
        patch_pending_d <= 2'b00;
    end
    else if (live && update_allow) begin
        pending_valid_d <= (pending_valid_d & ~wb_due) | commit_mask;
        pending_insert_d <= (pending_insert_d & ~wb_due & ~commit_mask) |
            (commit_mask & {2{commit_insert}});
        patch_pending_d <= (patch_pending_d & ~wb_due & ~patch_mask) |
            (commit_mask & {2{commit_insert & body_p[PTR_WIDTH]}});
        if (commit_mask[0]) begin
            pending0_d <= final_descriptor;
        end
        if (commit_mask[1]) begin
            pending1_d <= final_descriptor;
        end
    end
end

///////////////////////////////////////////////////////////////////////////////
// Single-copy memories. NEXT forwarding is captured AT THE READ EDGE.
// Legal FAST5 has at most one pending predecessor write; both contexts exist
// to overlap old WB with a new accept/commit, not to replicate node storage.
///////////////////////////////////////////////////////////////////////////////
wire                                                    data_read_intent;
wire                                                    next_read_intent;
wire [PTR_WIDTH-1:0]                                    next_read_ptr;
wire [ADDR_WIDTH-1:0]                                   next_read_addr;
wire                                                    data_read_en;
wire                                                    next_read_en;
wire                                                    next_write_en;
wire [ADDR_WIDTH-1:0]                                   next_write_addr;
wire [LINK_WIDTH-1:0]                                   next_write_data;
wire                                                    data_read_valid;
wire                                                    next_read_valid;
wire [PAYLOAD_WIDTH-1:0]                                data_read_data;
wire [LINK_WIDTH-1:0]                                   next_read_data;
reg                                                     data_context_d;
reg                                                     next_context_d;
reg                                                     next_insert_d;
wire                                                    pending_match0;
wire                                                    pending_match1;
wire [LINK_WIDTH-1:0]                                   pending_forward_data;
wire                                                    new_n_match;
wire                                                    new_p_match;
wire [LINK_WIDTH-1:0]                                   commit_forward_data;

assign data_read_intent = extract_fire & head_next_d[PTR_WIDTH];
assign next_read_intent = data_read_intent |
    (prepare_available & selected_pred[PTR_WIDTH] &
    ptr_good(selected_pred[PTR_WIDTH-1:0]));
assign next_read_ptr = at_prepare ? selected_pred[PTR_WIDTH-1:0] :
                                head_next_d[PTR_WIDTH-1:0];
assign next_read_addr = next_read_ptr[ADDR_WIDTH-1:0];
assign data_read_en = live & update_allow & data_read_intent &
    ptr_good(head_next_d[PTR_WIDTH-1:0]);
assign next_read_en = live & update_allow & next_read_intent & ptr_good(next_read_ptr);
assign next_write_en = live & update_allow & (insert_commit_intent | patch_write_intent);
assign next_write_addr = insert_commit_intent ? body_n[ADDR_WIDTH-1:0] :
                                                        patch_p[ADDR_WIDTH-1:0];
assign next_write_data = insert_commit_intent ? successor : {1'b1,patch_n};
assign successor = body_p[PTR_WIDTH] ? next_read_data : body_head;
assign successor_available = body_valid_d &
    (~body_p[PTR_WIDTH] | (next_read_valid & next_insert_d & (next_context_d == body_context_d)));
assign pending_match0 = pending_valid_d[0] & pending_insert_d[0] & pending0_p[PTR_WIDTH] &
    (pending0_p[PTR_WIDTH-1:0] == next_read_ptr);
assign pending_match1 = pending_valid_d[1] & pending_insert_d[1] & pending1_p[PTR_WIDTH] &
    (pending1_p[PTR_WIDTH-1:0] == next_read_ptr);
assign pending_forward_data = pending_match1 ? {1'b1,pending1_n} : {1'b1,pending0_n};
assign new_n_match = (body_n == next_read_ptr);
assign new_p_match = body_p[PTR_WIDTH] & (body_p[PTR_WIDTH-1:0] == next_read_ptr);
assign commit_forward_data = new_n_match ? successor : {1'b1,body_n};

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        data_context_d <= 1'b0;
        next_context_d <= 1'b0;
        next_insert_d <= 1'b0;
    end
    else begin
        if (data_read_en) begin
            data_context_d <= request_context;
        end
        if (next_read_en) begin
            next_context_d <= at_prepare ? context_d : request_context;
            next_insert_d <= at_prepare;
        end
    end
end

wfq_sync_ram_1r1w #(
    .DATA_WIDTH                                         (PAYLOAD_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_data (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (data_read_en),
    .read_addr                                          (head_next_d[ADDR_WIDTH-1:0]),
    .write_en                                           (insert_commit),
    .write_addr                                         (body_n[ADDR_WIDTH-1:0]),
    .write_data                                         (body_payload),
    .commit_valid                                       (insert_commit),
    .commit_addr                                        (body_n[ADDR_WIDTH-1:0]),
    .commit_data                                        (body_payload),
    .pending_valid                                      (1'b0),
    .pending_addr                                       ({ADDR_WIDTH{1'b0}}),
    .pending_data                                       ({PAYLOAD_WIDTH{1'b0}}),
    .read_valid                                         (data_read_valid),
    .read_data                                          (data_read_data)
);

wfq_sync_ram_1r1w #(
    .DATA_WIDTH                                         (LINK_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_next (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (next_read_en),
    .read_addr                                          (next_read_addr),
    .write_en                                           (next_write_en),
    .write_addr                                         (next_write_addr),
    .write_data                                         (next_write_data),
    .commit_valid                                       (insert_commit & (new_n_match | new_p_match)),
    .commit_addr                                        (next_read_addr),
    .commit_data                                        (commit_forward_data),
    .pending_valid                                      (pending_match0 | pending_match1),
    .pending_addr                                       (next_read_addr),
    .pending_data                                       (pending_forward_data),
    .read_valid                                         (next_read_valid),
    .read_data                                          (next_read_data)
);

///////////////////////////////////////////////////////////////////////////////
// Pre-edge consistency checks; invalid RAM returns are only schedule evidence
///////////////////////////////////////////////////////////////////////////////
wire                                                    boundary_bad;
wire                                                    cache_bad;
wire                                                    insertion_bad;
wire                                                    extraction_bad;
wire                                                    metadata_bad;
wire                                                    epoch_bad;
wire                                                    schedule_bad;
wire                                                    pointer_bad;
wire                                                    extract_return_ok;
wire [15:0]                                             next_epoch;
wire [11:0]                                             next_tag;
wire [15:0]                                             expected_next_epoch;

assign extract_return_ok = data_read_valid & next_read_valid & ~next_insert_d &
    (data_context_d == context_d) & (next_context_d == context_d);
assign next_epoch = data_read_data[PAYLOAD_WIDTH-1 -: 16];
assign next_tag = data_read_data[FLOW_ID_WIDTH +: 12];
assign expected_next_epoch = (old_bank_count_d > 1) ? operation_epoch : other_epoch;
assign boundary_bad =
    ((bank0_count == 0) ? (bank0_head_d[PTR_WIDTH] | bank0_tail_d[PTR_WIDTH]) :
        (~bank0_head_d[PTR_WIDTH] | ~bank0_tail_d[PTR_WIDTH] |
        (bank0_min_d > bank0_max_d) |
        ((bank0_count == 1) != (bank0_head_d[PTR_WIDTH-1:0] == bank0_tail_d[PTR_WIDTH-1:0])) |
        ((bank0_count == 1) & (bank0_min_d != bank0_max_d)))) |
    ((bank1_count == 0) ? (bank1_head_d[PTR_WIDTH] | bank1_tail_d[PTR_WIDTH]) :
        (~bank1_head_d[PTR_WIDTH] | ~bank1_tail_d[PTR_WIDTH] |
        (bank1_min_d > bank1_max_d) |
        ((bank1_count == 1) != (bank1_head_d[PTR_WIDTH-1:0] == bank1_tail_d[PTR_WIDTH-1:0])) |
        ((bank1_count == 1) & (bank1_min_d != bank1_max_d))));
assign cache_bad = (queue_level == 0) ?
    (head_d[PTR_WIDTH] | tail_d[PTR_WIDTH] | cache_valid_d | head_next_d[PTR_WIDTH]) :
    (~head_d[PTR_WIDTH] | ~tail_d[PTR_WIDTH] | ~cache_valid_d |
    (head_d != base_head) | (tail_d != expected_tail) |
    (head_payload_d[FLOW_ID_WIDTH +: 12] != base_min) |
    ((queue_level == 1) != (head_d[PTR_WIDTH-1:0] == tail_d[PTR_WIDTH-1:0])) |
    (head_next_d[PTR_WIDTH] != (queue_level > 1)) |
    (head_next_d[PTR_WIDTH] & (head_next_d[PTR_WIDTH-1:0] == head_d[PTR_WIDTH-1:0])));
assign metadata_bad = prepare_available &
    ((pred_found != ((op_bank_count != 0) & (op_tag >= op_bank_min))) |
    (pred_found & (pred_tag > op_tag)));
assign insertion_bad =
    (prepare_available & ((selected_pred[PTR_WIDTH] &
        (selected_pred[PTR_WIDTH-1:0] == alloc_ptr_d)) |
        (head_d[PTR_WIDTH] & (head_d[PTR_WIDTH-1:0] == alloc_ptr_d)))) |
    (insert_commit_intent & successor_available &
        ((body_p[PTR_WIDTH] &
        (successor[PTR_WIDTH] == (body_p == tail_d))) |
        (successor[PTR_WIDTH] & ((successor[PTR_WIDTH-1:0] == body_n) |
        (body_p[PTR_WIDTH] & (successor[PTR_WIDTH-1:0] == body_p[PTR_WIDTH-1:0])))) |
        (body_p[PTR_WIDTH] & (body_p == head_d) & !link_equal(successor,head_next_d))));
assign extraction_bad = extract_commit_intent &
    ((old_level_d == 0) | ~old_head_d[PTR_WIDTH] |
    (old_next_d[PTR_WIDTH] != (old_level_d > 1)) |
    ((old_bank_count_d == 1) & (old_level_d > 1) & (old_next_d != other_head)) |
    (old_next_d[PTR_WIDTH] & extract_return_ok &
        ((next_read_data[PTR_WIDTH] != (old_level_d > 2)) |
        ((old_level_d == 2) != (old_next_d == tail_d)) |
        (next_read_data[PTR_WIDTH] &
        ((next_read_data[PTR_WIDTH-1:0] == old_next_d[PTR_WIDTH-1:0]) |
        (next_read_data[PTR_WIDTH-1:0] == old_head_d[PTR_WIDTH-1:0]))) |
        ((old_bank_count_d > 1) &
        ((next_tag < op_tag) | (next_tag > op_bank_max) |
        ((old_bank_count_d == 2) != (old_next_d == op_bank_tail)) |
        ((old_bank_count_d == 2) & (next_tag != op_bank_max)))) |
        ((old_bank_count_d == 1) & (next_tag != other_min)))));
assign epoch_bad = ((queue_level != 0) &
    (head_payload_d[PAYLOAD_WIDTH-1 -: 16] != base_epoch)) |
    (extract_commit_intent & old_next_d[PTR_WIDTH] & extract_return_ok &
    ((next_epoch != expected_next_epoch) |
    ((old_bank_count_d == 1) & (other_count == 0))));
assign schedule_bad =
    (commit_req != work_due) |
    ((metadata_error_code == 0) & (metadata_commit_due != commit_req)) |
    (commit_req & ((commit_context != context_d) | (commit_insert != insert_d) |
        ((metadata_error_code == 0) & (metadata_commit_context != context_d)))) |
    (at_first & insert_d & (~alloc_valid | (alloc_context != context_d))) |
    (at_prepare & (metadata_error_code == 0) &
        (~pred_valid | (pred_context != context_d) | (pred_bank != op_bank))) |
    (insert_commit_intent & (~body_valid_d | (body_context_d != context_d) |
        (next_read_valid != body_p[PTR_WIDTH]) |
        (body_p[PTR_WIDTH] & (~next_insert_d | (next_context_d != context_d))))) |
    (extract_commit_intent &
        ((data_read_valid != old_next_d[PTR_WIDTH]) |
        (next_read_valid != old_next_d[PTR_WIDTH]) |
        (old_next_d[PTR_WIDTH] & ~extract_return_ok))) |
    (patch_req & (~pending_valid_d[patch_context] | ~pending_insert_d[patch_context] |
        (patch_pending_d[patch_context] != patch_p[PTR_WIDTH]))) |
    (|(wb_due & ~pending_valid_d)) |
    (|(commit_mask & pending_valid_d & ~wb_due)) |
    (insert_commit_intent & patch_write_intent) |
    (pending_match0 & pending_match1);
assign pointer_bad =
    (head_d[PTR_WIDTH] & ~ptr_good(head_d[PTR_WIDTH-1:0])) |
    (tail_d[PTR_WIDTH] & ~ptr_good(tail_d[PTR_WIDTH-1:0])) |
    (head_next_d[PTR_WIDTH] & ~ptr_good(head_next_d[PTR_WIDTH-1:0])) |
    (bank0_head_d[PTR_WIDTH] & ~ptr_good(bank0_head_d[PTR_WIDTH-1:0])) |
    (bank0_tail_d[PTR_WIDTH] & ~ptr_good(bank0_tail_d[PTR_WIDTH-1:0])) |
    (bank1_head_d[PTR_WIDTH] & ~ptr_good(bank1_head_d[PTR_WIDTH-1:0])) |
    (bank1_tail_d[PTR_WIDTH] & ~ptr_good(bank1_tail_d[PTR_WIDTH-1:0])) |
    (at_first & insert_d & alloc_valid & ~ptr_good(alloc_ptr)) |
    (prepare_available & selected_pred[PTR_WIDTH] & ~ptr_good(selected_pred[PTR_WIDTH-1:0])) |
    (insert_commit_intent & body_valid_d &
        (~ptr_good(body_n) | (body_p[PTR_WIDTH] & ~ptr_good(body_p[PTR_WIDTH-1:0])) |
        (successor_available & successor[PTR_WIDTH] & ~ptr_good(successor[PTR_WIDTH-1:0])))) |
    (extract_commit_intent & old_next_d[PTR_WIDTH] & extract_return_ok &
        next_read_data[PTR_WIDTH] & ~ptr_good(next_read_data[PTR_WIDTH-1:0])) |
    (patch_req & patch_p[PTR_WIDTH] &
        (~ptr_good(patch_p[PTR_WIDTH-1:0]) | ~ptr_good(patch_n)));
assign error_code = !live ? `WFQ_FAULT_NONE :
    (metadata_bad ? `WFQ_FAULT_METADATA :
    ((boundary_bad | cache_bad | insertion_bad | extraction_bad) ? `WFQ_FAULT_LINK :
    (epoch_bad ? `WFQ_FAULT_EPOCH :
    (schedule_bad ? `WFQ_FAULT_SCHEDULE :
    (pointer_bad ? `WFQ_FAULT_POINTER : `WFQ_FAULT_NONE)))));

///////////////////////////////////////////////////////////////////////////////
// Atomic committed list/cache updates, alongside metadata and resource writes
///////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        head_d <= NULL_LINK;
        tail_d <= NULL_LINK;
        cache_valid_d <= 1'b0;
        head_payload_d <= {PAYLOAD_WIDTH{1'b0}};
        head_next_d <= NULL_LINK;
        bank0_head_d <= NULL_LINK;
        bank0_tail_d <= NULL_LINK;
        bank1_head_d <= NULL_LINK;
        bank1_tail_d <= NULL_LINK;
        bank0_min_d <= 12'd0;
        bank0_max_d <= 12'd0;
        bank1_min_d <= 12'd0;
        bank1_max_d <= 12'd0;
    end
    else if (init_guard) begin
        head_d <= NULL_LINK;
        tail_d <= NULL_LINK;
        cache_valid_d <= 1'b0;
        head_payload_d <= {PAYLOAD_WIDTH{1'b0}};
        head_next_d <= NULL_LINK;
        bank0_head_d <= NULL_LINK;
        bank0_tail_d <= NULL_LINK;
        bank1_head_d <= NULL_LINK;
        bank1_tail_d <= NULL_LINK;
        bank0_min_d <= 12'd0;
        bank0_max_d <= 12'd0;
        bank1_min_d <= 12'd0;
        bank1_max_d <= 12'd0;
    end
    else if (insert_commit) begin
        if (!body_p[PTR_WIDTH]) begin
            head_d <= {1'b1,body_n};
            cache_valid_d <= 1'b1;
            head_payload_d <= body_payload;
            head_next_d <= successor;
        end
        else if (body_p == head_d) begin
            head_next_d <= {1'b1,body_n};
        end
        if (!successor[PTR_WIDTH]) begin
            tail_d <= {1'b1,body_n};
        end
        if (body_bank) begin
            if (body_empty_d || body_min_d) begin
                bank1_head_d <= {1'b1,body_n};
                bank1_min_d <= body_tag;
            end
            if (body_empty_d || body_max_d) begin
                bank1_tail_d <= {1'b1,body_n};
                bank1_max_d <= body_tag;
            end
        end
        else begin
            if (body_empty_d || body_min_d) begin
                bank0_head_d <= {1'b1,body_n};
                bank0_min_d <= body_tag;
            end
            if (body_empty_d || body_max_d) begin
                bank0_tail_d <= {1'b1,body_n};
                bank0_max_d <= body_tag;
            end
        end
    end
    else if (extract_commit) begin
        if (old_level_d == 1) begin
            head_d <= NULL_LINK;
            tail_d <= NULL_LINK;
            cache_valid_d <= 1'b0;
            head_payload_d <= {PAYLOAD_WIDTH{1'b0}};
            head_next_d <= NULL_LINK;
        end
        else begin
            head_d <= old_next_d;
            head_payload_d <= data_read_data;
            head_next_d <= next_read_data;
            cache_valid_d <= 1'b1;
        end
        if (op_bank) begin
            if (old_bank_count_d == 1) begin
                bank1_head_d <= NULL_LINK;
                bank1_tail_d <= NULL_LINK;
                bank1_min_d <= 12'd0;
                bank1_max_d <= 12'd0;
            end
            else begin
                bank1_head_d <= old_next_d;
                bank1_min_d <= next_tag;
            end
        end
        else begin
            if (old_bank_count_d == 1) begin
                bank0_head_d <= NULL_LINK;
                bank0_tail_d <= NULL_LINK;
                bank0_min_d <= 12'd0;
                bank0_max_d <= 12'd0;
            end
            else begin
                bank0_head_d <= old_next_d;
                bank0_min_d <= next_tag;
            end
        end
    end
end

endmodule

`default_nettype wire
