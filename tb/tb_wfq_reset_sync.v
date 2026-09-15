`timescale 1ns/1ps
module tb_wfq_reset_sync;
reg clk, rstn;
wire core_rstn;
integer round;
wfq_reset_sync u_dut (.clk(clk), .rstn(rstn), .core_rstn(core_rstn));

task expect_reset;
    input expected;
    begin
        #1;
        if (core_rstn !== expected) begin
            $display("FAIL reset round=%0d expected=%b actual=%b", round, expected, core_rstn);
            $finish;
        end
    end
endtask

initial begin
    clk = 0; rstn = 1;
    for (round = 0; round < 3; round = round + 1) begin
        #2; rstn = 0;
        expect_reset(0);
        #2; rstn = 1;
        expect_reset(0);
        #2; clk = 1;
        expect_reset(0);
        #2; clk = 0;
        #2; clk = 1;
        expect_reset(1);
        #2; clk = 0;
    end
    // Interrupt release after only its first stage and require two fresh edges.
    rstn = 0; expect_reset(0);
    rstn = 1; #2; clk = 1; expect_reset(0);
    clk = 0; rstn = 0; expect_reset(0);
    rstn = 1; #2; clk = 1; expect_reset(0);
    clk = 0; #2; clk = 1; expect_reset(1);
    $display("PASS tb_wfq_reset_sync");
    $finish;
end
endmodule
