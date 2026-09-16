// Project : wfq_tag_sort_engine
// File    : wfq_free_slot_stack.v
// Spec    : Design_Spec_V1.2.md, sections 2.4, 6.5, 12 and 13
// Function: Single-copy FREE RAM, allocation reservation and capacity counts.
// Timing  : Reserve reads FREE[old free_count-1] at E0; alloc_* is valid before
//           E1. Extract commit writes FREE[old free_count] on the same edge.
// Contract: Proposed events are checked before update_allow gates all changes.
//           alloc_valid denotes a returned word, not its pointer legality.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_free_slot_stack #(
    parameter integer PTR_WIDTH = 10,
    parameter integer MEM_DEPTH = 1024
) (
    clk,
    rstn,
    init_done,
    init_guard,
    init_write_en,
    init_write_addr,
    init_write_data,
    halt,
    update_allow,
    reserve_req,
    reserve_context,
    insert_commit_req,
    extract_commit_req,
    release_ptr,
    alloc_valid,
    alloc_context,
    alloc_ptr,
    free_count,
    alloc_reserved,
    queue_level,
    error_code
);

`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam integer RANGE_WIDTH = ((PTR_WIDTH > COUNT_WIDTH) ? PTR_WIDTH : COUNT_WIDTH) + 1;
localparam [COUNT_WIDTH-1:0] CAPACITY = MEM_DEPTH;
localparam [RANGE_WIDTH-1:0] PTR_LIMIT = MEM_DEPTH;


// Clock and shared initialization
input  wire                                             clk;
input  wire                                             rstn;
input  wire                                             init_done;
input  wire                                             init_guard;

// Connect the shared init controller FREE write outputs
input  wire                                             init_write_en;
input  wire [ADDR_WIDTH-1:0]                            init_write_addr;
input  wire [PTR_WIDTH-1:0]                             init_write_data;

// Normal operation proposals, checked before update_allow
input  wire                                             halt;
input  wire                                             update_allow;
input  wire                                             reserve_req;
input  wire                                             reserve_context;
input  wire                                             insert_commit_req;
input  wire                                             extract_commit_req;
input  wire [PTR_WIDTH-1:0]                             release_ptr;

// E1 return and allocation owner; data legality is reported separately
output wire                                             alloc_valid;
output wire                                             alloc_context;
output wire [PTR_WIDTH-1:0]                             alloc_ptr;

// Authoritative shared node-capacity counters
output wire [COUNT_WIDTH-1:0]                           free_count;
output wire [COUNT_WIDTH-1:0]                           alloc_reserved;
output wire [COUNT_WIDTH-1:0]                           queue_level;
output reg [3:0]                                        error_code;

reg [COUNT_WIDTH-1:0]                                   free_count_d;
reg [COUNT_WIDTH-1:0]                                   reserved_d;
reg [COUNT_WIDTH-1:0]                                   level_d;
reg                                                     read_expected_d1;
reg                                                     context_d;
wire                                                    live;
wire                                                    reserve_fire;
wire                                                    insert_commit;
wire                                                    extract_commit;
wire [COUNT_WIDTH+1:0]                                  capacity_sum;
wire [COUNT_WIDTH-1:0]                                  top_index;
wire [RANGE_WIDTH-1:0]                                  wide_alloc;
wire [RANGE_WIDTH-1:0]                                  wide_release;
wire                                                    ram_read_valid;
wire [PTR_WIDTH-1:0]                                    ram_read_data;
wire                                                    ram_write_en;
wire [ADDR_WIDTH-1:0]                                   ram_write_addr;
wire [PTR_WIDTH-1:0]                                    ram_write_data;

generate
    if ((MEM_DEPTH < 16) || (MEM_DEPTH > 65536) ||
        ((MEM_DEPTH & (MEM_DEPTH - 1)) != 0) ||
        (PTR_WIDTH < 4) || (PTR_WIDTH > 16) ||
        (PTR_WIDTH < ADDR_WIDTH)) begin : g_bad_parameters
        wfq_error_invalid_node_capacity_or_pointer_width u_error ();
    end
endgenerate

assign live = rstn & init_done & ~halt;
assign free_count = free_count_d;
assign alloc_reserved = reserved_d;
assign queue_level = level_d;
assign capacity_sum = {2'b00, free_count_d} + {2'b00, reserved_d} + {2'b00, level_d};
assign top_index = free_count_d - 1'b1;
assign wide_alloc = {{(RANGE_WIDTH-PTR_WIDTH){1'b0}}, ram_read_data};
assign wide_release = {{(RANGE_WIDTH-PTR_WIDTH){1'b0}}, release_ptr};
assign alloc_valid = live & read_expected_d1 & ram_read_valid;
assign alloc_context = context_d;
assign alloc_ptr = ram_read_data;

always @(*) begin
    error_code = `WFQ_FAULT_NONE;
    if (live) begin
        if ((free_count_d > CAPACITY) || (reserved_d > CAPACITY) ||
            (level_d > CAPACITY) || (capacity_sum != MEM_DEPTH) ||
            (reserve_req && (free_count_d == 0)) ||
            (insert_commit_req && ((reserved_d == 0) || (level_d >= CAPACITY))) ||
            (extract_commit_req && ((level_d == 0) || (free_count_d >= CAPACITY)))) begin
            error_code = `WFQ_FAULT_CAPACITY;
        end
        else if ((insert_commit_req && extract_commit_req) ||
                (read_expected_d1 && !ram_read_valid) || init_write_en) begin
            error_code = `WFQ_FAULT_SCHEDULE;
        end
        else if ((read_expected_d1 && ram_read_valid && (wide_alloc >= PTR_LIMIT)) ||
                (extract_commit_req && (wide_release >= PTR_LIMIT))) begin
            error_code = `WFQ_FAULT_POINTER;
        end
    end
end

assign reserve_fire = live & update_allow & (error_code == 0) & reserve_req;
assign insert_commit = live & update_allow & (error_code == 0) & insert_commit_req;
assign extract_commit = live & update_allow & (error_code == 0) & extract_commit_req;
// Index conversion occurs only after full-width count checks gate the access.
assign ram_write_en = (rstn & ~init_done & init_write_en) | extract_commit;
assign ram_write_addr = init_done ? free_count_d[ADDR_WIDTH-1:0] : init_write_addr;
assign ram_write_data = init_done ? release_ptr : init_write_data;

wfq_sync_ram_1r1w #(
    .DATA_WIDTH                                         (PTR_WIDTH),
    .MEM_DEPTH                                          (MEM_DEPTH)
) u_ram (
    .clk                                                (clk),
    .rstn                                               (rstn),
    .read_en                                            (reserve_fire),
    .read_addr                                          (top_index[ADDR_WIDTH-1:0]),
    .write_en                                           (ram_write_en),
    .write_addr                                         (ram_write_addr),
    .write_data                                         (ram_write_data),
    .commit_valid                                       (1'b0),
    .commit_addr                                        ({ADDR_WIDTH{1'b0}}),
    .commit_data                                        ({PTR_WIDTH{1'b0}}),
    .pending_valid                                      (1'b0),
    .pending_addr                                       ({ADDR_WIDTH{1'b0}}),
    .pending_data                                       ({PTR_WIDTH{1'b0}}),
    .read_valid                                         (ram_read_valid),
    .read_data                                          (ram_read_data)
);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        free_count_d <= {COUNT_WIDTH{1'b0}};
        reserved_d <= {COUNT_WIDTH{1'b0}};
        level_d <= {COUNT_WIDTH{1'b0}};
        read_expected_d1 <= 1'b0;
        context_d <= 1'b0;
    end
    else if (init_guard) begin
        free_count_d <= CAPACITY;
        reserved_d <= {COUNT_WIDTH{1'b0}};
        level_d <= {COUNT_WIDTH{1'b0}};
        read_expected_d1 <= 1'b0;
        context_d <= 1'b0;
    end
    else begin
        read_expected_d1 <= reserve_fire;
        if (reserve_fire) begin
            context_d <= reserve_context;
        end
        if (live && update_allow && (error_code == 0)) begin
            case ({extract_commit, reserve_fire})
                2'b10: free_count_d <= free_count_d + 1'b1;
                2'b01: free_count_d <= free_count_d - 1'b1;
                default: free_count_d <= free_count_d;
            endcase
            case ({reserve_fire, insert_commit})
                2'b10: reserved_d <= reserved_d + 1'b1;
                2'b01: reserved_d <= reserved_d - 1'b1;
                default: reserved_d <= reserved_d;
            endcase
            case ({insert_commit, extract_commit})
                2'b10: level_d <= level_d + 1'b1;
                2'b01: level_d <= level_d - 1'b1;
                default: level_d <= level_d;
            endcase
        end
    end
end

endmodule

`default_nettype wire
