// Independent transaction/resource scoreboard; list behavior is a TB fixture.
`timescale 1ns/1ps
module tb_wfq_resource_ctrl;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
parameter integer FLOW_ID_WIDTH = 9;
parameter integer ISSUE_INTERVAL = 5;
`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH+1);
localparam integer PAYLOAD_WIDTH = 28+FLOW_ID_WIDTH;
reg clk, rstn, halt, insert_val, extract_req, request_context;
reg [15:0] insert_epoch;
reg context_available, path_ready;
reg commit_req, commit_insert, commit_context;
reg [15:0] commit_epoch;
reg [PTR_WIDTH-1:0] release_ptr;
reg [PAYLOAD_WIDTH-1:0] response_payload;
reg [3:0] external_error_code;
reg extract_out_ready;
wire init_done, init_guard, init_free_write_en;
wire [ADDR_WIDTH-1:0] init_free_write_addr;
wire [PTR_WIDTH-1:0] init_free_write_data;
wire insert_ready, extract_ready, insert_fire, extract_fire;
wire insert_epoch_blocked, issue_open;
wire alloc_valid, alloc_context;
wire [PTR_WIDTH-1:0] alloc_ptr;
wire commit_due, commit_fire, cycle_allow;
wire extract_val;
wire [PAYLOAD_WIDTH-1:0] extract_payload;
wire [1:0] rsp_count, rsp_reserved;
wire [COUNT_WIDTH-1:0] free_count, alloc_reserved, queue_level;
wire empty, full;
wire [15:0] base_epoch, bank0_epoch, bank1_epoch;
wire [1:0] bank_valid;
wire [COUNT_WIDTH-1:0] bank0_count, bank1_count;
wire error_valid, fault;
wire [3:0] error_code, fault_code;

wfq_init_ctrl #(.PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH)) u_init (
    .clk(clk), .rstn(rstn), .init_done(init_done), .init_guard(init_guard),
    .meta_write_en(), .meta_write_addr(), .l1_write_en(), .l1_write_addr(),
    .l2_write_en(), .l2_write_addr(), .l3_write_en(), .l3_write_addr(),
    .free_write_en(init_free_write_en), .free_write_addr(init_free_write_addr),
    .free_write_data(init_free_write_data)
);

wfq_resource_ctrl #(
    .PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH),
    .FLOW_ID_WIDTH(FLOW_ID_WIDTH), .ISSUE_INTERVAL(ISSUE_INTERVAL)
) u_dut (
    .clk(clk), .rstn(rstn), .init_done(init_done), .init_guard(init_guard),
    .init_free_write_en(init_free_write_en),
    .init_free_write_addr(init_free_write_addr), .init_free_write_data(init_free_write_data),
    .halt(halt), .insert_val(insert_val), .insert_epoch(insert_epoch),
    .extract_req(extract_req), .request_context(request_context),
    .context_available(context_available), .path_ready(path_ready),
    .insert_ready(insert_ready), .extract_ready(extract_ready),
    .insert_fire(insert_fire), .extract_fire(extract_fire),
    .insert_epoch_blocked(insert_epoch_blocked), .issue_open(issue_open),
    .alloc_valid(alloc_valid), .alloc_context(alloc_context), .alloc_ptr(alloc_ptr),
    .commit_req(commit_req), .commit_insert(commit_insert),
    .commit_context(commit_context), .commit_epoch(commit_epoch),
    .release_ptr(release_ptr), .response_payload(response_payload),
    .external_error_code(external_error_code), .commit_due(commit_due),
    .commit_fire(commit_fire), .cycle_allow(cycle_allow),
    .extract_out_ready(extract_out_ready), .extract_val(extract_val),
    .extract_payload(extract_payload), .rsp_count(rsp_count), .rsp_reserved(rsp_reserved),
    .free_count(free_count), .alloc_reserved(alloc_reserved), .queue_level(queue_level),
    .empty(empty), .full(full), .base_epoch(base_epoch), .bank_valid(bank_valid),
    .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
    .bank0_count(bank0_count), .bank1_count(bank1_count),
    .error_valid(error_valid), .error_code(error_code), .fault(fault), .fault_code(fault_code)
);

