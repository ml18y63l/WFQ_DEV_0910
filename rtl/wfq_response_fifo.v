// Project : wfq_tag_sort_engine
// File    : wfq_response_fifo.v
// Spec    : Design_Spec_V1.2.md, sections 4.3, 12 and 13.3
// Function: Two register entries with separately reserved response credits.
// Contract: Pre-edge credit never borrows the current pop. Existing responses
//           can drain when update_allow=0, including after a global fault.

`timescale 1ns/1ps
`default_nettype none
`include "wfq_defs.vh"

module wfq_response_fifo #(
    parameter integer FLOW_ID_WIDTH = 9
) (

    // Clock and initialization; update_allow gates only reserve/production
    input  wire                                         clk,
    input  wire                                         rstn,
    input  wire                                         init_done,
    input  wire                                         init_guard,
    input  wire                                         update_allow,

    // Ungated requests and complete payload for the two-entry FIFO
    input  wire                                         reserve_req,
    input  wire                                         enqueue_req,
    input  wire [28+FLOW_ID_WIDTH-1:0]                  enqueue_payload,

    // Consumer remains active when production is stopped
    input  wire                                         out_ready,
    output wire                                         out_valid,
    output wire [28+FLOW_ID_WIDTH-1:0]                  out_payload,

    // Credit is based exclusively on pre-edge occupancy/reservations
    output wire                                         credit_available,
    output wire [1:0]                                   rsp_count,
    output wire [1:0]                                   rsp_reserved,
    output reg [3:0]                                    error_code
);

localparam integer PAYLOAD_WIDTH = 28 + FLOW_ID_WIDTH;
reg [PAYLOAD_WIDTH-1:0]                                 payload0_d;
reg [PAYLOAD_WIDTH-1:0]                                 payload1_d;
reg                                                     head_d;
reg                                                     tail_d;
reg [1:0]                                               count_d;
reg [1:0]                                               reserved_d;
wire [2:0]                                              used_credit;
wire                                                    push;
wire                                                    pop;
wire                                                    reserve;

generate
    if ((FLOW_ID_WIDTH < 8) || (FLOW_ID_WIDTH > 12)) begin : g_bad_flow_width
        wfq_error_flow_id_width_must_be_8_to_12 u_error ();
    end
endgenerate

assign used_credit = {1'b0, count_d} + {1'b0, reserved_d};
assign credit_available = rstn & init_done & (used_credit < 3'd2);
assign rsp_count = count_d;
assign rsp_reserved = reserved_d;
assign out_valid = rstn & init_done & (count_d != 0) & (count_d <= 2);
assign out_payload = head_d ? payload1_d : payload0_d;
assign pop = out_valid & out_ready;
assign push = rstn & init_done & update_allow & (error_code == 0) & enqueue_req;
assign reserve = rstn & init_done & update_allow & (error_code == 0) & reserve_req;

always @(*) begin
    error_code = `WFQ_FAULT_NONE;
    if (rstn && init_done) begin
        if ((used_credit > 3'd2) ||
            (reserve_req && (used_credit >= 3'd2)) ||
            (enqueue_req && ((reserved_d == 0) || (count_d >= 2)))) begin
            error_code = `WFQ_FAULT_CAPACITY;
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        payload0_d <= {PAYLOAD_WIDTH{1'b0}};
        payload1_d <= {PAYLOAD_WIDTH{1'b0}};
        head_d <= 1'b0;
        tail_d <= 1'b0;
        count_d <= 2'd0;
        reserved_d <= 2'd0;
    end
    else if (init_guard) begin
        payload0_d <= {PAYLOAD_WIDTH{1'b0}};
        payload1_d <= {PAYLOAD_WIDTH{1'b0}};
        head_d <= 1'b0;
        tail_d <= 1'b0;
        count_d <= 2'd0;
        reserved_d <= 2'd0;
    end
    else if (init_done) begin
        case ({push, pop})
            2'b10: count_d <= count_d + 1'b1;
            2'b01: count_d <= count_d - 1'b1;
            default: count_d <= count_d;
        endcase
        case ({reserve, push})
            2'b10: reserved_d <= reserved_d + 1'b1;
            2'b01: reserved_d <= reserved_d - 1'b1;
            default: reserved_d <= reserved_d;
        endcase
        if (push) begin
            if (tail_d) begin
                payload1_d <= enqueue_payload;
            end
            else begin
                payload0_d <= enqueue_payload;
            end
            tail_d <= ~tail_d;
        end
        if (pop) begin
            head_d <= ~head_d;
        end
    end
end

endmodule

`default_nettype wire
