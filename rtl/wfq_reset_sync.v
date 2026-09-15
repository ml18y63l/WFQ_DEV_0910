// Project : wfq_tag_sort_engine
// File    : wfq_reset_sync.v
// Spec    : Design_Spec_V1.2.md, section 12.1; RTL_Coding_Style.md, section 7
// Function: One shared asynchronous-assert, two-edge synchronous-release reset.

`timescale 1ns/1ps
`default_nettype none

module wfq_reset_sync (
    input  wire                                         clk,
    input  wire                                         rstn,
    output wire                                         core_rstn
);

// Preserve and place these two stages as a reset synchronizer during mapping.
reg                                                     rstn_sync_d1;
reg                                                     rstn_sync_d2;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        rstn_sync_d1 <= 1'b0;
        rstn_sync_d2 <= 1'b0;
    end
    else begin
        rstn_sync_d1 <= 1'b1;
        rstn_sync_d2 <= rstn_sync_d1;
    end
end

assign core_rstn = rstn_sync_d2;

endmodule

`default_nettype wire
