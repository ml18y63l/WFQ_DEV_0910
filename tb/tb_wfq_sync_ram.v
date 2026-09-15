`timescale 1ns/1ps
module tb_wfq_sync_ram;
parameter integer DATA_WIDTH = 11;
reg clk, rstn;
reg read_en, write_en, commit_valid, pending_valid;
reg [3:0] read_addr, write_addr, commit_addr, pending_addr;
reg [DATA_WIDTH-1:0] write_data, commit_data, pending_data;
wire read_valid;
wire [DATA_WIDTH-1:0] read_data;
reg rw_read_en, rw_write_en;
reg [3:0] rw_addr;
reg [DATA_WIDTH-1:0] rw_write_data;
wire rw_valid, access_conflict;
wire [DATA_WIDTH-1:0] rw_read_data;
reg [DATA_WIDTH-1:0] expected_mem [0:15];
reg [DATA_WIDTH-1:0] expected_rw_mem [0:15];
reg [DATA_WIDTH-1:0] held_dual, held_single;
integer i, seed, checks;

wfq_sync_ram_1r1w #(.DATA_WIDTH(DATA_WIDTH), .MEM_DEPTH(16)) u_dual (
    .clk(clk), .rstn(rstn), .read_en(read_en), .read_addr(read_addr),
    .write_en(write_en), .write_addr(write_addr), .write_data(write_data),
    .commit_valid(commit_valid), .commit_addr(commit_addr), .commit_data(commit_data),
    .pending_valid(pending_valid), .pending_addr(pending_addr), .pending_data(pending_data),
    .read_valid(read_valid), .read_data(read_data)
);
wfq_sync_ram_1rw #(.DATA_WIDTH(DATA_WIDTH), .MEM_DEPTH(16)) u_single (
    .clk(clk), .rstn(rstn), .read_en(rw_read_en), .write_en(rw_write_en),
    .addr(rw_addr), .write_data(rw_write_data), .read_valid(rw_valid),
    .read_data(rw_read_data), .access_conflict(access_conflict)
);

task check_cycle;
    reg expected_valid, expected_rw_valid, expected_conflict;
    reg [DATA_WIDTH-1:0] expected_data, expected_rw_data;
    begin
        expected_valid = rstn && read_en;
        expected_rw_valid = rstn && rw_read_en && !rw_write_en;
        expected_conflict = rstn && rw_read_en && rw_write_en;
        expected_data = expected_mem[read_addr];
        expected_rw_data = expected_rw_mem[rw_addr];
        if (write_en && (write_addr == read_addr))
            expected_data = write_data;
        if (pending_valid && (pending_addr == read_addr))
            expected_data = pending_data;
        if (commit_valid && (commit_addr == read_addr))
            expected_data = commit_data;
        if (rstn && write_en)
            expected_mem[write_addr] = write_data;
        if (rstn && rw_write_en && !rw_read_en)
            expected_rw_mem[rw_addr] = rw_write_data;
        #2;
        if (access_conflict !== expected_conflict) begin
            $display("FAIL RAM single-port collision indicator");
            $finish;
        end
        #2; clk = 1; #1;
        if ((read_valid !== expected_valid) || (rw_valid !== expected_rw_valid) ||
            (expected_valid && (read_data !== expected_data)) ||
            (expected_rw_valid && (rw_read_data !== expected_rw_data))) begin
            $display("FAIL RAM cycle=%0d dual=%b/%h expected=%b/%h single=%b/%h expected=%b/%h",
                     checks, read_valid, read_data, expected_valid, expected_data,
                     rw_valid, rw_read_data, expected_rw_valid, expected_rw_data);
            $finish;
        end
        checks = checks + 1;
        #4; clk = 0;
    end
endtask

initial begin
    clk = 0; rstn = 1; checks = 0; seed = 32'h19a72026;
    read_en = 0; write_en = 0; commit_valid = 0; pending_valid = 0;
    read_addr = 0; write_addr = 0; commit_addr = 0; pending_addr = 0;
    write_data = 0; commit_data = 0; pending_data = 0;
    rw_read_en = 0; rw_write_en = 0; rw_addr = 0; rw_write_data = 0;
    #1; rstn = 0; #1;
    if ((read_valid !== 0) || (rw_valid !== 0)) begin
        $display("FAIL RAM asynchronous valid reset");
        $finish;
    end
    rstn = 1;
    for (i = 0; i < 16; i = i + 1) begin
        write_en = 1; write_addr = i; write_data = i + 1;
        rw_write_en = 1; rw_addr = i; rw_write_data = i + 33;
        check_cycle;
    end
    write_en = 0; rw_write_en = 0;
    read_en = 1; rw_read_en = 1;
    for (i = 0; i < 16; i = i + 1) begin
        read_addr = i; rw_addr = i;
        check_cycle;
    end
    // Changing addresses between edges must not change synchronous read data.
    held_dual = read_data; held_single = rw_read_data;
    read_addr = 0; rw_addr = 0;
    #1;
    if ((read_data !== held_dual) || (rw_read_data !== held_single)) begin
        $display("FAIL RAM read is combinational instead of synchronous");
        $finish;
    end
    check_cycle;
    // NEXT[B] delayed patch overlaps the new extract's read of NEXT[B].
    read_addr = 3; write_en = 1; write_addr = 3; write_data = 11;
    check_cycle;
    // A macro may return X for a same-address read/write collision.
    force u_dual.ram_read_data_d = {DATA_WIDTH{1'bx}};
    #1;
    if (read_data !== write_data) begin
        $display("FAIL RAM forwarding depends on raw collision data");
        $finish;
    end
    release u_dual.ram_read_data_d;
    // New commit beats a pending patch and the physical write, including NULL.
    pending_valid = 1; pending_addr = 3; pending_data = 7;
    commit_valid = 1; commit_addr = 3; commit_data = 0;
    check_cycle;
    // Clearing source overlays after E_k must not change the captured read.
    commit_valid = 0; pending_valid = 0; write_en = 0;
    commit_data = {DATA_WIDTH{1'b1}}; pending_data = {DATA_WIDTH{1'b1}};
    #1;
    if ((read_valid !== 1) || (read_data !== {DATA_WIDTH{1'b0}})) begin
        $display("FAIL RAM bypass lifetime after overlay removal");
        $finish;
    end
    // A following raw read must return actual stored data, not stale bypass.
    check_cycle;
    pending_valid = 1; pending_addr = 3; pending_data = 0;
    commit_valid = 1; commit_addr = 4;
    check_cycle;
    commit_valid = 0; pending_valid = 0;
    // A 1RW collision is rejected, including its write side effect.
    rw_addr = 5; rw_read_en = 1; rw_write_en = 1; rw_write_data = 0;
    check_cycle;
    rw_write_en = 0;
    check_cycle;
    // Reset suppresses writes and valid, while preserving the RAM contents.
    rstn = 0; write_en = 1; write_addr = 3; write_data = 0;
    rw_read_en = 0; rw_write_en = 1; rw_write_data = 0;
    check_cycle;
    rstn = 1; write_en = 0; rw_write_en = 0; rw_read_en = 1;
    check_cycle;
    // Independent state model across random bubbles, collisions and forwarding.
    for (i = 0; i < 5000; i = i + 1) begin
        read_en = $random(seed); write_en = $random(seed);
        read_addr = $random(seed); write_addr = $random(seed);
        write_data = {$random(seed), $random(seed)};
        commit_valid = $random(seed); pending_valid = $random(seed);
        commit_addr = (i % 3 == 0) ? read_addr : $random(seed);
        pending_addr = (i % 2 == 0) ? read_addr : $random(seed);
        commit_data = {$random(seed), $random(seed)};
        pending_data = {$random(seed), $random(seed)};
        rw_read_en = $random(seed); rw_write_en = $random(seed);
        rw_addr = $random(seed); rw_write_data = {$random(seed), $random(seed)};
        check_cycle;
    end
    // Drain-check every physical word after the random stream.
    read_en = 1; write_en = 0; commit_valid = 0; pending_valid = 0;
    rw_read_en = 1; rw_write_en = 0;
    for (i = 0; i < 16; i = i + 1) begin
        read_addr = i; rw_addr = i;
        check_cycle;
    end
    $display("PASS tb_wfq_sync_ram width=%0d cycles=%0d", DATA_WIDTH, checks);
    $finish;
end
endmodule
