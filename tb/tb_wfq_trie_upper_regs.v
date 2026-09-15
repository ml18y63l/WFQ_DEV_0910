`timescale 1ns/1ps
module tb_wfq_trie_upper_regs;
reg clk, rstn;
reg l1_write_en, l1_write_addr, l2_write_en;
reg [4:0] l2_write_addr;
reg [15:0] l1_write_data, l2_write_data;
reg read_bank;
reg [3:0] read_a;
wire [15:0] l1_read_data, l2_read_data;
wire [31:0] l1_flat;
wire [511:0] l2_flat;
reg [15:0] expected_l1 [0:1];
reg [15:0] expected_l2 [0:31];
integer i, checks;

wfq_trie_upper_regs u_dut (
    .clk(clk), .rstn(rstn),
    .l1_write_en(l1_write_en), .l1_write_addr(l1_write_addr),
    .l1_write_data(l1_write_data), .l2_write_en(l2_write_en),
    .l2_write_addr(l2_write_addr), .l2_write_data(l2_write_data),
    .read_bank(read_bank), .read_a(read_a),
    .l1_read_data(l1_read_data), .l2_read_data(l2_read_data),
    .l1_flat(l1_flat), .l2_flat(l2_flat)
);

task tick;
    begin
        #4; clk = 1; #1;
        #4; clk = 0;
    end
endtask

task check_all;
    integer word_idx;
    begin
        // Clock stays LOW throughout: any registered read would fail this test.
        for (word_idx = 0; word_idx < 32; word_idx = word_idx + 1) begin
            read_bank = word_idx / 16;
            read_a = word_idx % 16;
            #1;
            if ((l2_read_data !== expected_l2[word_idx]) ||
                (l1_read_data !== expected_l1[read_bank]) ||
                (l2_flat[word_idx*16 +: 16] !== expected_l2[word_idx]) ||
                (l1_flat[read_bank*16 +: 16] !== expected_l1[read_bank])) begin
                $display("FAIL upper word=%0d", word_idx);
                $finish;
            end
            checks = checks + 1;
        end
    end
endtask

initial begin
    clk = 0; rstn = 1; checks = 0;
    l1_write_en = 0; l1_write_addr = 0; l1_write_data = 0;
    l2_write_en = 0; l2_write_addr = 0; l2_write_data = 0;
    read_bank = 0; read_a = 0;
    for (i = 0; i < 2; i = i + 1)
        expected_l1[i] = 0;
    for (i = 0; i < 32; i = i + 1)
        expected_l2[i] = 0;
    #1; rstn = 0; #1;
    check_all;
    rstn = 1;
    for (i = 0; i < 32; i = i + 1) begin
        l1_write_en = 1; l2_write_en = 1;
        l1_write_addr = i % 2; l2_write_addr = i;
        l1_write_data = 16'h8001 ^ (i * 257);
        l2_write_data = 16'h5a5a ^ (i * 513);
        // The pending write must not leak before its sampling edge.
        check_all;
        expected_l1[l1_write_addr] = l1_write_data;
        expected_l2[l2_write_addr] = l2_write_data;
        tick;
        check_all;
    end
    // Exact zero write on bank 1 does not clear neighboring rows or bank 0.
    l1_write_addr = 1; l1_write_data = 0;
    l2_write_addr = 31; l2_write_data = 0;
    expected_l1[1] = 0; expected_l2[31] = 0;
    tick;
    check_all;
    l1_write_en = 0; l2_write_en = 0;
    tick;
    check_all;
    // Asynchronous reset must clear both levels without a clock edge.
    rstn = 0;
    for (i = 0; i < 2; i = i + 1)
        expected_l1[i] = 0;
    for (i = 0; i < 32; i = i + 1)
        expected_l2[i] = 0;
    #1;
    check_all;
    $display("PASS tb_wfq_trie_upper_regs checks=%0d", checks);
    $finish;
end
endmodule