parameter integer RANDOM_CYCLES = 20000;
parameter integer SEED = 12345;

integer cycle, checks, accepts, commits, responses, tight_gaps, rr_conflicts;
integer epoch_blocks, credit_blocks, sparse_gaps;
integer seed, k, j, limit, mode, random_word;
integer model_free, model_reserved, model_level, model_rsp_reserved;
integer stack_model [0:MEM_DEPTH-1];
reg live_model [0:MEM_DEPTH-1];
integer slot_epoch [0:MEM_DEPTH-1];
integer slot_seq [0:MEM_DEPTH-1];
reg [11:0] slot_tag [0:MEM_DEPTH-1];
reg [FLOW_ID_WIDTH-1:0] slot_flow [0:MEM_DEPTH-1];
integer model_bank0, model_bank1, model_epoch0, model_epoch1, model_base;
integer last_accept, model_next_issue, seq, model_rr;
integer pending_due, pending_accept, pending_ptr, pending_epoch;
integer pending_sequence;
reg pending_insert, pending_context;
reg [11:0] pending_tag;
reg [FLOW_ID_WIDTH-1:0] pending_flow;
integer rsp_head, rsp_tail;
reg [PAYLOAD_WIDTH-1:0] rsp_model [0:200000];
integer epoch_input;
reg [11:0] tag_input;
reg [FLOW_ID_WIDTH-1:0] flow_input;
reg ci, ce, ei, ee, epop;
integer h, best, expected_ptr;
reg [PAYLOAD_WIDTH-1:0] expected_payload;

task fail;
    input [767:0] reason;
    begin
        $display("FAIL resources ptr=%0d depth=%0d cycle=%0d reason=%0s fault=%0d local=%0d",
                 PTR_WIDTH, MEM_DEPTH, cycle, reason, fault_code, error_code);
        $finish;
    end
endtask

