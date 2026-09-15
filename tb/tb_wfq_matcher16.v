// Exhaustive, independent behavioral reference for the grouped matcher.
`timescale 1ns/1ps
`include "wfq_defs.vh"

module tb_wfq_matcher16;
reg [15:0] bitmap;
reg [3:0] query;
reg [1:0] max_mode;
wire le_found, lt_found, max_found;
wire [3:0] le_index, lt_index, max_index;
wire [15:0] le_onehot, lt_onehot, max_onehot;
wire le_exact, lt_exact, max_exact;
integer bits_value, q, k, previous, current, maximum, checks;

wfq_matcher16 u_le (
    .bitmap(bitmap), .query(query), .mode(`WFQ_MATCH_LE),
    .found(le_found), .index(le_index), .onehot(le_onehot), .exact(le_exact)
);
wfq_matcher16 u_lt (
    .bitmap(bitmap), .query(query), .mode(`WFQ_MATCH_LT),
    .found(lt_found), .index(lt_index), .onehot(lt_onehot), .exact(lt_exact)
);
wfq_matcher16 u_max (
    .bitmap(bitmap), .query(query), .mode(max_mode),
    .found(max_found), .index(max_index), .onehot(max_onehot), .exact(max_exact)
);

task check_result;
    input actual_found;
    input [3:0] actual_index;
    input [15:0] actual_onehot;
    input actual_exact;
    input integer expected;
    input expected_exact;
    reg [3:0] expected_index;
    reg [15:0] expected_onehot;
    begin
        expected_index = (expected < 0) ? 4'd0 : expected;
        expected_onehot = (expected < 0) ? 16'h0000 : (16'h0001 << expected);
        if ((actual_found !== (expected >= 0)) ||
            (actual_index !== expected_index) ||
            (actual_onehot !== expected_onehot) ||
            (actual_exact !== expected_exact)) begin
            $display("FAIL matcher bitmap=%h query=%d expected=%d got=%b/%d/%h/%b",
                     bitmap, query, expected, actual_found, actual_index,
                     actual_onehot, actual_exact);
            $finish;
        end
        checks = checks + 1;
    end
endtask

initial begin
    bitmap = 0;
    query = 0;
    max_mode = `WFQ_MATCH_MAX;
    checks = 0;
    for (bits_value = 0; bits_value < 65536; bits_value = bits_value + 1) begin
        bitmap = bits_value;
        current = -1;
        maximum = -1;
        // Serial software-style scan is intentionally independent of RTL groups.
        for (k = 0; k < 16; k = k + 1) begin
            if (bitmap[k])
                maximum = k;
        end
        for (q = 0; q < 16; q = q + 1) begin
            query = q;
            previous = current;
            if (bitmap[q])
                current = q;
            #1;
            check_result(le_found, le_index, le_onehot, le_exact,
                         current, current == q);
            check_result(lt_found, lt_index, lt_onehot, lt_exact, previous, 1'b0);
            // Also prove MAX is independent of query, beyond the required sweep.
            check_result(max_found, max_index, max_onehot, max_exact, maximum, 1'b0);
        end
    end
    max_mode = 2'b11;
    bitmap = 16'hffff;
    #1;
    check_result(max_found, max_index, max_onehot, max_exact, -1, 1'b0);
    $display("PASS tb_wfq_matcher16 checks=%0d", checks);
    $finish;
end
endmodule
