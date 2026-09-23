// Project : wfq_tag_sort_engine
// File    : tb_wfq_tag_wrap.v
// Spec    : Design_Spec_V1.2.md, sections 3, 4 and 10
// Function: Self-checking tag/epoch wrap test; Verilog-2001 only.
// Model   : Untruncated logical epochs, stable insertion order, public ports.

`timescale 1ns/1ps
`default_nettype none

module tb_wfq_tag_wrap;

reg                                    clk;
reg                                    rstn;
reg                                    insert_val;
reg [15:0]                             insert_epoch;
reg [11:0]                             insert_tag;
reg [8:0]                              insert_flow_id;
reg                                    extract_req;
reg                                    extract_out_ready;
wire                                   insert_ready;
wire                                   insert_commit;
wire                                   insert_epoch_blocked;
wire                                   extract_ready;
wire                                   extract_commit;
wire                                   extract_val;
wire [15:0]                            min_epoch_out;
wire [11:0]                            min_tag_out;
wire [8:0]                             min_tag_flow_id;
wire                                   init_done;
wire                                   empty;
wire                                   full;
wire [10:0]                            queue_level;
wire                                   busy;
wire                                   idle;
wire                                   fault;
wire [3:0]                             fault_code;

integer                                logical_epoch;
integer                                model_epoch [0:31];
reg [11:0]                             model_tag [0:31];
reg [8:0]                              model_flow [0:31];
reg [36:0]                            expected_rsp [0:63];
reg [36:0]                            held_rsp;
reg                                    held_valid;
integer                                model_count;
integer                                rsp_write;
integer                                rsp_read;
integer                                cycle;
integer                                last_accept;
integer                                insert_due;
integer                                extract_due;
integer                                committed_count;
integer                                inserts;
integer                                extracts;
integer                                insert_commits;
integer                                extract_commits;
integer                                blocked_cycles;
integer                                stalled_cycles;
integer                                gap5_count;
integer                                scenario;
integer                                scenario_old_epoch;
integer                                old_drain_commit_target;
integer                                idx;
integer                                pos;
reg                                    sampled_insert;
reg                                    sampled_extract;
reg                                    expected_insert_commit;
reg                                    expected_extract_commit;
reg [2047:0]                           fsdb_path;