task check;
    input condition;
    input [767:0] reason;
    begin
        checks = checks + 1;
        if (condition !== 1'b1) begin
            fail(reason);
        end
    end
endtask

// Absolute cycle deadlines and live-node counts, independent of RTL phase state.
task step;
    begin
        insert_epoch = epoch_input;
        commit_req = (pending_due == cycle);
        commit_insert = pending_insert;
        commit_context = pending_context;
        commit_epoch = pending_epoch;
        release_ptr = pending_ptr;
        response_payload = {pending_epoch[15:0], pending_tag, pending_flow};
        #2;
        ci = insert_val && (model_free > 0) &&
             ((model_level == 0) || (epoch_input == model_base) ||
              (epoch_input == model_base+1)) && (cycle >= model_next_issue);
        ce = extract_req && (model_level > 0) &&
             ((rsp_tail-rsp_head+model_rsp_reserved) < 2) &&
             (cycle >= model_next_issue);
        ei = ci && (!ce || (model_rr == 1));
        ee = ce && (!ci || (model_rr == 0));
        epop = (rsp_tail != rsp_head) && extract_out_ready;
        check(insert_ready === ei, "insert grant/RR/eligibility");
        check(extract_ready === ee, "extract grant/RR/eligibility");
        check(!(ei && ee), "single issue");
        check(insert_epoch_blocked === (insert_val && (model_level != 0) &&
              (epoch_input != model_base) && (epoch_input != model_base+1)), "epoch blocked");
        check(commit_due === (pending_due == cycle), "fixed commit edge");
        check(commit_fire === commit_req, "valid commit permitted");
        check(!error_valid && !fault, "legal stream cannot fault");
        check(extract_val === (rsp_tail != rsp_head), "registered response valid");
        if (rsp_tail != rsp_head) begin
            check(extract_payload === rsp_model[rsp_head], "response data/order/stability");
        end
        check(alloc_valid === ((pending_accept+1 == cycle) && pending_insert),
              "FREE return exactly E1");
        if (alloc_valid) begin
            check(alloc_ptr == pending_ptr, "FREE top pointer");
            check(alloc_context == pending_context, "FREE context alignment");
            check(!live_model[alloc_ptr], "allocation must not alias live slot");
        end
        if (ci && ce) begin
            rr_conflicts = rr_conflicts + 1;
        end
        if (insert_epoch_blocked) begin
            epoch_blocks = epoch_blocks + 1;
        end
        if (extract_req && (model_level != 0) &&
            (rsp_tail-rsp_head+model_rsp_reserved >= 2) && (cycle >= model_next_issue)) begin
            credit_blocks = credit_blocks + 1;
        end
        if (epop) begin
            rsp_head = rsp_head + 1;
            responses = responses + 1;
        end

        if (commit_req) begin
            commits = commits + 1;
            if (pending_insert) begin
                model_reserved = model_reserved - 1;
                model_level = model_level + 1;
                live_model[pending_ptr] = 1;
                slot_epoch[pending_ptr] = pending_epoch;
                slot_seq[pending_ptr] = pending_sequence;
                slot_tag[pending_ptr] = pending_tag;
                slot_flow[pending_ptr] = pending_flow;
                if (model_level == 1) begin
                    model_base = pending_epoch;
                end
                if ((pending_epoch & 1) == 0) begin
                    model_bank0 = model_bank0 + 1;
                    model_epoch0 = pending_epoch;
                end
                else begin
                    model_bank1 = model_bank1 + 1;
                    model_epoch1 = pending_epoch;
                end
            end
            else begin
                check(live_model[pending_ptr], "release live pointer");
                live_model[pending_ptr] = 0;
                stack_model[model_free] = pending_ptr;
                model_free = model_free + 1;
                model_level = model_level - 1;
                model_rsp_reserved = model_rsp_reserved - 1;
                rsp_model[rsp_tail] = {pending_epoch[15:0], pending_tag, pending_flow};
                rsp_tail = rsp_tail + 1;
                if ((pending_epoch & 1) == 0) begin
                    model_bank0 = model_bank0 - 1;
                    if ((model_bank0 == 0) && (model_bank1 != 0)) begin
                        model_base = model_epoch1;
                    end
                end
                else begin
                    model_bank1 = model_bank1 - 1;
                    if ((model_bank1 == 0) && (model_bank0 != 0)) begin
                        model_base = model_epoch0;
                    end
                end
            end
            pending_due = -100;
        end
        if (ei || ee) begin
            check(cycle-last_accept >= 5, "minimum issue separation");
            if (cycle-last_accept == 5) begin
                tight_gaps = tight_gaps + 1;
            end
            else if (last_accept >= 0) begin
                sparse_gaps = sparse_gaps + 1;
            end
            last_accept = cycle;
            model_next_issue = cycle + 5;
            accepts = accepts + 1;
            pending_accept = cycle;
            pending_insert = ei;
            pending_context = request_context;
            model_rr = ee;
            if (ei) begin
                model_free = model_free - 1;
                model_reserved = model_reserved + 1;
                pending_ptr = stack_model[model_free];
                pending_epoch = epoch_input;
                pending_tag = tag_input;
                pending_flow = flow_input;
                seq = seq + 1;
                pending_sequence = seq;
                pending_due = cycle + 4;
            end
            else begin
                best = -1;
                for (h=0; h<MEM_DEPTH; h=h+1) begin
                    if (live_model[h]) begin
                        if (best == -1) begin
                            best = h;
                        end
                        else if ((slot_epoch[h] < slot_epoch[best]) ||
                                 ((slot_epoch[h] == slot_epoch[best]) &&
                                  ((slot_tag[h] < slot_tag[best]) ||
                                   ((slot_tag[h] == slot_tag[best]) &&
                                    (slot_seq[h] < slot_seq[best]))))) begin
                            best = h;
                        end
                    end
                end
                check(best >= 0, "model has head");
                pending_ptr = best;
                pending_epoch = slot_epoch[best];
                pending_tag = slot_tag[best];
                pending_flow = slot_flow[best];
                model_rsp_reserved = model_rsp_reserved + 1;
                pending_due = cycle + 1;
            end
        end
        #2; clk = 1; #1;
        check(free_count == model_free, "free count");
        check(alloc_reserved == model_reserved, "allocation reservation");
        check(queue_level == model_level, "committed level");
        check(free_count+alloc_reserved+queue_level == MEM_DEPTH, "capacity conservation");
        check(bank0_count == model_bank0 && bank1_count == model_bank1, "bank counts");
        check(bank_valid === {model_bank1!=0, model_bank0!=0}, "bank valid");
        if (model_level != 0) begin
            check(base_epoch == (model_base & 65535), "base and wrap advancement");
        end
        if (model_bank0 != 0) begin
            check(bank0_epoch == (model_epoch0 & 65535), "bank zero identity");
        end
        if (model_bank1 != 0) begin
            check(bank1_epoch == (model_epoch1 & 65535), "bank one identity");
        end
        check(rsp_count == rsp_tail-rsp_head && rsp_reserved == model_rsp_reserved,
              "response occupancy and reservations");
        check(empty === (model_level == 0) && full === (model_free == 0), "empty/full");
        check(!fault, "no sticky fault");
        #4; clk = 0;
        cycle = cycle + 1;
        request_context = ~request_context;
    end
endtask

task idle_cycles;
    input integer n;
    integer t;
    begin
        insert_val=0; extract_req=0;
        for(t=0;t<n;t=t+1) begin
            step;
        end
    end
endtask

task insert_one;
    input integer e;
    input [11:0] tag;
    integer target;
    begin
        epoch_input=e; tag_input=tag; flow_input=seq;
        insert_val=1; extract_req=0;
        target=accepts+1;
        while(accepts<target) begin
            step;
        end
        idle_cycles(4);
    end
endtask

task drain;
    integer watchdog;
    begin
        insert_val=0; extract_req=1; extract_out_ready=1;
        watchdog=0;
        while((model_level!=0)||(pending_due>=cycle)||(rsp_tail!=rsp_head)) begin
            step;
            watchdog=watchdog+1;
            if(watchdog>MEM_DEPTH*7+50) begin
                fail("drain timeout");
            end
        end
        idle_cycles(6);
    end
endtask

initial begin
    clk=0; rstn=0; halt=0; insert_val=0; extract_req=0; request_context=0;
    insert_epoch=0; epoch_input=0; tag_input=0; flow_input=0;
    context_available=1; path_ready=1; commit_req=0; commit_insert=0;
    commit_context=0; commit_epoch=0; release_ptr=0; response_payload=0;
    external_error_code=0; extract_out_ready=0;
    cycle=0; checks=0; accepts=0; commits=0; responses=0; tight_gaps=0; rr_conflicts=0;
    epoch_blocks=0; credit_blocks=0; sparse_gaps=0;
    model_free=MEM_DEPTH; model_reserved=0; model_level=0; model_rsp_reserved=0;
    model_bank0=0; model_bank1=0; model_epoch0=0; model_epoch1=0; model_base=0;
    last_accept=-100; model_next_issue=0; model_rr=0; seq=0;
    pending_due=-100; pending_accept=-100; pending_ptr=0; pending_epoch=0;
    pending_insert=0; pending_context=0; pending_tag=0; pending_flow=0;
    rsp_head=0; rsp_tail=0; seed=SEED;
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        stack_model[k]=k;
        live_model[k]=0;
    end
    #2; rstn=1;
    // Requests held through init; never accepted until the edge after guard.
    insert_val=1; extract_req=1;
    while(!init_done) begin
        #2;
        check(!insert_ready && !extract_ready && !extract_val && !full, "init masking");
        check(empty && queue_level==0, "init queue state");
        #2; clk=1; #1; #4; clk=0;
    end
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        check(u_dut.u_free.u_ram.mem_d[k] == k, "FREE initialization");
    end
    insert_val=0; extract_req=0;
    step;

    // Adjacent wrap epochs, interleaving, third-generation block and old drain.
    insert_one(65535,12'hfff);
    insert_one(65536,12'h000);
    insert_one(65535,12'h123);
    // Exhaustive read-only query check: only 65535 and 0 are legal in this window.
    for(j=0;j<65536;j=j+1) begin
        insert_epoch=j;#1;
        check(u_dut.epoch_legal===((j==65535)||(j==0)), "all epoch query encodings");
    end
    epoch_input=65537; insert_val=1; extract_req=1; extract_out_ready=0;
    for(k=0;k<15;k=k+1) begin
        step;
    end
    // Old responses retain full epoch despite bank reuse and queue rebuilding.
    idle_cycles(8);
    extract_out_ready=1;
    drain;
    insert_one(125,12'h011);
    drain;

    // Full capacity: all pointer encodings, including zero, are allocatable.
    epoch_input=200; tag_input=12'habc; insert_val=1; extract_req=0;
    while((model_free!=0)||(pending_due>=cycle)) begin
        flow_input=seq;
        step;
    end
    check(model_level==MEM_DEPTH && full && !empty, "full capacity no truncation");
    for(k=0;k<12;k=k+1) begin
        step;
    end
    check(alloc_ptr==0, "last initially allocated slot zero");
    // Full queue cannot borrow a same-edge release for insertion.
    extract_req=1;
    for(k=0;k<50;k=k+1) begin
        step;
    end
    drain;

    // Both requests continuously eligible: count 5-edge accepts and alternating RR.
    for(k=0;k<8;k=k+1) begin
        insert_one(500,k);
    end
    epoch_input=500; insert_val=1; extract_req=1; extract_out_ready=1;
    for(k=0;k<1000;k=k+1) begin
        tag_input=seq; flow_input=seq;
        step;
    end
    drain;

    // Non-aligned idle gaps, invalid epochs, mixed banks, random backpressure.
    for(k=0;k<RANDOM_CYCLES;k=k+1) begin
        random_word=$random(seed) & 32'h7fffffff;
        // Keep an offered insert and all its fields until it handshakes.
        // Requests outside the current window eventually progress by draining.
        if (!insert_val || ei) begin
            insert_val=(random_word % 8)<5;
            if(model_level==0) begin
                epoch_input=100000+(random_word%10000);
            end
            else begin
                case ((random_word/512)%8)
                    0,1: epoch_input=model_base+2;
                    2,3,4: epoch_input=model_base+1;
                    default: epoch_input=model_base;
                endcase
            end
            tag_input=random_word; flow_input=random_word/4096;
        end
        if (!extract_req || ee) begin
            extract_req=((random_word/8) % 8)<6;
        end
        if ((k%23)==0) begin
            extract_out_ready=((random_word/64) % 4)!=0;
        end
        step;
    end
    // Finish any accepted insert before asking to drain.
    idle_cycles(5);
    drain;
    check(model_free==MEM_DEPTH && model_reserved==0, "all slots returned");
    check(accepts==commits && responses*2==commits, "all operations and responses accounted");
    check(tight_gaps>100 && rr_conflicts>50, "sustained issue and conflict coverage");
    check(epoch_blocks>20 && credit_blocks>20 && sparse_gaps>10,
          "epoch/credit backpressure and non-aligned reissue coverage");
    // The stack is a permutation of all physical pointers after arbitrary reuse.
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        live_model[k]=0;
    end
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        expected_ptr=u_dut.u_free.u_ram.mem_d[k];
        check(expected_ptr<MEM_DEPTH && !live_model[expected_ptr], "unique FREE coverage");
        live_model[expected_ptr]=1;
    end
    $display("PASS tb_wfq_resource_ctrl ptr=%0d depth=%0d flow=%0d seed=%0d accepts=%0d responses=%0d gap5=%0d conflicts=%0d epoch_blocks=%0d credit_blocks=%0d sparse_gaps=%0d checks=%0d",
             PTR_WIDTH,MEM_DEPTH,FLOW_ID_WIDTH,SEED,accepts,responses,tight_gaps,rr_conflicts,
             epoch_blocks,credit_blocks,sparse_gaps,checks);
    $finish;
end

initial begin
    #100000000;
    fail("watchdog");
end
endmodule
