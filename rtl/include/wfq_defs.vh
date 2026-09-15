// Project : wfq_tag_sort_engine
// File    : wfq_defs.vh
// Spec    : Design_Spec_V1.2.md, sections 7.2 and 13.2
// Function: Shared fixed encodings; no mutable state or width overrides.

`ifndef WFQ_DEFS_VH
`define WFQ_DEFS_VH

`define WFQ_MATCH_LE       2'd0
`define WFQ_MATCH_LT       2'd1
`define WFQ_MATCH_MAX      2'd2

`define WFQ_FAULT_NONE     4'd0
`define WFQ_FAULT_RC       4'd1
`define WFQ_FAULT_METADATA 4'd2
`define WFQ_FAULT_LINK     4'd3
`define WFQ_FAULT_EPOCH    4'd4
`define WFQ_FAULT_CAPACITY 4'd5
`define WFQ_FAULT_SCHEDULE 4'd6
`define WFQ_FAULT_POINTER  4'd7

`endif