wfq_tag_sort_engine #(
    .PTR_WIDTH                         (10),
    .MEM_DEPTH                         (1024),
    .FLOW_ID_WIDTH                     (9),
    .ISSUE_INTERVAL                    (5)
) u_dut (
    .clk                               (clk),
    .rstn                              (rstn),
    .insert_val                        (insert_val),
    .insert_ready                      (insert_ready),
    .insert_epoch                      (insert_epoch),
    .insert_tag                        (insert_tag),
    .insert_flow_id                    (insert_flow_id),
    .insert_commit                     (insert_commit),
    .insert_epoch_blocked              (insert_epoch_blocked),
    .extract_req                       (extract_req),
    .extract_ready                     (extract_ready),
    .extract_commit                    (extract_commit),
    .extract_val                       (extract_val),
    .extract_out_ready                 (extract_out_ready),
    .min_epoch_out                     (min_epoch_out),
    .min_tag_out                       (min_tag_out),
    .min_tag_flow_id                   (min_tag_flow_id),
    .init_done                         (init_done),
    .empty                             (empty),
    .full                              (full),
    .queue_level                       (queue_level),
    .busy                              (busy),
    .idle                              (idle),
    .fault                             (fault),
    .fault_code                        (fault_code)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

initial begin
`ifdef FSDB
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_path)) begin
        fsdb_path = "wfq_tag_wrap.fsdb";
    end
    $fsdbDumpfile(fsdb_path);
    $fsdbDumpvars(0, tb_wfq_tag_wrap, "+all");
`endif
end

task fail;
    input [1023:0] reason;
    begin
        $display("FAIL tb_wfq_tag_wrap scenario=%0d cycle=%0d reason=%0s fault=%b code=%h",
                 scenario, cycle, reason, fault, fault_code);
`ifdef FSDB
        $fsdbDumpflush;
`endif
        // Verilog-2001 $finish need not return a failure exit code.
        // The supplied runner also requires PASS and rejects FAIL in the log.
        $finish;
    end
endtask

task check;
    input ok;
    input [1023:0] reason;
    begin
        if (ok !== 1'b1) begin
            fail(reason);
        end
    end
endtask

// Sample ready/valid before NBA, then check registered commit/status after NBA.
// At II=5 an earlier operation has committed before the next acceptance.
always @(posedge clk) begin
    if (rstn && init_done) begin
        cycle = cycle + 1;
        check(fault === 1'b0, "unexpected fault");
        sampled_insert = insert_val && insert_ready;
        sampled_extract = extract_req && extract_ready;
        check(!(sampled_insert && sampled_extract), "two requests accepted at one edge");

        if (held_valid) begin
            check(extract_val && ({min_epoch_out, min_tag_out, min_tag_flow_id} === held_rsp),
                  "response changed while backpressured");
        end
        held_valid = extract_val && !extract_out_ready;
        held_rsp = {min_epoch_out, min_tag_out, min_tag_flow_id};
        if (held_valid) begin
            stalled_cycles = stalled_cycles + 1;
        end
        if (extract_val && extract_out_ready) begin
            check(rsp_read < rsp_write, "unexpected response");
            if ({min_epoch_out, min_tag_out, min_tag_flow_id} !== expected_rsp[rsp_read]) begin
                $display("expected=%h actual=%h response=%0d", expected_rsp[rsp_read],
                         {min_epoch_out, min_tag_out, min_tag_flow_id}, rsp_read);
                fail("epoch/tag/FCFS output mismatch");
            end
            $display("OUT cycle=%0d epoch=%0d tag=%0d flow=%0d", cycle,
                     min_epoch_out, min_tag_out, min_tag_flow_id);
            rsp_read = rsp_read + 1;
        end
        if (insert_epoch_blocked) begin
            blocked_cycles = blocked_cycles + 1;
            check(!insert_ready, "out-of-window epoch accepted");
        end
        if (insert_val && (logical_epoch == scenario_old_epoch + 2) &&
            (extract_commits < old_drain_commit_target)) begin
            check(insert_epoch_blocked && !insert_ready, "third generation legal before old drain commit");
        end
        if (sampled_insert || sampled_extract) begin
            if (last_accept >= 0) begin
                check(cycle - last_accept >= 5, "FAST5 minimum issue interval violated");
                if (cycle - last_accept == 5) begin
                    gap5_count = gap5_count + 1;
                end
            end
            last_accept = cycle;
        end
        if (sampled_insert) begin
            check(model_count < 32, "reference queue overflow");
            check(insert_epoch === logical_epoch[15:0], "driver logical epoch mismatch");
            if (logical_epoch == scenario_old_epoch + 2) begin
                check(extract_commits == old_drain_commit_target,
                      "third generation accepted before old drain commit");
                check((model_count == 4) && (model_epoch[0] == scenario_old_epoch + 1),
                      "bank reuse requires remaining next-generation nodes");
            end
            // Append after equal keys: flow ID deliberately does not sort the key.
            pos = 0;
            for (idx = 0; idx < model_count; idx = idx + 1) begin
                if ((model_epoch[idx] < logical_epoch) ||
                    ((model_epoch[idx] == logical_epoch) && (model_tag[idx] <= insert_tag))) begin
                    pos = idx + 1;
                end
            end
            for (idx = model_count; idx > pos; idx = idx - 1) begin
                model_epoch[idx] = model_epoch[idx-1];
                model_tag[idx] = model_tag[idx-1];
                model_flow[idx] = model_flow[idx-1];
            end
            model_epoch[pos] = logical_epoch;
            model_tag[pos] = insert_tag;
            model_flow[pos] = insert_flow_id;
            model_count = model_count + 1;
            inserts = inserts + 1;
            insert_due = cycle + 4;
            $display("INSERT cycle=%0d logical_epoch=%0d epoch=%0d tag=%0d flow=%0d",
                     cycle, logical_epoch, insert_epoch, insert_tag, insert_flow_id);
        end
        if (sampled_extract) begin
            check(model_count > 0, "extract accepted on empty model");
            check(rsp_write < 64, "reference response queue overflow");
            expected_rsp[rsp_write] = {model_epoch[0][15:0], model_tag[0], model_flow[0]};
            rsp_write = rsp_write + 1;
            model_count = model_count - 1;
            for (idx = 0; idx < model_count; idx = idx + 1) begin
                model_epoch[idx] = model_epoch[idx+1];
                model_tag[idx] = model_tag[idx+1];
                model_flow[idx] = model_flow[idx+1];
            end
            extracts = extracts + 1;
            extract_due = cycle + 1;
        end
        expected_insert_commit = (cycle == insert_due);
        expected_extract_commit = (cycle == extract_due);
        if (expected_insert_commit) begin
            committed_count = committed_count + 1;
            insert_commits = insert_commits + 1;
        end
        if (expected_extract_commit) begin
            committed_count = committed_count - 1;
            extract_commits = extract_commits + 1;
        end
        #1;
        check(insert_commit === expected_insert_commit, "insert commit must be E0+4");
        check(extract_commit === expected_extract_commit, "extract commit must be E0+1");
        check(queue_level === committed_count[10:0], "committed queue_level mismatch");
        check(empty === (committed_count == 0), "empty status mismatch");
        check(full === 1'b0, "unexpected full status");
        check(fault === 1'b0, "fault after clock edge");
    end
end

// Drivers change inputs only on falling edges and hold payload until handshake.
task push;
    input integer epoch_value;
    input [11:0] tag_value;
    input [8:0] flow_value;
    begin
        @(negedge clk);
        logical_epoch = epoch_value;
        insert_epoch = epoch_value[15:0];
        insert_tag = tag_value;
        insert_flow_id = flow_value;
        insert_val = 1'b1;
        @(posedge clk);
        while (insert_ready !== 1'b1) begin
            @(posedge clk);
        end
        @(negedge clk);
        insert_val = 1'b0;
    end
endtask

task pop;
    begin
        @(negedge clk);
        extract_req = 1'b1;
        @(posedge clk);
        while (extract_ready !== 1'b1) begin
            @(posedge clk);
        end
        @(negedge clk);
        extract_req = 1'b0;
    end
endtask

task wrap_scenario;
    input integer old_epoch;
    integer start_inserts;
    integer start_responses;
    integer start_blocked;
    integer start_stalled;
    integer start_gap5;
    integer n;
    begin
        start_inserts = inserts;
        start_responses = rsp_read;
        start_blocked = blocked_cycles;
        start_stalled = stalled_cycles;
        start_gap5 = gap5_count;
        scenario_old_epoch = old_epoch;
        old_drain_commit_target = extract_commits + 4;
        $display("SCENARIO %0d: logical epochs %0d -> %0d -> %0d", scenario,
                 old_epoch, old_epoch+1, old_epoch+2);
        push(old_epoch,   12'hfff, 9'd91);
        push(old_epoch+1, 12'h000, 9'd81);
        push(old_epoch,   12'hffe, 9'd71);
        push(old_epoch+1, 12'h001, 9'd61);
        push(old_epoch,   12'hfff, 9'd51);
        push(old_epoch+1, 12'h000, 9'd41);
        push(old_epoch,   12'hff0, 9'd31);
        push(old_epoch+1, 12'hfff, 9'd21);
        repeat (8) @(negedge clk);
        check(queue_level == 8, "both generations must coexist before draining");

        // Keep this third-generation request unchanged until it is accepted.
        logical_epoch = old_epoch + 2;
        insert_epoch = logical_epoch[15:0];
        insert_tag = 12'h000;
        insert_flow_id = 9'd11;
        insert_val = 1'b1;
        repeat (8) begin
            @(posedge clk);
            #2;
            check(insert_epoch_blocked && !insert_ready, "third generation must be blocked");
            check(inserts == start_inserts + 8, "blocked insertion changed acceptance count");
        end

        @(negedge clk);
        extract_out_ready = 1'b0;
        pop;
        repeat (12) @(negedge clk);
        check(extract_val && (rsp_read == start_responses), "response must wait for consumer");
        extract_out_ready = 1'b1;
        // Blocked third generation must not prevent old-generation extraction.
        for (n = 0; n < 3; n = n + 1) begin
            pop;
        end
        wait (inserts == start_inserts + 9);
        @(negedge clk);
        insert_val = 1'b0;
        check(extracts == start_responses + 4, "third generation accepted before old epoch drained");
        $display("WINDOW_ADVANCE scenario=%0d third generation accepted without reset", scenario);

        for (n = 0; n < 5; n = n + 1) begin
            pop;
        end
        wait (rsp_read == start_responses + 9);
        repeat (8) @(negedge clk);
        check(empty && idle && !busy && !extract_val, "final queue/response/writeback drain");
        check(model_count == 0 && queue_level == 0, "model and DUT not empty");
        check(blocked_cycles > start_blocked, "missing epoch-block coverage");
        check(stalled_cycles >= start_stalled + 10, "missing response-stall coverage");
        check(gap5_count > start_gap5, "missing FAST5 acceptance coverage");
        $display("SCENARIO_PASS %0d inserts=9 responses=9 blocked_cycles=%0d stalled_cycles=%0d gap5=%0d",
                 scenario, blocked_cycles-start_blocked, stalled_cycles-start_stalled,
                 gap5_count-start_gap5);
    end
endtask

initial begin
    rstn = 1'b0;
    insert_val = 1'b0;
    insert_epoch = 16'd0;
    insert_tag = 12'd0;
    insert_flow_id = 9'd0;
    extract_req = 1'b0;
    extract_out_ready = 1'b1;
    logical_epoch = 0;
    model_count = 0;
    rsp_write = 0;
    rsp_read = 0;
    held_valid = 1'b0;
    held_rsp = 37'd0;
    cycle = 0;
    last_accept = -1;
    insert_due = -1;
    extract_due = -1;
    committed_count = 0;
    inserts = 0;
    extracts = 0;
    insert_commits = 0;
    extract_commits = 0;
    blocked_cycles = 0;
    stalled_cycles = 0;
    gap5_count = 0;
    scenario = 0;
    scenario_old_epoch = 0;
    old_drain_commit_target = 0;
    repeat (5) @(negedge clk);
    rstn = 1'b1;
    wait (init_done === 1'b1);
    @(negedge clk);
    scenario = 1;
    wrap_scenario(7);
    // Queue is empty: arbitrary rebase is legal; no reset between scenarios.
    scenario = 2;
    wrap_scenario(65535);
    check(inserts == 18 && extracts == 18 && rsp_read == 18, "operation totals");
    check(insert_commits == inserts && extract_commits == extracts, "commit totals");
`ifdef FSDB
    $fsdbDumpflush;
`endif
    $display("PASS tb_wfq_tag_wrap scenarios=2 inserts=18 extracts=18 responses=18 gap5=%0d", gap5_count);
    $finish;
end

// Includes the 8193-cycle initialization sweep; detects ready/valid deadlocks.
initial begin
    repeat (20000) @(posedge clk);
    fail("global timeout (20000 clocks)");
end

endmodule

`default_nettype wire
