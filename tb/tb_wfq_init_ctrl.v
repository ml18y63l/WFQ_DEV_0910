// Controller plus real storage instances: scan timing and complete readback.
`timescale 1ns/1ps
module tb_wfq_init_ctrl;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH + 1);
localparam integer INIT_WRITES = (MEM_DEPTH > 8192) ? MEM_DEPTH : 8192;

reg clk, rstn;
wire init_done, init_guard;
wire meta_write_en, l1_write_en, l2_write_en, l3_write_en, free_write_en;
wire [12:0] meta_write_addr;
wire l1_write_addr;
wire [4:0] l2_write_addr;
wire [8:0] l3_write_addr;
wire [ADDR_WIDTH-1:0] free_write_addr;
wire [PTR_WIDTH-1:0] free_write_data;
wire [31:0] l1_flat;
wire [511:0] l2_flat;
wire [15:0] unused_l1, unused_l2;
reg meta_read_en, leaf_read_en, free_read_en;
reg [12:0] meta_read_addr;
reg [8:0] leaf_read_addr;
reg [ADDR_WIDTH-1:0] free_read_addr;
wire tt_valid, rc_valid, leaf_valid, free_valid, leaf_conflict;
wire [PTR_WIDTH:0] tt_data;
wire [COUNT_WIDTH-1:0] rc_data;
wire [15:0] leaf_data;
wire [PTR_WIDTH-1:0] free_data;
integer i, meta_writes, leaf_writes, root_writes, parent_writes, free_writes;

wfq_init_ctrl #(.PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH)) u_dut (
    .clk(clk), .rstn(rstn), .init_done(init_done), .init_guard(init_guard),
    .meta_write_en(meta_write_en), .meta_write_addr(meta_write_addr),
    .l1_write_en(l1_write_en), .l1_write_addr(l1_write_addr),
    .l2_write_en(l2_write_en), .l2_write_addr(l2_write_addr),
    .l3_write_en(l3_write_en), .l3_write_addr(l3_write_addr),
    .free_write_en(free_write_en), .free_write_addr(free_write_addr),
    .free_write_data(free_write_data)
);
wfq_trie_upper_regs u_upper (
    .clk(clk), .rstn(rstn), .l1_write_en(l1_write_en), .l1_write_addr(l1_write_addr),
    .l1_write_data(16'h0000), .l2_write_en(l2_write_en), .l2_write_addr(l2_write_addr),
    .l2_write_data(16'h0000), .read_bank(1'b0), .read_a(4'd0),
    .l1_read_data(unused_l1), .l2_read_data(unused_l2), .l1_flat(l1_flat), .l2_flat(l2_flat)
);
wfq_sync_ram_1rw u_leaf (
    .clk(clk), .rstn(rstn), .read_en(leaf_read_en), .write_en(l3_write_en),
    .addr(init_done ? leaf_read_addr : l3_write_addr), .write_data(16'h0000),
    .read_valid(leaf_valid), .read_data(leaf_data), .access_conflict(leaf_conflict)
);
wfq_sync_ram_1r1w #(.DATA_WIDTH(PTR_WIDTH+1), .MEM_DEPTH(8192)) u_tt (
    .clk(clk), .rstn(rstn), .read_en(meta_read_en), .read_addr(meta_read_addr),
    .write_en(meta_write_en), .write_addr(meta_write_addr), .write_data({(PTR_WIDTH+1){1'b0}}),
    .commit_valid(1'b0), .commit_addr(13'd0), .commit_data({(PTR_WIDTH+1){1'b0}}),
    .pending_valid(1'b0), .pending_addr(13'd0), .pending_data({(PTR_WIDTH+1){1'b0}}),
    .read_valid(tt_valid), .read_data(tt_data)
);
wfq_sync_ram_1r1w #(.DATA_WIDTH(COUNT_WIDTH), .MEM_DEPTH(8192)) u_rc (
    .clk(clk), .rstn(rstn), .read_en(meta_read_en), .read_addr(meta_read_addr),
    .write_en(meta_write_en), .write_addr(meta_write_addr), .write_data({COUNT_WIDTH{1'b0}}),
    .commit_valid(1'b0), .commit_addr(13'd0), .commit_data({COUNT_WIDTH{1'b0}}),
    .pending_valid(1'b0), .pending_addr(13'd0), .pending_data({COUNT_WIDTH{1'b0}}),
    .read_valid(rc_valid), .read_data(rc_data)
);
wfq_sync_ram_1r1w #(.DATA_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH)) u_free (
    .clk(clk), .rstn(rstn), .read_en(free_read_en), .read_addr(free_read_addr),
    .write_en(free_write_en), .write_addr(free_write_addr), .write_data(free_write_data),
    .commit_valid(1'b0), .commit_addr({ADDR_WIDTH{1'b0}}), .commit_data({PTR_WIDTH{1'b0}}),
    .pending_valid(1'b0), .pending_addr({ADDR_WIDTH{1'b0}}), .pending_data({PTR_WIDTH{1'b0}}),
    .read_valid(free_valid), .read_data(free_data)
);

task tick;
    begin
        #4; clk = 1; #1;
        #4; clk = 0;
    end
endtask

task reset_test;
    begin
        rstn = 0;
        #1;
        if ({init_done, init_guard, meta_write_en, l1_write_en,
             l2_write_en, l3_write_en, free_write_en} !== 7'b0000000) begin
            $display("FAIL init reset suppresses all controls");
            $finish;
        end
        rstn = 1;
        #1;
    end
endtask

initial begin
    clk = 0; rstn = 1;
    meta_read_en = 0; leaf_read_en = 0; free_read_en = 0;
    meta_read_addr = 0; leaf_read_addr = 0; free_read_addr = 0;
    meta_writes = 0; leaf_writes = 0; root_writes = 0; parent_writes = 0; free_writes = 0;
    reset_test;
    // Interrupt an in-progress scan, then require an entire new initialization.
    for (i = 0; i < 17; i = i + 1)
        tick;
    reset_test;
    for (i = 0; i < INIT_WRITES; i = i + 1) begin
        if ((init_done !== 0) || (init_guard !== 0) ||
            (meta_write_en !== (i < 8192)) || (l1_write_en !== (i < 2)) ||
            (l2_write_en !== (i < 32)) || (l3_write_en !== (i < 512)) ||
            (free_write_en !== (i < MEM_DEPTH)) ||
            (meta_write_en && (meta_write_addr !== i)) ||
            (l1_write_en && (l1_write_addr !== i)) ||
            (l2_write_en && (l2_write_addr !== i)) ||
            (l3_write_en && (l3_write_addr !== i)) ||
            (free_write_en && ((free_write_addr !== i) || (free_write_data !== i)))) begin
            $display("FAIL init scan edge R%0d ptr=%0d depth=%0d", i, PTR_WIDTH, MEM_DEPTH);
            $finish;
        end
        meta_writes = meta_writes + meta_write_en;
        leaf_writes = leaf_writes + l3_write_en;
        root_writes = root_writes + l1_write_en;
        parent_writes = parent_writes + l2_write_en;
        free_writes = free_writes + free_write_en;
        tick;
    end
    if ((init_done !== 0) || (init_guard !== 1) ||
        ({meta_write_en, l1_write_en, l2_write_en, l3_write_en, free_write_en} !== 5'b00000)) begin
        $display("FAIL init last-write/guard boundary");
        $finish;
    end
    tick;
    if ((init_done !== 1) || (init_guard !== 0) ||
        (meta_writes != 8192) || (leaf_writes != 512) ||
        (root_writes != 2) || (parent_writes != 32) || (free_writes != MEM_DEPTH) ||
        (l1_flat !== 32'd0) || (l2_flat !== 512'd0)) begin
        $display("FAIL init completion and write counts");
        $finish;
    end
    // The first normal read edge is R_(INIT_WRITES+1), after the guard.
    for (i = 0; i < INIT_WRITES; i = i + 1) begin
        meta_read_en = i < 8192; leaf_read_en = i < 512; free_read_en = i < MEM_DEPTH;
        meta_read_addr = i; leaf_read_addr = i; free_read_addr = i;
        tick;
        if ((init_done !== 1) || (init_guard !== 0) || (leaf_conflict !== 0) ||
            ({meta_write_en, l1_write_en, l2_write_en, l3_write_en, free_write_en} !== 5'b00000) ||
            (tt_valid !== meta_read_en) || (rc_valid !== meta_read_en) ||
            (leaf_valid !== leaf_read_en) || (free_valid !== free_read_en) ||
            (meta_read_en && ((tt_data !== 0) || (rc_data !== 0))) ||
            (leaf_read_en && (leaf_data !== 0)) || (free_read_en && (free_data !== i))) begin
            $display("FAIL init readback index=%0d ptr=%0d depth=%0d", i, PTR_WIDTH, MEM_DEPTH);
            $finish;
        end
    end
    meta_read_en = 0; leaf_read_en = 0; free_read_en = 0;
    // Runtime reset restarts at address zero and clears init_done asynchronously.
    reset_test;
    if ((meta_write_addr !== 0) || (free_write_addr !== 0) || (init_done !== 0)) begin
        $display("FAIL init runtime restart");
        $finish;
    end
    $display("PASS tb_wfq_init_ctrl ptr=%0d depth=%0d writes=%0d guard=R%0d first_read=R%0d",
             PTR_WIDTH, MEM_DEPTH, INIT_WRITES, INIT_WRITES, INIT_WRITES+1);
    $finish;
end
endmodule
